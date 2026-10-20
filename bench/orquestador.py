"""Orquestador: recorre el manifiesto, reanuda campañas interrumpidas y reintenta las inválidas.

* Una ejecución está completa si existe su <run_id>.json (se escribe al final).
* Una ejecución inválida deja <run_id>.descartada-N.json y se repite con la
  MISMA semilla, hasta `general.max_reintentos` veces.
* Un bloqueo de archivo impide lanzar dos orquestadores sobre los mismos resultados.
"""
from __future__ import annotations

import fcntl
import time
from pathlib import Path

from . import motor as mot
from .config import Config
from .corrida import capturar_entorno, corrida_completa, ejecutar_corrida, rutas_corrida
from .plan import cargar_o_crear
from .util import ErrorBench, configurar_logging, log


def _intentos_previos(cfg: Config, item: dict) -> int:
    d = rutas_corrida(cfg, item)["dir"]
    return len(list(d.glob(f"{item['run_id']}.descartada-*.json"))) if d.exists() else 0


def estado(cfg: Config, piloto: bool = False) -> dict:
    man = cargar_o_crear(cfg, piloto=piloto)
    res: dict[str, dict] = {}
    for it in man["ejecuciones"]:
        r = res.setdefault(it["campana"], {"total": 0, "completas": 0, "pendientes": 0, "descartes": 0, "agotadas": 0})
        r["total"] += 1
        previos = _intentos_previos(cfg, it)
        r["descartes"] += previos
        if corrida_completa(cfg, it):
            r["completas"] += 1
        else:
            r["pendientes"] += 1
            if previos > cfg.get("general.max_reintentos"):
                r["agotadas"] += 1
    return {"plan_sha256": man["plan_sha256"], "total": man["total"], "campanas": res}


def verificar_requisitos(cfg: Config, items: list[dict]) -> list[str]:
    """Antes de empezar: imágenes base y huellas disponibles para todo lo que se va a ejecutar."""
    faltan = []
    vistos = set()
    for it in items:
        clave = (it["motor"], it["estrategia"])
        if clave in vistos:
            continue
        vistos.add(clave)
        if not mot.ControlMotor(cfg, it["motor"]).existe_imagen(it["estrategia"]):
            faltan.append(f"{it['motor']}/{it['estrategia']}")
    return faltan


def ejecutar_plan(cfg: Config, *, piloto: bool = False, campanas: list[str] | None = None,
                  motor: str | None = None, limite: int | None = None, simular: bool = False,
                  forzar_plan: bool = False, reintentar_agotadas: bool = False) -> dict:
    cfg.dir_resultados.mkdir(parents=True, exist_ok=True)
    configurar_logging(cfg.dir_resultados / "orquestador.log")
    man = cargar_o_crear(cfg, piloto=piloto, forzar=forzar_plan)
    items = [it for it in man["ejecuciones"]
             if (not campanas or it["campana"] in campanas or it["codigo"] in campanas)
             and (not motor or it["motor"] == motor)]
    pendientes = [it for it in items if not corrida_completa(cfg, it)]
    log.info("plan %s: %d ejecuciones en el filtro, %d pendientes", man["plan_sha256"][:12], len(items), len(pendientes))
    if simular:
        for it in pendientes[: (limite or 20)]:
            print(f"{it['orden']:5d}  {it['run_id']}  semilla={it['semilla']}")
        return {"simulado": True, "pendientes": len(pendientes)}
    faltan = verificar_requisitos(cfg, pendientes[:limite] if limite else pendientes)
    if faltan:
        raise ErrorBench("Faltan imágenes base: " + ", ".join(faltan) +
                         ". Créelas con: python -m bench imagenes --config <archivo.toml>")

    lock = open(cfg.dir_resultados / ".orquestador.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        raise ErrorBench("Ya hay un orquestador en ejecución sobre estos resultados (bloqueo activo).")

    if reintentar_agotadas:   # los registros de descarte se conservan, archivados fuera de la cuenta de intentos
        for it in pendientes:
            if _intentos_previos(cfg, it) > cfg.get("general.max_reintentos"):
                d = rutas_corrida(cfg, it)["dir"]
                arch = d / "descartes_archivados"
                arch.mkdir(exist_ok=True)
                for f in d.glob(f"{it['run_id']}.descartada-*.json"):
                    f.rename(arch / f.name)
                log.info("%s: descartes archivados, se reintenta", it["run_id"])
    entorno = capturar_entorno(cfg)
    controles: dict[str, mot.ControlMotor] = {}
    g = cfg.get("general")
    hechas = invalidas = agotadas = 0
    t_ini = time.monotonic()
    try:
        for it in pendientes:
            if limite is not None and hechas >= limite:
                break
            ctl = controles.setdefault(it["motor"], mot.ControlMotor(cfg, it["motor"]))
            ok = False
            while not ok:
                previos = _intentos_previos(cfg, it)
                if previos > g["max_reintentos"]:
                    log.error("%s: agotados %d intentos; se omite", it["run_id"], previos)
                    agotadas += 1
                    break
                intento = previos + 1
                log.info("[%d/%d] %s (intento %d)", it["orden"], man["total"], it["run_id"], intento)
                reg = ejecutar_corrida(cfg, ctl, it, intento=intento, entorno=entorno)
                v = reg["validez"]
                if v["valida"]:
                    ok = True
                    hechas += 1
                    log.info("   válida: tps=%s  p95=%s ms  adv=%s", reg.get("tps"),
                             (reg.get("latencia_ms", {}).get("global") or {}).get("p95"), v.get("advertencias"))
                else:
                    invalidas += 1
                    log.warning("   DESCARTADA: %s", v.get("motivo_descarte"))
                time.sleep(g["cooldown_s"])
    finally:
        lock.close()
    return {"completadas": hechas, "descartadas": invalidas, "agotadas": agotadas,
            "segundos": round(time.monotonic() - t_ini, 1)}
