"""TCP sockets (POSIX FFI) with optional TLS via the system OpenSSL (libssl.so.3).

Mirrors what prediction2 gets from Go net + crypto/tls: hostname resolution,
connect/read/write deadlines, SNI and certificate + hostname verification against
the system trust store (SSL_CERT_FILE / P2M_CA_FILE override for tests).
"""

from std.ffi import external_call
from std.os import getenv
from p2.ptr import keep

comptime PB = Pointer[UInt8, MutUntrackedOrigin]

comptime AF_UNSPEC = 0
comptime SOCK_STREAM = 1
comptime SOL_SOCKET = 1
comptime SO_RCVTIMEO = 20
comptime SO_SNDTIMEO = 21
comptime IPPROTO_TCP = 6
comptime TCP_NODELAY = 1


def _cstr(s: String) -> List[UInt8]:
    var out = List[UInt8](capacity=s.byte_length() + 1)
    for b in s.as_bytes():
        out.append(b)
    out.append(0)
    return out^


def _errno() -> Int:
    return Int(external_call["__errno_location", Pointer[Int32, MutUntrackedOrigin]]()[])


def strerror(en: Int) -> String:
    """Go syscall.Errno text: libc strerror with a lower-cased first letter."""
    var p = external_call["strerror", Pointer[UInt8, MutUntrackedOrigin]](Int32(en))
    var out = List[UInt8]()
    var i = 0
    while p[unsafe_offset=i] != 0:
        var b = p[unsafe_offset=i]
        if i == 0 and b >= 65 and b <= 90:
            b += 32
        out.append(b)
        i += 1
    return String(unsafe_from_utf8=out)


def _set_timeout(fd: Int32, opt: Int, ms: Int):
    var tv = List[Int](length=2, fill=0)
    tv[0] = ms // 1000
    tv[1] = (ms % 1000) * 1000
    _ = external_call["setsockopt", Int32](fd, Int32(SOL_SOCKET), Int32(opt), tv.unsafe_ptr(), UInt32(16))
    keep(tv)


struct Conn(Movable):
    """A connected stream; TLS when ssl != 0. Errors raise with Go-like text."""

    var fd: Int32
    var ctx: Int
    var ssl: Int
    var host: String
    var origin: String
    var closed: Bool

    def __init__(out self, fd: Int32, host: String):
        self.origin = String("")
        self.fd = fd
        self.ctx = 0
        self.ssl = 0
        self.host = host
        self.closed = False

    @staticmethod
    def dial(host: String, port: Int, tls: Bool, timeout_ms: Int, insecure: Bool = False) raises -> Conn:
        # Writes to a peer-closed socket must fail with EPIPE, not kill the process (as in Go).
        _ = external_call["signal", Int](Int32(13), Int(1))
        var chost = _cstr(host)
        var cport = _cstr(String(port))
        var hints = List[UInt8](length=48, fill=0)
        hints.unsafe_ptr().unsafe_bitcast[Int32]()[unsafe_offset=2] = Int32(SOCK_STREAM)
        var res = List[Int](length=1, fill=0)
        var rc = external_call["getaddrinfo", Int32](chost.unsafe_ptr(), cport.unsafe_ptr(), hints.unsafe_ptr(), res.unsafe_ptr())
        keep(hints)
        if rc != 0:
            raise Error("dial tcp: lookup " + host + ": no such host")
        var head = res[0]
        var ai = head
        var fd = Int32(-1)
        var last_err = 0
        while ai != 0:
            var p = PB(unsafe_from_address=ai)
            var ints = p.unsafe_bitcast[Int32]()
            var fam = ints[unsafe_offset=1]
            var stype = ints[unsafe_offset=2]
            var proto = ints[unsafe_offset=3]
            var alen = p.unsafe_offset(16).unsafe_bitcast[UInt32]()[]
            var aaddr = p.unsafe_offset(24).unsafe_bitcast[Int]()[]
            fd = external_call["socket", Int32](fam, stype, proto)
            if fd >= 0:
                _set_timeout(fd, SO_SNDTIMEO, timeout_ms)
                _set_timeout(fd, SO_RCVTIMEO, timeout_ms)
                if external_call["connect", Int32](fd, aaddr, alen) == 0:
                    break
                last_err = _errno()
                _ = external_call["close", Int32](fd)
                fd = -1
            ai = p.unsafe_offset(40).unsafe_bitcast[Int]()[]
        external_call["freeaddrinfo", NoneType](head)
        keep(chost)
        keep(cport)
        keep(res)
        if fd < 0:
            raise Error("dial tcp " + host + ":" + String(port) + ": connect: " + strerror(last_err))
        var one = List[Int32](length=1, fill=1)
        _ = external_call["setsockopt", Int32](fd, Int32(IPPROTO_TCP), Int32(TCP_NODELAY), one.unsafe_ptr(), UInt32(4))
        keep(one)
        var c = Conn(fd, host)
        if tls:
            c._handshake(insecure)
        return c^

    def start_tls(mut self) raises:
        """Upgrade an established plain connection (SMTP STARTTLS)."""
        self._handshake()

    def _handshake(mut self, insecure: Bool = False) raises:
        var method = external_call["TLS_client_method", Int]()
        self.ctx = external_call["SSL_CTX_new", Int](method)
        if self.ctx == 0:
            raise Error("tls: SSL_CTX_new failed")
        _ = external_call["SSL_CTX_set_options", UInt64](self.ctx, UInt64(1 << 7))
        _ = external_call["SSL_CTX_ctrl", Int](self.ctx, Int32(123), Int(0x0303), Int(0))
        var ca = getenv("P2M_CA_FILE", getenv("SSL_CERT_FILE", ""))
        if ca.byte_length() > 0:
            var cca = _cstr(ca)
            if external_call["SSL_CTX_load_verify_locations", Int32](self.ctx, cca.unsafe_ptr(), Int(0)) != 1:
                raise Error("tls: cannot load CA file " + ca)
            keep(cca)
        else:
            _ = external_call["SSL_CTX_set_default_verify_paths", Int32](self.ctx)
        external_call["SSL_CTX_set_verify", NoneType](self.ctx, Int32(0) if insecure else Int32(1), Int(0))
        self.ssl = external_call["SSL_new", Int](self.ctx)
        var chost = _cstr(self.host)
        _ = external_call["SSL_ctrl", Int](self.ssl, Int32(55), Int(0), chost.unsafe_ptr())
        _ = external_call["SSL_set1_host", Int32](self.ssl, chost.unsafe_ptr())
        _ = external_call["SSL_set_fd", Int32](self.ssl, self.fd)
        var rc = external_call["SSL_connect", Int32](self.ssl)
        keep(chost)
        if rc != 1:
            var vr = external_call["SSL_get_verify_result", Int](self.ssl)
            raise Error("tls: handshake with " + self.host + " failed (verify=" + String(vr) + ")")

    def write_all(mut self, data: List[UInt8]) raises:
        var off = 0
        var n = len(data)
        var p = data.unsafe_ptr()
        while off < n:
            var w: Int
            if self.ssl != 0:
                w = Int(external_call["SSL_write", Int32](self.ssl, p.unsafe_offset(off), Int32(n - off)))
            else:
                w = external_call["send", Int](self.fd, p.unsafe_offset(off), n - off, Int32(0x4000))
            if w <= 0:
                raise Error("write: " + strerror(_errno()))
            off += w
        keep(data)

    def write_str(mut self, s: String) raises:
        var b = List[UInt8](capacity=s.byte_length())
        for x in s.as_bytes():
            b.append(x)
        self.write_all(b)

    def read_some(mut self, mut buf: List[UInt8], max_bytes: Int = 65536) raises -> Int:
        """Appends up to max_bytes; returns count (0 = EOF). Raises on timeout/error."""
        var old = len(buf)
        buf.resize(old + max_bytes, 0)
        var r: Int
        if self.ssl != 0:
            r = Int(external_call["SSL_read", Int32](self.ssl, buf.unsafe_ptr().unsafe_offset(old), Int32(max_bytes)))
            if r <= 0:
                var e = Int(external_call["SSL_get_error", Int32](self.ssl, Int32(r)))
                buf.resize(old, 0)
                if e == 6:
                    return 0
                if e == 5 and _errno() == 0:
                    return 0
                if e == 5 and (_errno() == 11 or _errno() == 110):
                    raise Error("i/o timeout")
                raise Error("read: tls error " + String(e) + " errno " + String(_errno()))
        else:
            r = external_call["recv", Int](self.fd, buf.unsafe_ptr().unsafe_offset(old), max_bytes, Int32(0))
            if r < 0:
                buf.resize(old, 0)
                var en = _errno()
                if en == 11:
                    raise Error("i/o timeout")
                raise Error("read: " + strerror(en))
        buf.resize(old + r, 0)
        return r

    def set_timeout_ms(mut self, ms: Int):
        _set_timeout(self.fd, SO_RCVTIMEO, ms)
        _set_timeout(self.fd, SO_SNDTIMEO, ms)

    def close(mut self):
        if self.closed:
            return
        self.closed = True
        if self.ssl != 0:
            _ = external_call["SSL_shutdown", Int32](self.ssl)
            external_call["SSL_free", NoneType](self.ssl)
            external_call["SSL_CTX_free", NoneType](self.ctx)
            self.ssl = 0
        _ = external_call["close", Int32](self.fd)

    def __del__(deinit self):
        if not self.closed:
            if self.ssl != 0:
                external_call["SSL_free", NoneType](self.ssl)
                external_call["SSL_CTX_free", NoneType](self.ctx)
            _ = external_call["close", Int32](self.fd)
