"""Núcleo de simulação em Zig (core/) exposto como ISimBackend."""
from .backend import CoreError, ZigBackend, ZigSession, build, lib_path

__all__ = ["CoreError", "ZigBackend", "ZigSession", "build", "lib_path"]
