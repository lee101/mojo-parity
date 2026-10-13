"""Raw pointer helper: hot loops address shared read-mostly buffers without origin tracking."""


@always_inline
def raw[T: AnyType](p: Pointer[T, _]) -> Pointer[T, MutUntrackedOrigin]:
    return p.unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin]()


@no_inline
def keep[T: AnyType](ref x: T):
    """Marks x as used here. Mojo destroys values after their last syntactic use,
    and an untracked raw pointer does not count, so values reached only through
    raw pointers (e.g. inside parallel closures) must be kept alive explicitly."""
    pass
