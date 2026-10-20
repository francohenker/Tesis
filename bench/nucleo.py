"""Núcleo de una ejecución: lanza los clientes, sincroniza las barreras y captura métricas.

El orquestador es la parte n+1 de la barrera. Secuencia (ver cliente.py):

    A  todos conectados
    B  calentamiento y línea base terminados -> contadores iniciales, instantánea, monitor
    C  inicio común de la ventana (t_ventana: reloj monótono compartido)
    D  fin de la ventana  -> instantánea final, contadores finales

En W3 hay una barrera de inicio y una de fin por fase; la reconstrucción de
índices (fase R) la ejecuta el orquestador entre E1 y E2, con los clientes
esperando.
"""
from __future__ import annotations

import multiprocessing as mp
import threading
import time
from pathlib import Path
from typing import Any

from . import motor as mot
from .cliente import trabajador
from .config import Config
from .consultas import FASES_W3
from .db import Conexion
from .recursos import bucle_monitor, crear_fuente, leer_monitor, snapshot_completo
from .util import log

_REPOSO_STATS_S = 1.2   # PostgreSQL vuelca las estadísticas con retardo de ~1 s


def ventana_de(cfg: Config, carga: str) -> dict:
    """Calentamiento y medición (s) de una carga. W2 y W3 se miden por cantidad de trabajo, no por tiempo."""
    if carga in ("W2", "W3"):
        return {"calentamiento_s": 0, "medicion_s": None}
    v = cfg.get(f"ventanas.{carga}")
    if v is None:
        raise ValueError(f"No hay ventana configurada para la carga {carga}")
    return {"calentamiento_s": v["calentamiento_s"], "medicion_s": v["medicion_s"]}


def _max_id_mov(con: Conexion) -> int:
    return int(con.consultar("SELECT COALESCE(MAX(id_movimiento), 0) FROM movimientos_inventario")[0][0])


def ejecutar_clientes(cfg: Config, *, motor: str, estrategia: str, carga: str, n: int, seed_run: int,
                      dir_tmp: Path, calentar: bool = True, base: str | None = None,
                      filas_sbtest: int = 1, medicion_s: float | None = None,
                      calentamiento_s: float | None = None) -> dict[str, Any]:
    """Ejecuta una corrida completa de clientes y devuelve datos crudos + instantáneas."""
    dir_tmp = Path(dir_tmp)
    dir_tmp.mkdir(parents=True, exist_ok=True)
    motor_cfg = cfg.motor(motor)
    sis = cfg.get("sistema")
    vent = ventana_de(cfg, carga)
    medicion_s = medicion_s if medicion_s is not None else vent["medicion_s"]
    calentamiento_s = calentamiento_s if calentamiento_s is not None else vent["calentamiento_s"]
    t_conexion = cfg.get("general.timeout_conexion_s")
    t_largo = cfg.get("general.timeout_ejecucion_s")
    cpus = list(sis.get("cpus_clientes") or [])

    ctx = mp.get_context("spawn")
    barrera = ctx.Barrier(n + 1)
    abort = ctx.Event()
    t_ventana = ctx.Value("q", 0)
    id_base = ctx.Value("q", 0)
    id_max = ctx.Value("q", 0)
    parar_mon, monitor_listo = ctx.Event(), ctx.Event()

    spec_base = {
        "n": n, "carga": carga, "motor": motor, "estrategia": estrategia, "seed_run": seed_run,
        "dir_tmp": str(dir_tmp), "cfg_datos": cfg.datos, "cfg_ruta": str(cfg.ruta) if cfg.ruta else None,
        "exigir_cext": bool(sis.get("exigir_cext_mysql", True)), "calentar": calentar,
        "calentamiento_s": calentamiento_s, "linea_base_n": cfg.get("ventanas.linea_base_n"),
        "medicion_s": medicion_s, "t_conexion": t_conexion, "t_largo": t_largo, "base": base,
        "filas_sbtest": filas_sbtest, "cpus": cpus, "barrera": barrera, "abort": abort,
        "t_ventana": t_ventana, "id_base": id_base, "id_max": id_max,
    }
    procs = [ctx.Process(target=trabajador, args=({**spec_base, "indice": k},), name=f"cliente-{k}")
             for k in range(n)]
    monitor = ctx.Process(target=bucle_monitor, name="monitor", args=(
        sis, motor_cfg, str(dir_tmp / "monitor.csv"), parar_mon, monitor_listo, cpus))

    out: dict[str, Any] = {"abortada": False, "motivo_aborto": None, "reindex": [], "dir_tmp": str(dir_tmp),
                           "medicion_s": medicion_s, "calentamiento_s": calentamiento_s}
    con = None
    fuente = crear_fuente(sis, motor_cfg)
    disp = sis.get("dispositivo_datos", "")
    try:
        con = Conexion(motor_cfg, base=base, exigir_cext=False)
        for p in procs:
            p.start()
        barrera.wait(t_conexion)                                               # A
        barrera.wait(t_largo)                                                  # B
        if carga == "W3":
            id_base.value = _max_id_mov(con)
            out["id_base"] = id_base.value
        time.sleep(_REPOSO_STATS_S)
        out["contadores_ini"] = mot.contadores(con)
        monitor.start()
        if not monitor_listo.wait(30):
            raise RuntimeError("el monitor no arrancó")
        out["ini"] = snapshot_completo(fuente, disp)
        t_ventana.value = time.monotonic_ns() + 300_000_000
        barrera.wait(t_largo)                                                  # C
        out["t_ventana_ns"] = t_ventana.value

        if carga == "W3":
            _orquestar_w3(cfg, con, barrera, t_largo, estrategia, id_max, out)
        else:
            barrera.wait((medicion_s or 0) + t_largo if carga == "W2" else medicion_s + 120)   # D
        out["fin"] = snapshot_completo(fuente, disp)
        out["t_fin_ns"] = out["fin"]["t_ns"]
        time.sleep(_REPOSO_STATS_S)
        out["contadores_fin"] = mot.contadores(con)
        if carga == "W3":
            out["residuo_w3"] = int(con.consultar(
                "SELECT COUNT(*) FROM movimientos_inventario WHERE id_movimiento > %s", (id_base.value,))[0][0])
    except (threading.BrokenBarrierError, Exception) as e:  # noqa: BLE001
        out["abortada"] = True
        out["motivo_aborto"] = f"{type(e).__name__}: {e}"
        log.error("corrida abortada: %s", out["motivo_aborto"])
        abort.set()
        try:
            barrera.abort()
        except Exception:
            pass
        out.setdefault("ini", snapshot_completo(fuente, disp))
        out.setdefault("fin", snapshot_completo(fuente, disp))
        out.setdefault("t_ventana_ns", t_ventana.value or out["ini"]["t_ns"])
        out.setdefault("t_fin_ns", out["fin"]["t_ns"])
        out.setdefault("contadores_ini", {})
        out.setdefault("contadores_fin", {})
    finally:
        parar_mon.set()
        for p in procs:
            p.join(60)
            if p.is_alive():
                p.terminate()
                p.join(10)
        if monitor.is_alive() or monitor.pid:
            monitor.join(20)
            if monitor.is_alive():
                monitor.terminate()
        if con is not None:
            con.cerrar()

    out["procesos"] = [{"nombre": p.name, "exitcode": p.exitcode} for p in procs]
    ruta_mon = dir_tmp / "monitor.csv"
    out["serie"] = leer_monitor(ruta_mon) if ruta_mon.exists() else []
    return out


def _orquestar_w3(cfg: Config, con: Conexion, barrera, t_largo: float, estrategia: str, id_max, out: dict) -> None:
    for fase in FASES_W3:
        if fase == "R":
            out["id_max"] = _max_id_mov(con)
            id_max.value = out["id_max"]
            out["reindex"] = mot.reconstruir_indices(con, estrategia)
            continue
        barrera.wait(t_largo)      # inicio de fase
        barrera.wait(t_largo)      # fin de fase
        if fase == "E1":
            pass
    if "id_max" not in out:
        out["id_max"] = id_max.value
