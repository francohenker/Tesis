"""Una ejecución completa del protocolo de 12 pasos (Tabla 3.26) y su registro.

`ejecutar_corrida` recibe un elemento del manifiesto y deja en disco:
    <run_id>.json      registro con todas las métricas y la trazabilidad
    <run_id>.lat.gz    latencia de cada operación (columnar, comprimido)
    <run_id>.mon.csv   serie del monitor de recursos (1 s)
Si la ejecución es inválida, el registro se guarda como <run_id>.descartada-N.json
(con la causa) para que el descarte quede documentado.
"""
from __future__ import annotations

import platform
import shutil
import sys
import time
from pathlib import Path
from typing import Any

from . import __version__
from . import motor as mot
from .config import Config
from .consultas import Dominio
from .db import Conexion
from .nucleo import ejecutar_clientes
from .postproceso import (duracion_efectiva_s, errores_totales, escribir_lat, fusionar_trabajadores,
                          resumir_fases, resumir_latencias, resumir_linea_base, resumir_recursos)
from .recursos import esperar_reposo
from .util import ErrorBench, ahora_utc_iso, escribir_json, hash_codigo, log
from .validez import evaluar


# ------------------------------------------------------------------ entorno
def _leer(ruta: str) -> str | None:
    try:
        with open(ruta) as f:
            return f.read().strip()
    except OSError:
        return None


def capturar_entorno(cfg: Config) -> dict[str, Any]:
    """Estado del equipo y de las dependencias (se guarda en cada resultado)."""
    cpu = next((l.split(":", 1)[1].strip() for l in (_leer("/proc/cpuinfo") or "").splitlines()
                if l.startswith("model name")), None)
    mem = {l.split(":")[0]: l.split(":")[1].strip() for l in (_leer("/proc/meminfo") or "").splitlines() if ":" in l}
    os_rel = {}
    for l in (_leer("/etc/os-release") or "").splitlines():
        if "=" in l:
            k, v = l.split("=", 1)
            os_rel[k] = v.strip('"')
    drivers: dict[str, Any] = {}
    try:
        import psycopg2
        drivers["psycopg2"] = psycopg2.__version__
    except Exception:
        drivers["psycopg2"] = None
    try:
        import mysql.connector as mc
        drivers["mysql-connector-python"] = mc.__version__
        drivers["mysql_extension_c"] = bool(getattr(mc, "HAVE_CEXT", False))
    except Exception:
        drivers["mysql-connector-python"] = None
    return {
        "so": os_rel.get("PRETTY_NAME"), "kernel": platform.release(), "arquitectura": platform.machine(),
        "cpu_modelo": cpu, "cpus_logicas": __import__("os").cpu_count(),
        "memoria_total": mem.get("MemTotal"), "swap_total": mem.get("SwapTotal"),
        "governor": _leer("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"),
        "thp": _leer("/sys/kernel/mm/transparent_hugepage/enabled"),
        "swappiness": _leer("/proc/sys/vm/swappiness"),
        "python": sys.version.split()[0], "drivers": drivers, "bench": __version__,
        "cpus_clientes": cfg.get("sistema.cpus_clientes"),
    }


# ---------------------------------------------------------------- utilidades
def rutas_corrida(cfg: Config, item: dict) -> dict[str, Path]:
    d = cfg.dir_resultados / "datos" / item["campana"]
    base = d / item["run_id"]
    return {"dir": d, "json": base.with_suffix(".json"), "lat": d / f"{item['run_id']}.lat.gz",
            "mon": d / f"{item['run_id']}.mon.csv", "tmp": cfg.dir_resultados / "tmp" / item["run_id"]}


def corrida_completa(cfg: Config, item: dict) -> bool:
    r = rutas_corrida(cfg, item)
    return r["json"].exists()


def _registro_base(cfg: Config, item: dict, ctl, intento: int, entorno: dict) -> dict:
    return {
        "esquema": "tesis-bench/resultado-v1", "run_id": item["run_id"], "campana": item["campana"],
        "motor": item["motor"], "tipo_motor": ctl.tipo, "estrategia": item["estrategia"], "carga": item["carga"],
        "concurrencia": item["concurrencia"], "repeticion": item["repeticion"], "bloque": item.get("bloque"),
        "semilla": item["semilla"], "intento": intento, "calentar": item.get("calentar", True),
        "inicio_utc": ahora_utc_iso(), "config_sha256": cfg.sha256, "codigo": hash_codigo(), "entorno": entorno,
    }


def _marcar_descartada(cfg: Config, item: dict, reg: dict, motivo: str, intento: int) -> dict:
    r = rutas_corrida(cfg, item)
    reg["validez"] = reg.get("validez") or {"valida": False, "advertencias": [], "criterios": {}}
    reg["validez"]["valida"] = False
    reg["validez"]["motivo_descarte"] = reg["validez"].get("motivo_descarte") or motivo
    reg["fin_utc"] = ahora_utc_iso()
    escribir_json(r["dir"] / f"{item['run_id']}.descartada-{intento}.json", reg)
    return reg


# ---------------------------------------------------------------- la corrida
def ejecutar_corrida(cfg: Config, ctl: mot.ControlMotor, item: dict, *, intento: int = 1,
                     entorno: dict | None = None) -> dict:
    """Ejecuta los pasos 1-12. Devuelve el registro (válido o descartado)."""
    entorno = entorno or capturar_entorno(cfg)
    rutas = rutas_corrida(cfg, item)
    reg = _registro_base(cfg, item, ctl, intento, entorno)
    g = cfg.get("general")
    carga, estrategia, n = item["carga"], item["estrategia"], item["concurrencia"]
    base_dato = cfg.get("sysbench.base") if carga == "SB1" else None
    try:
        # 1. aislamiento y reposo
        reposo = esperar_reposo(g["reposo_cpu_max_pct"], g["reposo_espera_max_s"])
        reg["reposo_cpu_pct"] = round(reposo, 3)
        if reposo > g["reposo_cpu_max_pct"]:
            return _marcar_descartada(cfg, item, reg, f"sistema_no_en_reposo({reposo:.1f}%)", intento)
        # 2-4. detener, restaurar imagen base y verificar, vaciar caché del SO
        ctl.detener()
        ctl.restaurar(estrategia if carga != "SB1" else "sysbench")
        ver = ctl.verificar_restauracion(estrategia if carga != "SB1" else "sysbench",
                                         cfg.get("sistema.verificacion_imagen_por_corrida"))
        reg["restauracion"] = ver
        if not ver["ok"]:
            return _marcar_descartada(cfg, item, reg, "restauracion_inexacta", intento)
        ctl.vaciar_cache()
        # 5. iniciar el motor
        t0 = time.monotonic()
        ctl.iniciar()
        con = ctl.esperar_disponible()
        reg["arranque_s"] = round(time.monotonic() - t0, 3)
        reg["version_motor"] = mot.version_motor(con)
        reg["parametros_motor"] = mot.parametros_motor(con, ctl.m.get("parametros_registrar", []))
        problemas = [] if carga == "SB1" else mot.verificar_dominio(con, Dominio.desde_config(cfg))
        con.cerrar()
        estado_inicial_ok = bool(ver["ok"]) and not problemas
        reg["estado_inicial"] = {"huella_ok": ver["ok"], "problemas_dominio": problemas}

        # 6-9. calentamiento, línea base, ventana (clientes + monitor + contadores)
        filas_sb = int(cfg.get("sysbench.filas")) if carga == "SB1" else 1
        datos = ejecutar_clientes(cfg, motor=item["motor"], estrategia=estrategia, carga=carga, n=n,
                                  seed_run=item["semilla"], dir_tmp=rutas["tmp"], calentar=item.get("calentar", True),
                                  base=base_dato, filas_sbtest=filas_sb)

        # 10. postproceso y validación
        cols, resumenes = fusionar_trabajadores(rutas["tmp"], n)
        lat = resumir_latencias(cols)
        err = errores_totales(resumenes)
        estados = [r.get("estado", "sin_datos") for r in resumenes]
        estados += [f"exit{p['exitcode']}" for p in datos["procesos"] if p["exitcode"] not in (0, None)]
        dur = duracion_efectiva_s(resumenes, datos["t_ventana_ns"])
        n_ops = lat["conteo"]["ok"] + lat["conteo"]["negocio"]
        rec = resumir_recursos(datos["ini"], datos["fin"], datos["serie"], datos["t_ventana_ns"], datos["t_fin_ns"],
                               n_ops, cfg.get("sistema.cpus_clientes"))
        delta = mot.delta_contadores(datos["contadores_ini"], datos["contadores_fin"]) if datos["contadores_fin"] else {}
        val = evaluar(cfg, carga=carga, tipo_motor=ctl.tipo, estados_trabajadores=estados, conteo=lat["conteo"],
                      errores=err, medicion_s=datos["medicion_s"], duracion_efectiva_s=dur, recursos=rec,
                      estado_inicial_ok=estado_inicial_ok, reposo_cpu_pct=reposo, contadores_delta=delta,
                      abortada=datos["abortada"], hay_cpus_cliente=bool(cfg.get("sistema.cpus_clientes")))
        if datos["abortada"]:
            reg["aborto"] = datos["motivo_aborto"]
        errores_trab = [r.get("error") or r.get("primer_error") for r in resumenes if r.get("error") or r.get("primer_error")]
        reg.update({
            "ventana": {"calentamiento_s": datos["calentamiento_s"], "medicion_s": datos["medicion_s"],
                        "duracion_efectiva_s": round(dur, 4)},
            "operaciones": lat["conteo"],
            "latencia_ms": lat["latencia_ms"], "linea_base_ms": resumir_linea_base(resumenes),
            "tps": round(n_ops / dur, 4) if dur > 0 else None,
            "tps_ok": round(lat["conteo"]["ok"] / dur, 4) if dur > 0 else None,
            "recursos": rec, "contadores": delta, "errores": err, "primeros_errores": errores_trab[:5],
            "fases": resumir_fases(resumenes), "reindex": datos["reindex"],
            "residuo_w3": datos.get("residuo_w3"), "validez": val,
        })
        reg["fin_utc"] = ahora_utc_iso()

        if val["valida"]:
            rutas["dir"].mkdir(parents=True, exist_ok=True)
            escribir_lat(rutas["lat"], cols, {"run_id": item["run_id"], "semilla": item["semilla"]})
            if (rutas["tmp"] / "monitor.csv").exists():
                shutil.copyfile(rutas["tmp"] / "monitor.csv", rutas["mon"])
            escribir_json(rutas["json"], reg)   # el JSON se escribe al final: marca de corrida completa
        else:
            escribir_json(rutas["dir"] / f"{item['run_id']}.descartada-{intento}.json", reg)
        return reg
    except ErrorBench as e:
        log.error("%s: %s", item["run_id"], e)
        reg["error_fatal"] = str(e)
        return _marcar_descartada(cfg, item, reg, f"error_entorno: {e}", intento)
    except Exception as e:  # noqa: BLE001 - un fallo inesperado descarta la corrida, no detiene la campaña
        import traceback
        log.error("%s: excepción inesperada: %s", item["run_id"], e)
        reg["error_fatal"] = f"{type(e).__name__}: {e}"
        reg["traza"] = traceback.format_exc()[-2000:]
        return _marcar_descartada(cfg, item, reg, f"excepcion: {type(e).__name__}", intento)
    finally:
        # 11-12. detener el motor; el enfriamiento lo aplica el orquestador
        try:
            ctl.detener()
        except Exception as e:  # noqa: BLE001
            log.warning("no se pudo detener %s: %s", ctl.nombre, e)
        shutil.rmtree(rutas["tmp"], ignore_errors=True)
