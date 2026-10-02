"""Implementações da camada Sim (ISimBackend)."""


def default_backend():
    from .zig import ZigBackend
    return ZigBackend()
