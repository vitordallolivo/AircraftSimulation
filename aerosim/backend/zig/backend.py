"""Implementação de ISimBackend com o núcleo em Zig (libaerosim, via ctypes).

As chamadas ctypes soltam o GIL, então sessões diferentes rodam em paralelo em threads.
"""
from __future__ import annotations

import ctypes
import math
import os
import subprocess
import sys
import threading

import numpy as np

from aerosim.interfaces.backend import ISimBackend, ISimSession, LogChunk, RunStatus, SimSpec, TrimKind
from . import abi

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
CORE = os.path.join(ROOT, "core")
LIB_NAMES = {"linux": "libaerosim.so", "darwin": "libaerosim.dylib", "win32": "aerosim.dll"}


def lib_path() -> str:
    name = LIB_NAMES.get(sys.platform, "libaerosim.so")
    sub = "bin" if sys.platform == "win32" else "lib"
    return os.path.join(CORE, "zig-out", sub, name)


def _zig_cmd() -> list[str]:
    try:
        import ziglang  # noqa: F401  (pip install ziglang)
        return [sys.executable, "-m", "ziglang"]
    except ImportError:
        return ["zig"]


def _sources_mtime() -> float:
    m = os.path.getmtime(os.path.join(CORE, "build.zig"))
    for d, _, fs in os.walk(os.path.join(CORE, "src")):
        for f in fs:
            if f.endswith(".zig"):
                m = max(m, os.path.getmtime(os.path.join(d, f)))
    return m


def build(fast_math: bool = True, force: bool = False) -> str:
    """compila o núcleo se a biblioteca não existir ou estiver desatualizada"""
    path = lib_path()
    if force or not os.path.exists(path) or os.path.getmtime(path) < _sources_mtime():
        cmd = _zig_cmd() + ["build", "--release=fast", f"-Dfast_math={'true' if fast_math else 'false'}"]
        subprocess.run(cmd, cwd=CORE, check=True)
    return path


def _fresh_copy(path: str) -> str:
    """cópia da biblioteca com outro nome (para carregar a recompilada no mesmo processo)"""
    import shutil
    import tempfile
    d = tempfile.mkdtemp(prefix="aerosim_lib_")
    dst = os.path.join(d, os.path.basename(path))
    shutil.copy2(path, dst)
    return dst


_ERRORS = {-1: "slot inválido", -2: "não configurado", -3: "segmento inválido", -4: "trimagem não convergiu",
           -5: "índice inválido", -10: "superfícies demais", -11: "motores demais", -12: "pontos de trem demais",
           -13: "tanques demais", -14: "segmentos demais", -15: "eventos demais", -16: "dt inválido",
           -17: "massa inválida", -18: "pontos de hélice demais"}


class CoreError(RuntimeError):
    def __init__(self, code: int, where: str):
        super().__init__(f"{where}: {_ERRORS.get(code, 'erro')} ({code})")
        self.code = code


def _check(code: int, where: str) -> int:
    if code < 0:
        raise CoreError(code, where)
    return code


class _Lib:
    """a biblioteca carregada + esquema (uma por processo)"""
    _inst: "_Lib | None" = None
    _lock = threading.Lock()

    @classmethod
    def get(cls, path: str | None = None) -> "_Lib":
        with cls._lock:
            if cls._inst is None:
                try:
                    cls._inst = _Lib(path or build())
                except abi.AbiMismatch:
                    if path:                      # biblioteca pedida explicitamente: não recompila
                        raise
                    # biblioteca velha (fontes mudaram sem a data mudar): recompila e carrega uma cópia nova
                    # (o mesmo caminho devolveria a biblioteca já carregada no processo)
                    cls._inst = _Lib(_fresh_copy(build(force=True)))
            return cls._inst

    def __init__(self, path: str):
        L = self.dll = ctypes.CDLL(path)
        c_int, c_double, c_size, vp = ctypes.c_int32, ctypes.c_double, ctypes.c_size_t, ctypes.c_void_p
        L.aerosim_schema.restype = ctypes.c_char_p
        text = L.aerosim_schema()
        self.schema = abi.parse(text.decode())
        lib_hash = None
        if hasattr(L, "aerosim_schema_hash"):
            L.aerosim_schema_hash.restype = ctypes.c_uint64
            lib_hash = int(L.aerosim_schema_hash())
        abi.check(self.schema, text, lib_hash)
        T = self.schema.types
        sig = {
            "aerosim_abi_version": (ctypes.c_uint32, []),
            "aerosim_acquire": (c_int, []),
            "aerosim_release": (None, [c_int]),
            "aerosim_params": (ctypes.POINTER(T["Params"]), [c_int]),
            "aerosim_params_reset": (c_int, [c_int]),
            "aerosim_configure": (c_int, [c_int]),
            "aerosim_reset_ground": (c_int, [c_int]),
            "aerosim_reset_air": (c_int, [c_int, c_int]),
            "aerosim_run": (c_int, [c_int, c_double, vp, c_size, ctypes.POINTER(c_size)]),
            "aerosim_events": (ctypes.POINTER(T["Events"]), [c_int]),
            "aerosim_time": (c_double, [c_int]),
            "aerosim_snapshot_size": (c_size, []),
            "aerosim_snapshot_save": (c_int, [c_int, ctypes.c_char_p]),
            "aerosim_snapshot_load": (c_int, [c_int, ctypes.c_char_p]),
            "aerosim_mass_props": (c_int, [c_int, ctypes.POINTER(T["MassProps"])]),
            "aerosim_aero_coeffs": (c_int, [c_int] + [c_double] * 6 + [ctypes.POINTER(T["AeroCoeffs"])]),
            "aerosim_aero_coeffs_ex": (c_int, [c_int] + [c_double] * 9 + [vp, ctypes.POINTER(T["AeroCoeffs"])]),
            "aerosim_linearize": (c_int, [c_int, c_double, ctypes.POINTER(T["LinModel"])]),
            "aerosim_autotune": (c_int, [c_int, c_double, ctypes.POINTER(T["Result"])]),
            "aerosim_prop_point": (c_int, [c_int, c_int, c_double, c_double, ctypes.POINTER(T["PropPoint"])]),
            "aerosim_trim": (c_int, [c_int, c_int, c_double, c_double, ctypes.POINTER(T["TrimPoint"])]),
            "aerosim_performance": (c_int, [c_int, c_double, c_double, c_double, vp, c_size]),
            "aerosim_envelope": (c_int, [c_int, ctypes.POINTER(T["EnvCfg"]), vp, c_size, ctypes.POINTER(c_double)]),
            "aerosim_envelope_curve": (c_int, [c_int, ctypes.POINTER(T["EnvCfg"]), c_double, vp, vp, vp, c_size]),
            "aerosim_simple_perf": (c_int, [ctypes.POINTER(T["SimpleCfg"]), vp, c_size, ctypes.POINTER(T["SimpleSummary"])]),
            "aerosim_sizing_defaults": (None, [ctypes.POINTER(T["SizingCfg"]), ctypes.POINTER(T["OptOpts"])]),
            "aerosim_sizing_eval": (c_int, [ctypes.POINTER(T["SizingCfg"]), vp, ctypes.POINTER(T["SizingOut"])]),
            "aerosim_sizing_optimize": (c_int, [ctypes.POINTER(T["SizingCfg"]), ctypes.POINTER(T["OptOpts"]), vp, c_size,
                                                ctypes.POINTER(c_size), ctypes.POINTER(T["SizingOut"]), vp, vp]),
            "aerosim_sizing_name": (ctypes.c_char_p, [c_int, c_int]),
        }
        absent = [n for n in sig if not hasattr(L, n)]
        if absent:
            raise abi.AbiMismatch("a biblioteca do núcleo não exporta " + ", ".join(absent) +
                                  ": ela é de outra versão dos fontes (apague core/zig-out e rode de novo)")
        for name, (res, args) in sig.items():
            fn = getattr(L, name)
            fn.restype = res
            fn.argtypes = args
        if L.aerosim_abi_version() != self.schema.abi:
            raise abi.AbiMismatch("versão do ABI não confere")
        if L.aerosim_snapshot_size() != self.schema.snapshot_size:
            raise abi.AbiMismatch("tamanho do snapshot não confere")
        self.log_dtype = self.schema.dtypes["LogRow"]
        self.perf_dtype = self.schema.dtypes["PerfRow"]
        self.env_dtype = self.schema.dtypes["EnvRow"]
        self.simple_dtype = self.schema.dtypes["SimpleRow"]


def _struct_dict(obj) -> dict[str, float]:
    return {k: getattr(obj, k) for k, _ in obj._fields_ if not k.startswith("_")}


class ZigSession(ISimSession):
    def __init__(self, lib: _Lib):
        self._lib = lib
        self._slot = _check(lib.dll.aerosim_acquire(), "acquire")
        self._spec: SimSpec = {}
        self._counts: dict[str, int] = {}

    # ------------------------------------------------------------------ configuração
    def configure(self, spec: SimSpec) -> None:
        L = self._lib.dll
        _check(L.aerosim_params_reset(self._slot), "params_reset")
        p = L.aerosim_params(self._slot).contents
        spec = dict(spec)
        for arr, cnt in (("surf", "n_surf"), ("prop", "n_prop"), ("gear", "n_gear"), ("tank", "n_tank"),
                         ("seg", "n_seg"), ("event", "n_event"), ("pads", "n_pad")):
            if arr in spec:
                spec[cnt] = len(spec[arr])
        for u in spec.get("prop", []):
            if "J" in u:
                u.setdefault("n_pts", len(u["J"]))
        abi.write(p, spec)
        _check(L.aerosim_configure(self._slot), "configure")
        self._spec = spec
        self._counts = {k: int(spec.get(k, 0)) for k in ("n_prop", "n_gear", "n_tank")}

    def derived(self) -> SimSpec:
        return abi.read(self._lib.dll.aerosim_params(self._slot).contents)

    def set(self, **overrides) -> None:
        """muda escalares sem refazer tudo (ex.: stop_t, stop_seg) — chama configure de novo"""
        p = self._lib.dll.aerosim_params(self._slot).contents
        abi.write(p, overrides)
        if any(not k.startswith("stop_") for k in overrides):   # paradas não mudam nada derivado
            _check(self._lib.dll.aerosim_configure(self._slot), "configure")

    # ------------------------------------------------------------------ corrida
    def reset_ground(self) -> None:
        _check(self._lib.dll.aerosim_reset_ground(self._slot), "reset_ground")

    def reset_air(self, segment: int) -> None:
        _check(self._lib.dll.aerosim_reset_air(self._slot, int(segment)), "reset_air")

    def run(self, t_limit: float = float("inf"), max_rows: int = 200_000) -> tuple[RunStatus, LogChunk]:
        n = ctypes.c_size_t(0)
        tl = t_limit if math.isfinite(t_limit) else 1e300
        if max_rows <= 0:          # sem registro: o núcleo roda direto até parar
            buf = np.zeros(0, dtype=self._lib.log_dtype)
            st = self._lib.dll.aerosim_run(self._slot, tl, None, 0, ctypes.byref(n))
        else:
            buf = np.zeros(int(max_rows), dtype=self._lib.log_dtype)
            st = self._lib.dll.aerosim_run(self._slot, tl, buf.ctypes.data, len(buf), ctypes.byref(n))
        _check(st if st != -1 else -2, "run")
        return RunStatus(st), self._to_chunk(buf[: n.value])

    def _to_chunk(self, rows: np.ndarray) -> LogChunk:
        cols: dict[str, np.ndarray] = {}
        active = {"rpm": "n_prop", "thrust": "n_prop", "current": "n_prop", "Ngear": "n_gear",
                  "slosh_x": "n_tank", "slosh_y": "n_tank"}
        for name in rows.dtype.names:
            v = rows[name]
            if v.ndim == 1:
                cols[name] = np.array(v)
            else:
                for i in range(self._counts.get(active.get(name, ""), v.shape[1])):
                    cols[f"{name}_{i}"] = np.array(v[:, i])
        return LogChunk(cols)

    def events(self) -> dict[str, float]:
        return _struct_dict(self._lib.dll.aerosim_events(self._slot).contents)

    @property
    def time(self) -> float:
        return float(self._lib.dll.aerosim_time(self._slot))

    def snapshot(self) -> bytes:
        buf = ctypes.create_string_buffer(self._lib.schema.snapshot_size)
        _check(self._lib.dll.aerosim_snapshot_save(self._slot, buf), "snapshot")
        return buf.raw

    def restore(self, snap: bytes) -> None:
        if len(snap) != self._lib.schema.snapshot_size:
            raise ValueError("snapshot de outra versão do núcleo")
        _check(self._lib.dll.aerosim_snapshot_load(self._slot, snap), "restore")

    # ------------------------------------------------------------------ análises estáticas
    def aero_coeffs(self, V, alpha, beta=0.0, de=0.0, da=0.0, dr=0.0):
        o = self._lib.schema.types["AeroCoeffs"]()
        _check(self._lib.dll.aerosim_aero_coeffs(self._slot, V, alpha, beta, de, da, dr, ctypes.byref(o)), "aero")
        return _struct_dict(o)

    def aero_coeffs_ex(self, V, alpha, beta=0.0, p=0.0, q=0.0, r=0.0, de=0.0, da=0.0, dr=0.0, ref=None):
        o = self._lib.schema.types["AeroCoeffs"]()
        rb = (ctypes.c_double * 3)(*ref) if ref is not None else None
        _check(self._lib.dll.aerosim_aero_coeffs_ex(self._slot, V, alpha, beta, p, q, r, de, da, dr,
                                                    ctypes.cast(rb, ctypes.c_void_p) if rb is not None else None,
                                                    ctypes.byref(o)), "aero_ex")
        return _struct_dict(o)

    def linearize(self, V):
        o = self._lib.schema.types["LinModel"]()
        st = self._lib.dll.aerosim_linearize(self._slot, V, ctypes.byref(o))
        if st not in (0, -4):
            _check(st, "linearize")
        d = {k: getattr(o, k) for k, _ in o._fields_ if not k.startswith("_") and k not in ("A", "B", "cg")}
        d["ok"] = bool(o.ok)
        d["cg"] = list(o.cg)
        d["A"] = np.array(list(o.A)).reshape(8, 8)
        d["B"] = np.array(list(o.B)).reshape(8, 4)
        return d

    def autotune(self, V):
        o = self._lib.schema.types["Result"]()
        self._lib.dll.aerosim_autotune(self._slot, V, ctypes.byref(o))
        d = {k: getattr(o, k) for k, _ in o._fields_ if not k.startswith("_")}
        d["gains"] = dict(abi.read(self._lib.dll.aerosim_params(self._slot).contents)["ap"])
        return d

    def prop_point(self, index, V, thr=1.0):
        o = self._lib.schema.types["PropPoint"]()
        _check(self._lib.dll.aerosim_prop_point(self._slot, int(index), V, thr, ctypes.byref(o)), "prop_point")
        return _struct_dict(o)

    def mass_props(self):
        o = self._lib.schema.types["MassProps"]()
        _check(self._lib.dll.aerosim_mass_props(self._slot, ctypes.byref(o)), "mass_props")
        return {"m": o.m, "cg": list(o.cg), "I": np.array(list(o.I)).reshape(3, 3), "m_liq": o.m_liq}

    def trim(self, kind: TrimKind, V: float, n: float = 1.0):
        o = self._lib.schema.types["TrimPoint"]()
        self._lib.dll.aerosim_trim(self._slot, int(kind), V, n, ctypes.byref(o))
        d = _struct_dict(o)
        d["ok"] = bool(d["ok"])
        return d

    def performance(self, V_hi, V_lo, dV):
        cap = int((V_hi - V_lo) / dV) + 2
        buf = np.zeros(cap, dtype=self._lib.perf_dtype)
        n = _check(self._lib.dll.aerosim_performance(self._slot, V_hi, V_lo, dV, buf.ctypes.data, cap), "performance")
        return {k: np.array(buf[k][:n]) for k in buf.dtype.names}

    def _env_cfg(self, cfg: dict):
        c = self._lib.schema.types["EnvCfg"]()
        abi.write(c, cfg)
        return c

    def envelope(self, cfg):
        c = self._env_cfg(cfg)
        cap = int(c.h_max / c.h_step) + 2
        buf = np.zeros(cap, dtype=self._lib.env_dtype)
        ceil = ctypes.c_double(0)
        n = _check(self._lib.dll.aerosim_envelope(self._slot, ctypes.byref(c), buf.ctypes.data, cap,
                                                  ctypes.byref(ceil)), "envelope")
        return {k: np.array(buf[k][:n]) for k in buf.dtype.names}, float(ceil.value)

    def envelope_curve(self, cfg, h, n=200):
        c = self._env_cfg(cfg)
        V, Td, Tr = (np.zeros(n) for _ in range(3))
        _check(self._lib.dll.aerosim_envelope_curve(self._slot, ctypes.byref(c), h, V.ctypes.data, Td.ctypes.data,
                                                    Tr.ctypes.data, n), "envelope_curve")
        return {"V": V, "Td": Td, "Tr": Tr, "Pd": Td * V, "Pr": Tr * V}

    def close(self) -> None:
        if self._slot >= 0:
            self._lib.dll.aerosim_release(self._slot)
            self._slot = -1

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass


class ZigBackend(ISimBackend):
    name = "zig"

    def __init__(self, lib_path: str | None = None):
        from .translator import ZigTranslator
        self._lib = _Lib.get(lib_path)
        self._translator = ZigTranslator()

    @property
    def translator(self):
        return self._translator

    def open_session(self) -> ZigSession:
        return ZigSession(self._lib)

    def limits(self) -> dict[str, int]:
        return dict(self._lib.schema.limits)

    def log_channels(self) -> list[str]:
        return list(self._lib.log_dtype.names)

    # ------------------------------------------------------------------ dimensionamento inicial (mini-MDO)
    _SIZING_PROGRESS = ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.c_void_p, ctypes.c_int32, ctypes.c_size_t)

    def sizing_names(self) -> dict[str, list[str]]:
        """os índices do núcleo: grandezas, variáveis, tipos de aeronave e otimizadores"""
        out = {}
        for what, key in enumerate(("quantities", "variables", "kinds", "methods")):
            names, i = [], 0
            while (s := self._lib.dll.aerosim_sizing_name(what, i)) is not None:
                names.append(s.decode())
                i += 1
            out[key] = names
        return out

    def _sizing_structs(self, cfg: dict, opts: dict | None = None):
        T = self._lib.schema.types
        c, o = T["SizingCfg"](), T["OptOpts"]()
        self._lib.dll.aerosim_sizing_defaults(ctypes.byref(c), ctypes.byref(o))   # padrões do núcleo
        abi.write(c, cfg)
        abi.write(o, opts or {})
        return c, o

    def sizing_eval(self, cfg: dict, x) -> dict:
        c, _ = self._sizing_structs(cfg)
        xs = (ctypes.c_double * len(x))(*[float(v) for v in x])
        out = self._lib.schema.types["SizingOut"]()
        _check(self._lib.dll.aerosim_sizing_eval(ctypes.byref(c), xs, ctypes.byref(out)), "sizing_eval")
        return abi.read(out)

    def sizing_optimize(self, cfg: dict, opts: dict | None = None, progress=None, cancel=None):
        """(indivíduos: array estruturado, melhor: dict). `progress(iteração, indivíduos até agora)` é
        chamado a cada iteração (do thread de quem chamou); `cancel` (threading.Event) para no fim dela"""
        c, o = self._sizing_structs(cfg, opts)
        cap = max(int(o.particles), 1) * max(int(o.iterations), 1)
        buf = np.zeros(cap, dtype=self._lib.schema.dtypes["Individual"])
        n = ctypes.c_size_t(0)
        best = self._lib.schema.types["SizingOut"]()

        def cb(_ctx, it, k):
            try:
                if progress is not None:
                    progress(int(it), buf[:k].copy())
            except Exception:
                pass
            return 1 if (cancel is not None and cancel.is_set()) else 0
        fn = self._SIZING_PROGRESS(cb)
        _check(self._lib.dll.aerosim_sizing_optimize(ctypes.byref(c), ctypes.byref(o), buf.ctypes.data, cap,
                                                     ctypes.byref(n), ctypes.byref(best),
                                                     ctypes.cast(fn, ctypes.c_void_p), None), "sizing_optimize")
        return buf[:n.value].copy(), abi.read(best)

    def simple_performance(self, cfg: dict) -> tuple[dict, dict]:
        T = self._lib.schema.types
        c = T["SimpleCfg"]()
        # a struct ctypes nasce zerada: os padrões do núcleo (simple_perf.zig) vêm daqui
        cfg = dict(dict(W=100.0, S=1.0, CD0=0.03, K=0.06, CLmax=1.4, rho0=1.225, h=0.0, T0=288.15, lapse=-0.0065,
                        Rgas=287.053, phi_T=0.0, rho_exp=1.0, V_lo=1.0, V_hi=30.0, dV=0.5, n_load=2.0, bat_Rt=1.0,
                        bat_C=5.0, bat_n=1.05, bat_V=22.2, bat_eta=0.6), **cfg)
        if "thr_V" in cfg:
            cfg["n_thr"] = len(cfg["thr_V"])
        if "bank" in cfg:
            cfg["bank"] = list(cfg["bank"])[:8]
            cfg["n_bank"] = len(cfg["bank"])
        abi.write(c, cfg)
        cap = int((c.V_hi - c.V_lo) / c.dV) + 2
        buf = np.zeros(cap, dtype=self._lib.simple_dtype)
        s = T["SimpleSummary"]()
        n = _check(self._lib.dll.aerosim_simple_perf(ctypes.byref(c), buf.ctypes.data, cap, ctypes.byref(s)),
                   "simple_perf")
        rows = {}
        for k in buf.dtype.names:
            v = np.array(buf[k][:n])
            if v.ndim == 1:
                rows[k] = v
            else:
                for i in range(c.n_bank):
                    rows[f"{k}_{i}"] = v[:, i]
        return rows, _struct_dict(s)

    @property
    def schema(self) -> abi.Schema:
        return self._lib.schema
