"""Consolidación de resultados en CSV (sección 3.6.4).

La unidad estadística es la EJECUCIÓN: cada combinación aporta hasta 30 valores
(uno por ejecución válida). Los IC al 95 % usan la distribución t de Student
con n-1 grados de libertad. Las ejecuciones descartadas no entran en los
promedios, pero se cuentan para documentar cuántas hubo.
"""
from __future__ import annotations

import csv
import math
import statistics
from pathlib import Path
from typing import Any, Iterable

from .config import Config
from .util import leer_json

# t de Student, cuantil 0,975 (bilateral 95 %)
_T975 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228,
         11: 2.201, 12: 2.179, 13: 2.160, 14: 2.145, 15: 2.131, 16: 2.120, 17: 2.110, 18: 2.101, 19: 2.093,
         20: 2.086, 21: 2.080, 22: 2.074, 23: 2.069, 24: 2.064, 25: 2.060, 26: 2.056, 27: 2.052, 28: 2.048,
         29: 2.045, 30: 2.042, 40: 2.021, 60: 2.000, 120: 1.980}


def t975(gl: int) -> float:
    if gl <= 0:
        return float("nan")
    if gl in _T975:
        return _T975[gl]
    if gl > 120:
        return 1.960
    claves = sorted(_T975)
    for a, b in zip(claves, claves[1:]):
        if a < gl < b:
            return _T975[a] + (_T975[b] - _T975[a]) * (gl - a) / (b - a)
    return 1.960


def estadisticos(valores: Iterable[float]) -> dict[str, float | None]:
    v = [x for x in valores if x is not None and not (isinstance(x, float) and math.isnan(x))]
    n = len(v)
    if n == 0:
        return {"n": 0, "media": None, "desvio": None, "cv_pct": None, "ic95_inf": None, "ic95_sup": None,
                "mediana": None, "min": None, "max": None}
    media = statistics.fmean(v)
    sd = statistics.stdev(v) if n > 1 else 0.0
    semi = t975(n - 1) * sd / math.sqrt(n) if n > 1 else float("nan")
    return {"n": n, "media": media, "desvio": sd, "cv_pct": 100 * sd / media if media else None,
            "ic95_inf": media - semi if n > 1 else None, "ic95_sup": media + semi if n > 1 else None,
            "mediana": statistics.median(v), "min": min(v), "max": max(v)}


def cargar_resultados(cfg: Config, campanas: list[str] | None = None) -> tuple[list[dict], dict[str, int]]:
    base = cfg.dir_resultados / "datos"
    validos, descartes = [], {}
    if not base.exists():
        return [], {}
    for d in sorted(base.iterdir()):
        if not d.is_dir() or (campanas and d.name not in campanas):
            continue
        for f in sorted(d.glob("*.json")):
            if ".descartada-" in f.name:
                rid = f.name.split(".descartada-")[0]
                descartes[rid] = descartes.get(rid, 0) + 1
                continue
            validos.append(leer_json(f))
        for f in sorted((d / "descartes_archivados").glob("*.json")):   # ver orquestador --reintentar-agotadas
            rid = f.name.split(".descartada-")[0]
            descartes[rid] = descartes.get(rid, 0) + 1
    return validos, descartes


def _g(d: dict, ruta: str, defecto: Any = None) -> Any:
    for p in ruta.split("."):
        if not isinstance(d, dict) or p not in d:
            return defecto
        d = d[p]
    return d


COLUMNAS_EJEC = [
    ("tps", "tps"), ("tps_ok", "tps_ok"),
    ("lat_media_ms", "latencia_ms.global.media"), ("lat_mediana_ms", "latencia_ms.global.mediana"),
    ("lat_p95_ms", "latencia_ms.global.p95"), ("lat_p99_ms", "latencia_ms.global.p99"),
    ("lat_max_ms", "latencia_ms.global.max"), ("linea_base_mediana_ms", "linea_base_ms.mediana"),
    ("cpu_media_pct", "recursos.cpu.media_pct"), ("cpu_max_pct", "recursos.cpu.max_pct"),
    ("cpu_s_por_op", "recursos.cpu.cpu_s_por_op"), ("ram_residente_media_mb", "recursos.ram_mb.residente_media"),
    ("ram_residente_max_mb", "recursos.ram_mb.residente_max"), ("io_leido_mb", "recursos.io.leido_mb"),
    ("io_escrito_mb", "recursos.io.escrito_mb"), ("io_escrito_mb_s", "recursos.io.escrito_mb_s"),
    ("cliente_cpu_pct", "recursos.cliente_cpu_pct"), ("ops_ok", "operaciones.ok"),
    ("ops_negocio", "operaciones.negocio"), ("errores_tecnicos", "errores.tecnicos"),
]
METRICAS_COMB = ["tps", "lat_media_ms", "lat_mediana_ms", "lat_p95_ms", "lat_p99_ms", "lat_max_ms",
                 "cpu_media_pct", "ram_residente_media_mb", "io_escrito_mb_s", "cpu_s_por_op"]
CLAVE_COMB = ("campana", "motor", "estrategia", "carga", "concurrencia")


def fila_ejecucion(r: dict) -> dict:
    f = {k: r.get(k) for k in ("run_id", "campana", "motor", "tipo_motor", "estrategia", "carga",
                               "concurrencia", "repeticion", "semilla", "intento")}
    for nombre, ruta in COLUMNAS_EJEC:
        f[nombre] = _g(r, ruta)
    f["version_motor"] = r.get("version_motor")
    f["advertencias"] = ";".join(_g(r, "validez.advertencias", []) or [])
    f["inicio_utc"] = r.get("inicio_utc")
    return f


def _escribir(ruta: Path, filas: list[dict], columnas: list[str] | None = None) -> None:
    ruta.parent.mkdir(parents=True, exist_ok=True)
    columnas = columnas or (list(filas[0]) if filas else [])
    with open(ruta, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=columnas, extrasaction="ignore")
        w.writeheader()
        for fila in filas:
            w.writerow({k: ("" if v is None else v) for k, v in fila.items()})


def consolidar(cfg: Config, campanas: list[str] | None = None) -> dict[str, Any]:
    res, descartes = cargar_resultados(cfg, campanas)
    out = cfg.dir_resultados / "consolidado"
    if not res:
        return {"ejecuciones": 0}
    ejec = [fila_ejecucion(r) for r in res]
    _escribir(out / "resumen_ejecuciones.csv", ejec)

    ops = []
    for r in res:
        for op, v in (r.get("latencia_ms") or {}).items():
            if op == "global":
                continue
            ops.append({"run_id": r["run_id"], "campana": r["campana"], "motor": r["motor"],
                        "estrategia": r["estrategia"], "carga": r["carga"], "concurrencia": r["concurrencia"],
                        "repeticion": r["repeticion"], "operacion": op, **{k: v[k] for k in
                                                                            ("n", "media", "mediana", "p95", "p99", "max")}})
    _escribir(out / "resumen_operaciones.csv", ops,
              ["run_id", "campana", "motor", "estrategia", "carga", "concurrencia", "repeticion", "operacion",
               "n", "media", "mediana", "p95", "p99", "max"])

    fases = []
    for r in res:
        for f, v in (r.get("fases") or {}).items():
            fases.append({"run_id": r["run_id"], "motor": r["motor"], "estrategia": r["estrategia"],
                          "concurrencia": r["concurrencia"], "repeticion": r["repeticion"], "fase": f, **v})
        for ix in r.get("reindex") or []:
            fases.append({"run_id": r["run_id"], "motor": r["motor"], "estrategia": r["estrategia"],
                          "concurrencia": r["concurrencia"], "repeticion": r["repeticion"],
                          "fase": f"R:{ix['indice']}", "segundos": ix["segundos"]})
    if fases:
        _escribir(out / "fases_w3.csv", fases, ["run_id", "motor", "estrategia", "concurrencia", "repeticion",
                                                "fase", "segundos", "filas", "ops", "filas_por_s"])

    grupos: dict[tuple, list[dict]] = {}
    for f in ejec:
        grupos.setdefault(tuple(f[k] for k in CLAVE_COMB), []).append(f)
    comb, alertas = [], []
    for clave, filas in sorted(grupos.items(), key=lambda kv: tuple(str(x) for x in kv[0])):
        base = dict(zip(CLAVE_COMB, clave))
        base["ejecuciones_validas"] = len(filas)
        base["descartes"] = sum(descartes.get(f["run_id"], 0) for f in filas)
        for m in METRICAS_COMB:
            e = estadisticos([f.get(m) for f in filas])
            for k, v in e.items():
                base[f"{m}_{k}"] = v
        cv = base.get("tps_cv_pct")
        if cv is not None and cv > cfg.get("validez.cv_tps_max_pct"):
            alertas.append({**{k: base[k] for k in CLAVE_COMB}, "cv_tps_pct": round(cv, 2)})
        comb.append(base)
    _escribir(out / "resumen_combinaciones.csv", comb)
    if alertas:
        _escribir(out / "alertas_cv_tps.csv", alertas)
    return {"ejecuciones": len(res), "combinaciones": len(comb), "descartes": sum(descartes.values()),
            "alertas_cv": len(alertas), "directorio": str(out)}
