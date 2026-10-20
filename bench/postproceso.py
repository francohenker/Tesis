"""Postprocesamiento de una ejecución (sección 3.6.4 de la tesis).

Convierte los datos crudos de los trabajadores en los valores resumen de la
Tabla 3.33. Los percentiles se calculan de forma EXACTA sobre todas las
observaciones (interpolación lineal, igual que numpy.percentile por defecto),
sin aproximaciones por histograma.
"""
from __future__ import annotations

import array
import gzip
import json
import math
import sys
from pathlib import Path
from typing import Any

from .cliente import NEG, OK, OP_IDS
from .util import leer_json

_COLUMNAS = (("op", "B"), ("st", "B"), ("t", "I"), ("lat", "I"))


def fusionar_trabajadores(dir_tmp: Path, n: int) -> tuple[dict[str, array.array], list[dict]]:
    """Une las bitácoras de los n trabajadores. Devuelve (columnas, resúmenes por trabajador)."""
    cols = {nombre: array.array(tipo) for nombre, tipo in _COLUMNAS}
    resumenes: list[dict] = []
    for k in range(n):
        ruta_json = dir_tmp / f"w{k}.json"
        if not ruta_json.exists():
            resumenes.append({"indice": k, "estado": "sin_datos", "error": "el trabajador no dejó resultados"})
            continue
        resumenes.append(leer_json(ruta_json))
        for nombre, tipo in _COLUMNAS:
            arr = array.array(tipo)
            ruta = dir_tmp / f"w{k}.{nombre}"
            tam = ruta.stat().st_size
            if tam:
                with open(ruta, "rb") as f:
                    arr.fromfile(f, tam // arr.itemsize)
            cols[nombre].extend(arr)
    return cols, resumenes


def escribir_lat(ruta: Path, cols: dict[str, array.array], extra: dict | None = None) -> None:
    """Archivo .lat.gz: una línea de cabecera JSON y luego las 4 columnas en binario."""
    cab = {"formato": "columnar-v1", "n": len(cols["op"]), "orden_bytes": sys.byteorder, "ops": OP_IDS,
           "columnas": [{"nombre": nombre, "tipo": tipo} for nombre, tipo in _COLUMNAS],
           "estados": {"0": "ok", "1": "error_tecnico", "2": "evento_negocio"},
           "unidades": {"t": "us desde inicio de ventana", "lat": "us"}}
    if extra:
        cab.update(extra)
    with gzip.open(ruta, "wb", compresslevel=6) as f:
        f.write((json.dumps(cab) + "\n").encode("utf-8"))
        for nombre, _t in _COLUMNAS:
            f.write(cols[nombre].tobytes())


def leer_lat(ruta: Path) -> tuple[dict, dict[str, array.array]]:
    with gzip.open(ruta, "rb") as f:
        cab = json.loads(f.readline().decode("utf-8"))
        cols = {}
        for c in cab["columnas"]:
            arr = array.array(c["tipo"])
            arr.frombytes(f.read(cab["n"] * arr.itemsize))
            cols[c["nombre"]] = arr
    return cab, cols


def percentil(ordenados, p: float) -> float:
    """Percentil p (0-100) con interpolación lineal sobre datos ya ordenados."""
    n = len(ordenados)
    if n == 0:
        return float("nan")
    if n == 1:
        return float(ordenados[0])
    pos = (p / 100.0) * (n - 1)
    lo = int(math.floor(pos))
    hi = min(lo + 1, n - 1)
    return float(ordenados[lo]) + (float(ordenados[hi]) - float(ordenados[lo])) * (pos - lo)


def resumen_valores(valores_us, *, unidad_div: float = 1000.0) -> dict[str, Any]:
    """n, media, mediana, p95, p99, máximo y desvío muestral (µs -> ms)."""
    n = len(valores_us)
    if n == 0:
        return {"n": 0, "media": None, "mediana": None, "p95": None, "p99": None, "max": None, "desvio": None}
    orden = sorted(valores_us)
    media = sum(orden) / n
    desvio = math.sqrt(sum((x - media) ** 2 for x in orden) / (n - 1)) if n > 1 else 0.0
    r = lambda x: round(x / unidad_div, 6)  # noqa: E731
    return {"n": n, "media": r(media), "mediana": r(percentil(orden, 50)), "p95": r(percentil(orden, 95)),
            "p99": r(percentil(orden, 99)), "max": r(orden[-1]), "desvio": r(desvio)}


def resumir_latencias(cols: dict[str, array.array]) -> dict[str, Any]:
    """Latencia por operación y global (solo operaciones OK)."""
    por_op: dict[int, array.array] = {}
    todas = array.array("I")
    conteo = {"ok": 0, "tecnicos": 0, "negocio": 0}
    for op, st, lat in zip(cols["op"], cols["st"], cols["lat"]):
        if st == OK:
            por_op.setdefault(op, array.array("I")).append(lat)
            todas.append(lat)
            conteo["ok"] += 1
        elif st == NEG:
            conteo["negocio"] += 1
        else:
            conteo["tecnicos"] += 1
    salida = {"global": resumen_valores(todas)}
    for op in sorted(por_op):
        salida[OP_IDS[op]] = resumen_valores(por_op[op])
    return {"latencia_ms": salida, "conteo": conteo}


def resumir_linea_base(resumenes: list[dict]) -> dict[str, Any]:
    vals: list = []
    for r in resumenes:
        vals.extend(r.get("baseline_us", []))
    r = resumen_valores(vals)
    return {"n": r["n"], "mediana": r["mediana"], "p95": r["p95"], "media": r["media"]}


def duracion_efectiva_s(resumenes: list[dict], t_ventana_ns: int) -> float:
    fines = [r["t_ultimo_fin_ns"] for r in resumenes if r.get("t_ultimo_fin_ns")]
    return max(0.0, (max(fines) - t_ventana_ns) / 1e9) if fines else 0.0


def resumir_fases(resumenes: list[dict]) -> dict[str, Any]:
    """W3: duración y filas/s de cada fase (de la primera salida a la última llegada)."""
    fases: dict[str, Any] = {}
    nombres = {f for r in resumenes for f in r.get("fases", {})}
    for f in sorted(nombres):
        datos = [r["fases"][f] for r in resumenes if f in r.get("fases", {})]
        dur = (max(d["t_fin_ns"] for d in datos) - min(d["t_ini_ns"] for d in datos)) / 1e9
        filas = sum(d["filas"] for d in datos)
        fases[f] = {"segundos": round(dur, 4), "filas": filas, "ops": sum(d["ops"] for d in datos),
                    "filas_por_s": round(filas / dur, 2) if dur > 0 else None}
    return fases


def errores_totales(resumenes: list[dict]) -> dict[str, Any]:
    det = {"deadlock": 0, "timeout": 0, "conexion": 0, "otro": 0}
    neg = reco = 0
    for r in resumenes:
        for k, v in r.get("errores", {}).items():
            det[k] = det.get(k, 0) + v
        neg += r.get("negocio", 0)
        reco += r.get("reconexiones", 0)
    return {"tecnicos": sum(det.values()), "detalle": det, "negocio_stock": neg, "reconexiones": reco}


def resumir_recursos(ini: dict, fin: dict, serie: list[dict], t_ini_ns: int, t_fin_ns: int,
                     n_ops: int, cpus_cliente: list[int]) -> dict[str, Any]:
    """CPU, RAM e I/O sobre la ventana, a partir de instantáneas exactas y de la serie de 1 s."""
    dt_s = max((fin["t_ns"] - ini["t_ns"]) / 1e9, 1e-9)
    cpu_s = (fin["motor"]["cpu_usec"] - ini["motor"]["cpu_usec"]) / 1e6
    ventana = [f for f in serie if t_ini_ns <= f["t_ns"] <= t_fin_ns]
    max_pct = None
    for a, b in zip(serie, serie[1:]):
        if a["t_ns"] >= t_ini_ns and b["t_ns"] <= t_fin_ns + 1_500_000_000:
            d = (b["t_ns"] - a["t_ns"]) / 1e9
            if d > 0:
                p = 100.0 * ((b["cpu_usec"] - a["cpu_usec"]) / 1e6) / d
                max_pct = p if max_pct is None else max(max_pct, p)
    res_mb = [(f["anon"] + f["shmem"]) / 1e6 for f in ventana]
    cache_mb = [f["file"] / 1e6 for f in ventana]
    cli = None
    if len(ventana) >= 2:
        o = ventana[-1]["cli_ocupado"] - ventana[0]["cli_ocupado"]
        t = ventana[-1]["cli_total"] - ventana[0]["cli_total"]
        cli = 100.0 * o / t if t > 0 else None
    d_ini, d_fin = ini["sistema"]["disco"], fin["sistema"]["disco"]
    leido = (d_fin["rd_sectors"] - d_ini["rd_sectors"]) * 512 / 1e6
    escrito = (d_fin["wr_sectors"] - d_ini["wr_sectors"]) * 512 / 1e6
    return {
        "cpu": {"media_pct": round(100.0 * cpu_s / dt_s, 3), "max_pct": None if max_pct is None else round(max_pct, 3),
                "cpu_s": round(cpu_s, 4), "cpu_s_por_op": round(cpu_s / n_ops, 8) if n_ops else None},
        "ram_mb": {"residente_media": round(sum(res_mb) / len(res_mb), 2) if res_mb else None,
                   "residente_max": round(max(res_mb), 2) if res_mb else None,
                   "cache_archivos_media": round(sum(cache_mb) / len(cache_mb), 2) if cache_mb else None},
        "io": {"leido_mb": round(leido, 3), "escrito_mb": round(escrito, 3),
               "lecturas": d_fin["rd_ios"] - d_ini["rd_ios"], "escrituras": d_fin["wr_ios"] - d_ini["wr_ios"],
               "leido_mb_s": round(leido / dt_s, 3), "escrito_mb_s": round(escrito / dt_s, 3)},
        "cliente_cpu_pct": None if cli is None else round(cli, 2),
        "swap": {"pswpin": fin["sistema"]["swap"]["pswpin"] - ini["sistema"]["swap"]["pswpin"],
                 "pswpout": fin["sistema"]["swap"]["pswpout"] - ini["sistema"]["swap"]["pswpout"]},
        "muestras_monitor": len(ventana), "ventana_s": round(dt_s, 3),
    }
