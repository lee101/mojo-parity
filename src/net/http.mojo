"""HTTP/1.1 client over net.sock (plain or TLS) with per-origin keep-alive reuse.

Covers what prediction2's Go clients use from net/http: absolute-URL requests,
case-insensitive response headers, Content-Length / chunked / close-delimited
bodies, a body byte cap (io.LimitReader), and a whole-request timeout.
"""

from net.sock import Conn
from net.ratelimit import pace
from std.time import perf_counter_ns


@fieldwise_init
struct URL(Copyable, Movable):
    var scheme: String
    var host: String
    var port: Int
    var path: String

    @staticmethod
    def parse(raw: String) raises -> URL:
        var scheme: String
        var rest: String
        if raw.startswith("https://"):
            scheme = "https"
            rest = String(raw[byte=8:])
        elif raw.startswith("http://"):
            scheme = "http"
            rest = String(raw[byte=7:])
        elif raw.startswith("wss://"):
            scheme = "wss"
            rest = String(raw[byte=6:])
        elif raw.startswith("ws://"):
            scheme = "ws"
            rest = String(raw[byte=5:])
        else:
            raise Error("unsupported protocol scheme in " + raw)
        var slash = rest.find("/")
        var hostport = rest if slash < 0 else String(rest[byte=0:slash])
        var path = String("/") if slash < 0 else String(rest[byte=slash:])
        var secure = scheme == "https" or scheme == "wss"
        var port = 443 if secure else 80
        var host = hostport
        var colon = hostport.rfind(":")
        if colon >= 0 and hostport.find("]") < colon:
            host = String(hostport[byte=0:colon])
            port = atol(String(hostport[byte = colon + 1 :]))
        if host.startswith("[") and host.endswith("]"):
            var h2 = String(host[byte = 1 : host.byte_length() - 1])
            host = h2
        if host.byte_length() == 0:
            raise Error("http: no Host in request URL")
        return URL(scheme, host, port, path)

    def secure(self) -> Bool:
        return self.scheme == "https" or self.scheme == "wss"

    def origin(self) -> String:
        return self.scheme + "://" + self.host + ":" + String(self.port)

    def host_header(self) -> String:
        var default = 443 if self.secure() else 80
        if self.port == default:
            return self.host
        return self.host + ":" + String(self.port)


@fieldwise_init
struct Header(Copyable, Movable):
    var name: String
    var value: String


struct Response(Movable):
    var status: Int
    var reason: String
    var headers: List[Header]
    var body: List[UInt8]
    var keep_alive: Bool

    def __init__(out self):
        self.keep_alive = False
        self.reason = ""
        self.status = 0
        self.headers = List[Header]()
        self.body = List[UInt8]()

    def header(self, name: String) -> String:
        var key = name.lower()
        for h in self.headers:
            if h.name.lower() == key:
                return h.value
        return ""

    def text(self) -> String:
        return String(unsafe_from_utf8=self.body)


struct Client(Movable):
    var timeout_ms: Int
    var pool: List[Conn]
    var insecure: Bool
    var insecure_all: Bool
    var use_cookies: Bool
    var jar_hosts: List[String]
    var jar_names: List[String]
    var jar_values: List[String]

    def __init__(out self, timeout_ms: Int = 15000):
        self.timeout_ms = timeout_ms
        self.pool = List[Conn]()
        self.insecure = False
        self.insecure_all = False
        self.use_cookies = False
        self.jar_hosts = List[String]()
        self.jar_names = List[String]()
        self.jar_values = List[String]()

    def _cookie_header(self, host: String) -> String:
        var out = String("")
        for i in range(len(self.jar_hosts)):
            if self.jar_hosts[i] == host:
                if out.byte_length() > 0:
                    out += "; "
                out += self.jar_names[i] + "=" + self.jar_values[i]
        return out

    def _store_cookies(mut self, host: String, resp: Response):
        """net/http/cookiejar subset: name=value per host, Max-Age<=0 deletes."""
        for h in resp.headers:
            if h.name.lower() != "set-cookie":
                continue
            var parts = h.value.split(";")
            if len(parts) == 0:
                continue
            var nv = String(parts[0].strip())
            var eq = nv.find("=")
            if eq <= 0:
                continue
            var name = String(nv[byte=0:eq])
            var value = String(nv[byte = eq + 1 :])
            var delete = False
            for k in range(1, len(parts)):
                var a = String(parts[k].strip()).lower()
                if a.startswith("max-age="):
                    var v = String(a[byte=8:])
                    if v.startswith("-") or v == "0":
                        delete = True
            var at = -1
            for i in range(len(self.jar_hosts)):
                if self.jar_hosts[i] == host and self.jar_names[i] == name:
                    at = i
            if delete:
                if at >= 0:
                    _ = self.jar_hosts.pop(at)
                    _ = self.jar_names.pop(at)
                    _ = self.jar_values.pop(at)
                continue
            if at >= 0:
                self.jar_values[at] = value
            else:
                self.jar_hosts.append(host)
                self.jar_names.append(name)
                self.jar_values.append(value)

    def _take(mut self, u: URL) raises -> Conn:
        var o = u.origin()
        for i in range(len(self.pool)):
            if self.pool[i].origin == o:
                return self.pool.pop(i)
        var loopback = u.host == "localhost" or u.host == "127.0.0.1" or u.host == "::1"
        var c = Conn.dial(u.host, u.port, u.secure(), self.timeout_ms, self.insecure and loopback or self.insecure_all)
        c.origin = o
        return c^

    def do(
        mut self, method: String, url: String, headers: List[Header], body: String, max_bytes: Int = 1 << 20
    ) raises -> Response:
        var u = URL.parse(url)
        pace(u.host)
        var deadline = perf_counter_ns() + self.timeout_ms * 1_000_000
        var attempt = 0
        while True:
            var reused = False
            var o = u.origin()
            for i in range(len(self.pool)):
                if self.pool[i].origin == o:
                    reused = True
            var conn: Conn
            try:
                conn = self._take(u)
            except e:
                raise Error(_op(method) + " \"" + url + "\": " + String(e))
            conn.set_timeout_ms(self.timeout_ms)
            var hdrs = headers.copy()
            if self.use_cookies:
                var ck = self._cookie_header(u.host)
                if ck.byte_length() > 0:
                    hdrs.append(Header("Cookie", ck))
            try:
                var resp = _roundtrip(conn, method, u, hdrs, body, max_bytes, deadline)
                for h in hdrs:
                    if h.name.lower() == "connection" and h.value.lower() == "close":
                        resp.keep_alive = False
                if self.use_cookies:
                    self._store_cookies(u.host, resp)
                if resp.keep_alive:
                    self.pool.append(conn^)
                else:
                    conn.close()
                return resp^
            except e:
                conn.close()
                if reused and attempt == 0 and (method == "GET" or method == "HEAD" or method == "DELETE"):
                    attempt += 1
                    continue
                raise Error(_op(method) + " \"" + url + "\": " + String(e))


def _roundtrip(
    mut conn: Conn, method: String, u: URL, headers: List[Header], body: String, max_bytes: Int, deadline: Int
) raises -> Response:
    var req = method + " " + u.path + " HTTP/1.1\r\nHost: " + u.host_header() + "\r\n"
    var has_ua = False
    for h in headers:
        if h.name.lower() == "user-agent":
            has_ua = True
    if not has_ua:
        req += "User-Agent: Go-http-client/1.1\r\n"
    for h in headers:
        req += h.name + ": " + h.value + "\r\n"
    var has_cl = False
    for h in headers:
        if h.name.lower() == "content-length":
            has_cl = True
    # One Content-Length only: the IBKR gateway (and RFC 9112) reject duplicates with 400.
    if not has_cl and (body.byte_length() > 0 or method == "POST" or method == "PUT" or method == "PATCH"):
        req += "Content-Length: " + String(body.byte_length()) + "\r\n"
    req += "Accept-Encoding: identity\r\n\r\n"
    req += body
    conn.write_str(req)
    var rd = _Reader()
    var resp = Response()
    var line = rd.line(conn, deadline, True)
    if not line.startswith("HTTP/1."):
        raise Error("malformed HTTP response \"" + line + "\"")
    var sp = line.find(" ")
    resp.status = atol(String(line[byte = sp + 1 : sp + 4]))
    if line.byte_length() > sp + 5:
        resp.reason = String(line[byte = sp + 5 :])
    var keep_alive = line.startswith("HTTP/1.1")
    while True:
        var h = rd.line(conn, deadline)
        if h.byte_length() == 0:
            break
        var c = h.find(":")
        if c < 0:
            continue
        resp.headers.append(Header(String(h[byte=0:c]), String(String(h[byte = c + 1 :]).strip())))
    var conn_hdr = resp.header("Connection").lower()
    if conn_hdr == "close":
        keep_alive = False
    elif conn_hdr == "keep-alive":
        keep_alive = True
    if method == "HEAD" or resp.status == 204 or resp.status == 304 or (resp.status >= 100 and resp.status < 200):
        resp.keep_alive = keep_alive
        return resp^
    var te = resp.header("Transfer-Encoding").lower()
    var cl = resp.header("Content-Length")
    if te.find("chunked") >= 0:
        while True:
            var sz_line = rd.line(conn, deadline)
            var semi = sz_line.find(";")
            if semi >= 0:
                var cut = String(sz_line[byte=0:semi])
                sz_line = cut
            var n = _hex(String(sz_line.strip()))
            if n == 0:
                while rd.line(conn, deadline).byte_length() > 0:
                    pass
                break
            rd.copy(conn, n, resp.body, max_bytes, deadline)
            _ = rd.line(conn, deadline)
    elif cl.byte_length() > 0:
        rd.copy(conn, atol(cl), resp.body, max_bytes, deadline)
    else:
        keep_alive = False
        rd.copy(conn, -1, resp.body, max_bytes, deadline)
    if len(resp.body) > max_bytes:
        resp.body.resize(max_bytes, 0)
        keep_alive = False
    resp.keep_alive = keep_alive
    return resp^


def _op(method: String) -> String:
    """net/http urlErrorOp: "GET" -> "Get"."""
    if method.byte_length() == 0:
        return method
    return String(method[byte=0:1]) + String(method[byte=1:]).lower()


def _hex(s: String) raises -> Int:
    var v = 0
    if s.byte_length() == 0:
        raise Error("malformed chunked encoding")
    for b in s.as_bytes():
        var d: Int
        if b >= 48 and b <= 57:
            d = Int(b) - 48
        elif b >= 97 and b <= 102:
            d = Int(b) - 87
        elif b >= 65 and b <= 70:
            d = Int(b) - 55
        else:
            raise Error("malformed chunked encoding")
        v = v * 16 + d
    return v


struct _Reader:
    var buf: List[UInt8]
    var pos: Int

    def __init__(out self):
        self.buf = List[UInt8]()
        self.pos = 0

    def _fill(mut self, mut conn: Conn, deadline: Int) raises -> Bool:
        if perf_counter_ns() > deadline:
            raise Error("context deadline exceeded (Client.Timeout exceeded while awaiting headers)")
        if self.pos > 0 and self.pos == len(self.buf):
            self.buf.clear()
            self.pos = 0
        return conn.read_some(self.buf) > 0

    def line(mut self, mut conn: Conn, deadline: Int, first: Bool = False) raises -> String:
        while True:
            for i in range(self.pos, len(self.buf)):
                if self.buf[i] == 10:
                    var end = i
                    if end > self.pos and self.buf[end - 1] == 13:
                        end -= 1
                    var s = String(unsafe_from_utf8=Span(self.buf)[self.pos : end])
                    self.pos = i + 1
                    return s
            if not self._fill(conn, deadline):
                if first and self.pos == len(self.buf):
                    raise Error("EOF")
                raise Error("unexpected EOF")

    def copy(mut self, mut conn: Conn, n: Int, mut out: List[UInt8], max_bytes: Int, deadline: Int) raises:
        """Moves n bytes (n < 0: until EOF) into out, keeping at most max_bytes+1."""
        var left = n
        while left != 0:
            if self.pos == len(self.buf):
                if not self._fill(conn, deadline):
                    if n < 0:
                        return
                    raise Error("unexpected EOF")
            var avail = len(self.buf) - self.pos
            var take = avail if left < 0 else min(avail, left)
            for i in range(self.pos, self.pos + take):
                if len(out) <= max_bytes:
                    out.append(self.buf[i])
            self.pos += take
            if left > 0:
                left -= take
