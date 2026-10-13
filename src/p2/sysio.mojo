"""Single-signature libc file wrappers. Every module must call a C symbol with
one signature program-wide, so all file syscalls go through here."""

from std.ffi import external_call

comptime PB = Pointer[UInt8, MutUntrackedOrigin]


@always_inline
def c_open(path: Pointer[UInt8, _], flags: Int32, mode: UInt32) -> Int32:
    return external_call["open64", Int32](path, flags, mode)


@always_inline
def c_write(fd: Int32, p: Pointer[UInt8, _], n: Int) -> Int:
    return external_call["__write", Int](fd, p, n)


@always_inline
def c_read(fd: Int32, p: Pointer[UInt8, _], n: Int) -> Int:
    return external_call["read", Int](fd, p, n)


@always_inline
def c_close(fd: Int32) -> Int32:
    return external_call["close", Int32](fd)
