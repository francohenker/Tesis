"""Verificación cruzada del cliente propio contra Sysbench (oltp_point_select).

Objetivo: comprobar que el cliente propio mide lo mismo que una herramienta
estándar y ampliamente usada en un caso donde ambas pueden ejecutar la MISMA
operación (SELECT c FROM sbtest1 WHERE id = ?). No reemplaza la medición
principal: es una prueba de validez de instrumento.

Criterio: para cada nivel de concurrencia se calcula la razón de TPS
PostgreSQL/MySQL con el cliente propio y con Sysbench. Si difieren más del
umbral (por defecto 20 %), el cliente introduce un sesgo y debe revisarse.
La razón entre motores es la magnitud relevante para la tesis; los valores
absolutos pueden diferir (Sysbench es C/Lua, el cliente propio es Python).

Configuración equivalente en ambas herramientas: sin sentencias preparadas del
servidor (--db-ps-mode=disable), distribución uniforme de las claves
(--rand-type=uniform), una sola sentencia por evento, TCP local sin TLS, y la
misma imagen base restaurada antes de cada medición.
"""
from __future__ import annotations

import csv
import random
import re
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any

from . import motor as mot
from .config import Config
from .corrida import capturar_entorno, ejecutar_corrida
from .consolidar import estadisticos
from .db import Conexion
from .recursos import esperar_reposo
from .util import ErrorBench, derivar_semilla, escribir_json, leer_json, log, ahora_utc_iso


# ------------------------------------------------------------- preparación
def _args_conexion(m: dict, base: str, pw: str) -> list[str]:
    pre = "pgsql" if m["tipo"] == "postgresql" else "mysql"
    return [f"--db-driver={pre}", f"--{pre}-host={m['host']}", f"--{pre}-port={m['puerto']}",
            f"--{pre}-user={m['usuario']}", f"--{pre}-password={pw}", f"--{pre}-db={base}"]


def _password(m: dict) -> str:
    import os
    env = m.get("password_env")
    return os.environ.get(env, "") if env and env in os.environ else m.get("password", "")


def _sysbench(cfg: Config, m: dict, base: str, comando: str, extra: list[str], timeout: float) -> subprocess.CompletedProcess:
    sb = cfg.get("sysbench")
    cmd = [sb["binario"], "oltp_point_select", "--tables=1", f"--table-size={sb['filas']}",
           "--rand-type=uniform", "--db-ps-mode=disable", "--report-interval=0",
           *_args_conexion(m, base, _password(m)), *extra, comando]
    log.debug("sysbench: %s", " ".join(c if "password" not in c else "--*-password=***" for c in cmd))
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def preparar_imagen(cfg: Config, motor: str) -> None:
    """Crea la base `sbtest` con sbtest1 sobre la imagen E0 y la guarda como imagen «sysbench»."""
    ctl = mot.ControlMotor(cfg, motor)
    sb = cfg.get("sysbench")
    ctl.detener()
    ctl.restaurar("E0")
    ctl.iniciar()
    con = ctl.esperar_disponible()
    try:
        if ctl.tipo == "postgresql":
            if not con.consultar("SELECT 1 FROM pg_database WHERE datname = %s", (sb["base"],)):
                con.ejecutar(f'CREATE DATABASE "{sb["base"]}"')
        else:
            con.ejecutar(f"CREATE DATABASE IF NOT EXISTS `{sb['base']}`")
    finally:
        con.cerrar()
    r = _sysbench(cfg, ctl.m, sb["base"], "prepare", [], 7200)
    if r.returncode != 0:
        raise ErrorBench(f"sysbench prepare falló: {(r.stderr or r.stdout)[-500:]}")
    con = Conexion(ctl.m, base=sb["base"], exigir_cext=False)
    try:
        con.ejecutar_leyendo("ANALYZE sbtest1" if ctl.tipo == "postgresql" else "ANALYZE TABLE sbtest1")
        if ctl.tipo == "postgresql":
            con.ejecutar("VACUUM (ANALYZE) sbtest1")
    finally:
        con.cerrar()
    ctl.detener()
    ctl.copiar_a_imagen("sysbench")
    ctl.registrar_huella_imagen("sysbench", True)
    log.info("[%s] imagen sysbench lista (%d filas)", motor, sb["filas"])


# ----------------------------------------------------------------- análisis
_RE_TPS = re.compile(r"transactions:\s+(\d+)\s+\(([\d.]+) per sec\.\)")
_RE_QPS = re.compile(r"queries:\s+(\d+)\s+\(([\d.]+) per sec\.\)")
_RE_AVG = re.compile(r"^\s*avg:\s+([\d.]+)", re.M)
_RE_P95 = re.compile(r"95th percentile:\s+([\d.]+)")
_RE_MAX = re.compile(r"^\s*max:\s+([\d.]+)", re.M)
_RE_ERR = re.compile(r"ignored errors:\s+(\d+)")


def analizar_salida(texto: str) -> dict[str, Any]:
    """Extrae TPS y latencias (ms) del informe final de Sysbench."""
    def f(rx, i=1):
        m = rx.search(texto)
        return float(m.group(i)) if m else None
    return {"transacciones": f(_RE_TPS), "tps": f(_RE_TPS, 2), "qps": f(_RE_QPS, 2), "lat_media_ms": f(_RE_AVG),
            "lat_p95_ms": f(_RE_P95), "lat_max_ms": f(_RE_MAX), "errores_ignorados": f(_RE_ERR) or 0}


def ejecutar_sysbench(cfg: Config, ctl: mot.ControlMotor, hilos: int, semilla: int) -> dict[str, Any]:
    sb = cfg.get("sysbench")
    esperar_reposo(cfg.get("general.reposo_cpu_max_pct"), cfg.get("general.reposo_espera_max_s"))
    ctl.detener()
    ctl.restaurar("sysbench")
    ctl.vaciar_cache()
    ctl.iniciar()
    ctl.esperar_disponible().cerrar()
    comun = [f"--threads={hilos}", f"--rand-seed={semilla % (2**31)}"]
    try:
        if sb["calentamiento_s"]:
            _sysbench(cfg, ctl.m, sb["base"], "run", [*comun, f"--time={sb['calentamiento_s']}"], sb["calentamiento_s"] + 120)
        r = _sysbench(cfg, ctl.m, sb["base"], "run", [*comun, f"--time={sb['tiempo_s']}"], sb["tiempo_s"] + 300)
    finally:
        ctl.detener()
    if r.returncode != 0:
        raise ErrorBench(f"sysbench run falló: {(r.stderr or r.stdout)[-500:]}")
    return {**analizar_salida(r.stdout), "salida": r.stdout[-3000:]}


def comparar(own: dict[tuple, list[float]], sbv: dict[tuple, list[float]], motores: list[str],
             hilos: list[int], umbral_pct: float) -> list[dict]:
    """Razón de TPS entre los dos motores con cada herramienta y desviación relativa."""
    if len(motores) != 2:
        return []
    a, b = sorted(motores)
    filas = []
    for h in hilos:
        fila: dict[str, Any] = {"hilos": h, "motor_a": a, "motor_b": b}
        for nombre, datos in (("propio", own), ("sysbench", sbv)):
            va, vb = datos.get((a, h), []), datos.get((b, h), [])
            ma, mb = (sum(va) / len(va) if va else None), (sum(vb) / len(vb) if vb else None)
            fila[f"tps_{a}_{nombre}"], fila[f"tps_{b}_{nombre}"] = ma, mb
            fila[f"razon_{nombre}"] = ma / mb if ma and mb else None
        rp, rs = fila["razon_propio"], fila["razon_sysbench"]
        fila["desviacion_pct"] = abs(rp / rs - 1) * 100 if rp and rs else None
        fila["supera_umbral"] = (fila["desviacion_pct"] > umbral_pct) if fila["desviacion_pct"] is not None else None
        filas.append(fila)
    return filas


def ejecutar_verificacion(cfg: Config, repeticiones: int | None = None) -> dict[str, Any]:
    sb = cfg.get("sysbench")
    reps = repeticiones or sb["repeticiones"]
    motores = sorted(cfg.motores)
    hilos = list(sb["hilos"])
    ctls = {m: mot.ControlMotor(cfg, m) for m in motores}
    faltan = [m for m in motores if not ctls[m].existe_imagen("sysbench")]
    if faltan:
        raise ErrorBench(f"Falta la imagen «sysbench» de {faltan}. Cree con: python -m bench sysbench-preparar")
    entorno = capturar_entorno(cfg)
    maestra = cfg.req("general.semilla_maestra")
    dir_out = cfg.dir_resultados / "verificacion"
    dir_out.mkdir(parents=True, exist_ok=True)
    own: dict[tuple, list[float]] = {}
    sbv: dict[tuple, list[float]] = {}
    crudo: list[dict] = []
    combos = [(m, h, i) for m in motores for h in hilos for i in range(1, reps + 1)]
    for bloque in range(1, reps + 1):
        orden = [c for c in combos if c[2] == bloque]
        random.Random(derivar_semilla(maestra, "verificacion", bloque)).shuffle(orden)
        for m, h, i in orden:
            sem = derivar_semilla(maestra, "SB1", h, i)
            rid = f"verificacion-{m}-sysbench-SB1-c{h:03d}-i{i:03d}"
            ruta = dir_out / f"{rid}.sysbench.json"
            if ruta.exists():
                r_sb = leer_json(ruta)
            else:
                r_sb = {"run_id": rid, **ejecutar_sysbench(cfg, ctls[m], h, sem)}
                escribir_json(ruta, r_sb)
                time.sleep(cfg.get("general.cooldown_s"))
            item = {"run_id": rid, "campana": "verificacion", "motor": m, "estrategia": "sysbench", "carga": "SB1",
                    "concurrencia": h, "repeticion": i, "bloque": i, "semilla": sem, "calentar": True}
            ruta_own = cfg.dir_resultados / "datos" / "verificacion" / f"{rid}.json"
            if ruta_own.exists():
                r_own = leer_json(ruta_own)
            else:
                r_own = ejecutar_corrida(cfg, ctls[m], item, intento=1, entorno=entorno)
                time.sleep(cfg.get("general.cooldown_s"))
            if r_own["validez"]["valida"] and r_sb.get("tps"):
                own.setdefault((m, h), []).append(r_own["tps"])
                sbv.setdefault((m, h), []).append(r_sb["tps"])
                crudo.append({"run_id": rid, "motor": m, "hilos": h, "repeticion": i, "tps_propio": r_own["tps"],
                              "tps_sysbench": r_sb["tps"],
                              "p95_propio_ms": r_own["latencia_ms"]["global"]["p95"], "p95_sysbench_ms": r_sb["lat_p95_ms"]})
    comp = comparar(own, sbv, motores, hilos, sb["umbral_desviacion_pct"])
    est = {f"{m}|{h}": {"propio": estadisticos(own.get((m, h), [])), "sysbench": estadisticos(sbv.get((m, h), []))}
           for m in motores for h in hilos}
    informe = {"generado_utc": ahora_utc_iso(), "config_sha256": cfg.sha256, "umbral_pct": sb["umbral_desviacion_pct"],
               "repeticiones": reps, "comparacion": comp, "estadisticos": est,
               "conclusion": ("consistente" if comp and all(c["supera_umbral"] is False for c in comp)
                              else "revisar" if comp else "sin_datos"), "entorno": entorno}
    escribir_json(dir_out / "verificacion_sysbench.json", informe)
    if crudo:
        with open(dir_out / "verificacion_crudo.csv", "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=list(crudo[0]))
            w.writeheader()
            w.writerows(crudo)
    if comp:
        with open(dir_out / "verificacion_razones.csv", "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=list(comp[0]))
            w.writeheader()
            w.writerows(comp)
    return informe
