"""Manifiesto de ejecuciones (Tabla 3.28 de la tesis).

El manifiesto se deriva de forma DETERMINISTA de la configuración y de la
semilla maestra: el mismo archivo de configuración produce siempre el mismo
plan, el mismo orden sorteado y las mismas semillas por ejecución. Por eso es
suficiente publicar el archivo de configuración y el código para que otra
persona repita exactamente el experimento.

Campañas (código de la tesis -> nombre interno):
    C1-C4  principal           W1..W4 × concurrencias × motores, estrategia E0
    C5     indices_lectura     E1 y E2, L1-L8 (W1) y A1-A4 (W2), 1 conexión
    C6     indices_texto       L9 (T9): E0 y E3 (PG: GIN y GiST; MySQL: FULLTEXT)
    C7     indices_escritura   W3 bajo E1 y E2
    C8     fria (opcional)     W1 y W2, 1 conexión, sin calentamiento

Nota sobre C5: la Tabla 3.28 cuenta 120 ejecuciones (una por combinación). Aquí
W1 y W2 se ejecutan por separado (240), porque cada carga tiene su propia
ventana y su referencia E0 (1 conexión) proviene de la misma carga en C1/C2.
"""
from __future__ import annotations

import json
import random
from pathlib import Path
from typing import Any

from .config import Config
from .util import ErrorBench, derivar_semilla, escribir_json, leer_json, sha256_bytes

CODIGOS = {"principal": "C1-C4", "indices_lectura": "C5", "indices_texto": "C6",
           "indices_escritura": "C7", "fria": "C8", "piloto": "piloto"}
ORDEN_CAMPANAS = ["principal", "indices_lectura", "indices_texto", "indices_escritura", "fria"]


def estrategias_e3(tipo: str) -> list[str]:
    return ["E3-GIN", "E3-GiST"] if tipo == "postgresql" else ["E3"]


def estrategias_motor(tipo: str) -> list[str]:
    return ["E0", "E1", "E2"] + estrategias_e3(tipo)


def _combinaciones(cfg: Config, campana: str) -> list[dict]:
    motores = sorted(cfg.motores)
    conc = list(cfg.get("general.concurrencias"))
    c: list[dict] = []
    if campana in ("principal", "piloto"):
        for m in motores:
            for carga in ("W1", "W2", "W3", "W4"):
                for n in conc:
                    c.append({"motor": m, "estrategia": "E0", "carga": carga, "concurrencia": n})
    elif campana == "indices_lectura":
        for m in motores:
            for e in ("E1", "E2"):
                for carga in ("W1", "W2"):
                    c.append({"motor": m, "estrategia": e, "carga": carga, "concurrencia": 1})
    elif campana == "indices_texto":
        n6 = cfg.get("general.c6_concurrencia", 1)
        for m in motores:
            tipo = cfg.motor(m)["tipo"]
            for e in ["E0"] + estrategias_e3(tipo):
                c.append({"motor": m, "estrategia": e, "carga": "T9", "concurrencia": n6})
    elif campana == "indices_escritura":
        n7 = cfg.get("general.c7_concurrencia")
        for m in motores:
            for e in ("E1", "E2"):
                c.append({"motor": m, "estrategia": e, "carga": "W3", "concurrencia": n7})
    elif campana == "fria":
        for m in motores:
            for carga in ("W1", "W2"):
                c.append({"motor": m, "estrategia": "E0", "carga": carga, "concurrencia": 1, "calentar": False})
    else:
        raise ErrorBench(f"Campaña desconocida: {campana}")
    return c


def run_id(campana: str, comb: dict, bloque: int) -> str:
    return (f"{campana}-{comb['motor']}-{comb['estrategia']}-{comb['carga']}-"
            f"c{comb['concurrencia']:03d}-i{bloque:03d}")


def generar_manifiesto(cfg: Config, *, campanas: list[str] | None = None, piloto: bool = False) -> dict[str, Any]:
    """Plan completo: ejecuciones ordenadas por campaña, bloque y orden aleatorio dentro del bloque."""
    maestra = cfg.req("general.semilla_maestra")
    if piloto:
        campanas, reps = ["piloto"], cfg.get("general.piloto_repeticiones")
    else:
        campanas = campanas or [c for c in ORDEN_CAMPANAS if c != "fria" or cfg.get("general.incluir_cache_fria")]
        reps = cfg.get("general.repeticiones")
    desconocidas = [c for c in campanas if c not in CODIGOS]
    if desconocidas:
        raise ErrorBench(f"Campañas desconocidas: {desconocidas}. Válidas: {list(CODIGOS)}")
    items: list[dict] = []
    for campana in campanas:
        combs = _combinaciones(cfg, campana)
        for bloque in range(1, reps + 1):
            orden = combs[:]
            random.Random(derivar_semilla(maestra, "orden", campana, bloque)).shuffle(orden)
            for comb in orden:
                it = {
                    "run_id": run_id(campana, comb, bloque), "campana": campana, "codigo": CODIGOS[campana],
                    "motor": comb["motor"], "estrategia": comb["estrategia"], "carga": comb["carga"],
                    "concurrencia": comb["concurrencia"], "repeticion": bloque, "bloque": bloque,
                    # misma semilla para ambos motores y para todas las estrategias del bloque: flujos de
                    # parámetros idénticos (diseño apareado)
                    "semilla": derivar_semilla(maestra, comb["carga"], comb["concurrencia"], bloque),
                    "calentar": comb.get("calentar", True),
                }
                items.append(it)
    for i, it in enumerate(items, 1):
        it["orden"] = i
    ids = [it["run_id"] for it in items]
    if len(ids) != len(set(ids)):
        raise ErrorBench("run_id duplicados en el manifiesto")
    cuerpo = json.dumps(items, sort_keys=True).encode()
    return {"esquema": "tesis-bench/manifiesto-v1", "config_sha256": cfg.sha256,
            "semilla_maestra": maestra, "campanas": campanas, "repeticiones": reps,
            "plan_sha256": sha256_bytes(cuerpo), "total": len(items), "ejecuciones": items}


def resumen_plan(man: dict) -> dict[str, int]:
    cuenta: dict[str, int] = {}
    for it in man["ejecuciones"]:
        cuenta[it["campana"]] = cuenta.get(it["campana"], 0) + 1
    return cuenta


def ruta_manifiesto(cfg: Config, piloto: bool = False) -> Path:
    return cfg.dir_resultados / ("manifiesto-piloto.json" if piloto else "manifiesto.json")


def cargar_o_crear(cfg: Config, *, piloto: bool = False, forzar: bool = False) -> dict:
    """Usa el manifiesto guardado si existe (y coincide con la configuración); si no, lo crea.

    El manifiesto siempre contiene el plan completo; para ejecutar solo algunas campañas
    se filtra al ejecutar (así el plan_sha256 no depende de lo que se ejecute en cada sesión).
    """
    ruta = ruta_manifiesto(cfg, piloto)
    nuevo = generar_manifiesto(cfg, piloto=piloto)
    if ruta.exists() and not forzar:
        viejo = leer_json(ruta)
        if viejo["plan_sha256"] != nuevo["plan_sha256"]:
            raise ErrorBench(
                f"El manifiesto guardado ({ruta}) no coincide con la configuración actual. "
                "Un plan no debe cambiar a mitad de un experimento. Restaure el archivo de configuración original "
                "o use --forzar-plan (esto invalida la reanudación y debe documentarse).")
        return viejo
    escribir_json(ruta, nuevo)
    return nuevo
