"""Interfaz de línea de comandos:  python -m bench <comando> --config config/experimento.toml"""
from __future__ import annotations

import argparse
import json
import sys

from .config import Config
from .util import ErrorBench, configurar_logging


def _cfg(a) -> Config:
    return Config.cargar(a.config)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="bench", description="Cliente y orquestador de la tesis PostgreSQL vs MySQL")
    ap.add_argument("--config", default="config/experimento.toml", help="archivo de configuración TOML")
    ap.add_argument("-v", "--verbose", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("plan", help="genera/muestra el manifiesto de ejecuciones")
    p.add_argument("--piloto", action="store_true")
    p = sub.add_parser("imagenes", help="crea las imágenes base E0-E3 de un motor")
    p.add_argument("--motor", required=True)
    p.add_argument("--estrategias", nargs="*")
    p.add_argument("--huella-rapida", action="store_true", help="no calcula el SHA-256 completo de la imagen")
    p = sub.add_parser("run", help="ejecuta (o reanuda) el plan")
    p.add_argument("--piloto", action="store_true")
    p.add_argument("--campanas", nargs="*", help="p. ej. principal indices_lectura  (o C1-C4, C5, C6, C7, C8)")
    p.add_argument("--motor")
    p.add_argument("--limite", type=int, help="máximo de ejecuciones a completar en esta sesión")
    p.add_argument("--simular", action="store_true", help="solo lista lo pendiente")
    p.add_argument("--forzar-plan", action="store_true")
    p.add_argument("--reintentar-agotadas", action="store_true",
                   help="archiva los descartes de las ejecuciones que agotaron sus reintentos y las vuelve a intentar")
    p = sub.add_parser("una", help="ejecuta una sola corrida (prueba/depuración)")
    p.add_argument("--motor", required=True)
    p.add_argument("--estrategia", default="E0")
    p.add_argument("--carga", required=True, choices=["W1", "W2", "W3", "W4", "T9", "SB1"])
    p.add_argument("--concurrencia", type=int, default=1)
    p.add_argument("--semilla", type=int, default=1)
    p.add_argument("--sin-calentamiento", action="store_true")
    p.add_argument("--id", default="prueba")
    p = sub.add_parser("estado", help="avance por campaña")
    p.add_argument("--piloto", action="store_true")
    sub.add_parser("consolidar", help="genera los CSV de resultados")
    p = sub.add_parser("sysbench-preparar", help="crea la imagen «sysbench» de un motor")
    p.add_argument("--motor", nargs="*")
    p = sub.add_parser("sysbench", help="verificación cruzada contra Sysbench")
    p.add_argument("--repeticiones", type=int)
    sub.add_parser("entorno", help="muestra el entorno que se registrará")
    a = ap.parse_args(argv)
    configurar_logging(nivel=10 if a.verbose else 20)
    try:
        cfg = _cfg(a)
        if a.cmd == "plan":
            from .plan import cargar_o_crear, resumen_plan, ruta_manifiesto
            man = cargar_o_crear(cfg, piloto=a.piloto)
            print(f"Manifiesto: {ruta_manifiesto(cfg, a.piloto)}\nplan_sha256: {man['plan_sha256']}\n"
                  f"Total: {man['total']}  por campaña: {resumen_plan(man)}")
        elif a.cmd == "imagenes":
            from .imagenes import crear_imagenes
            inf = crear_imagenes(cfg, a.motor, a.estrategias, huella_completa=not a.huella_rapida)
            for e, r in inf.items():
                n = sum(1 for c in r["construccion"] if c["indice"])
                t = sum(c["segundos"] for c in r["construccion"])
                print(f"{a.motor}/{e}: {n} índices en {t:.1f} s  huella {r['huella']['rapida']['sha256'][:12]}")
        elif a.cmd == "run":
            from .orquestador import ejecutar_plan
            print(json.dumps(ejecutar_plan(cfg, piloto=a.piloto, campanas=a.campanas, motor=a.motor,
                                           limite=a.limite, simular=a.simular, forzar_plan=a.forzar_plan,
                                           reintentar_agotadas=a.reintentar_agotadas), indent=2))
        elif a.cmd == "una":
            from .corrida import ejecutar_corrida
            from .motor import ControlMotor
            item = {"run_id": f"{a.id}-{a.motor}-{a.estrategia}-{a.carga}-c{a.concurrencia:03d}-i001",
                    "campana": "prueba", "motor": a.motor, "estrategia": a.estrategia, "carga": a.carga,
                    "concurrencia": a.concurrencia, "repeticion": 1, "bloque": 1, "semilla": a.semilla,
                    "calentar": not a.sin_calentamiento}
            reg = ejecutar_corrida(cfg, ControlMotor(cfg, a.motor), item)
            resumen = {k: reg.get(k) for k in ("run_id", "tps", "operaciones", "validez", "ventana", "aborto",
                                               "primeros_errores", "error_fatal")}
            resumen["latencia_global_ms"] = (reg.get("latencia_ms") or {}).get("global")
            print(json.dumps(resumen, indent=2, ensure_ascii=False, default=str))
        elif a.cmd == "estado":
            from .orquestador import estado
            print(json.dumps(estado(cfg, a.piloto), indent=2))
        elif a.cmd == "consolidar":
            from .consolidar import consolidar
            print(json.dumps(consolidar(cfg), indent=2))
        elif a.cmd == "sysbench-preparar":
            from .verificacion import preparar_imagen
            for m in a.motor or sorted(cfg.motores):
                preparar_imagen(cfg, m)
        elif a.cmd == "sysbench":
            from .verificacion import ejecutar_verificacion
            inf = ejecutar_verificacion(cfg, a.repeticiones)
            print(json.dumps({"conclusion": inf["conclusion"], "comparacion": inf["comparacion"]}, indent=2))
        elif a.cmd == "entorno":
            from .corrida import capturar_entorno
            print(json.dumps(capturar_entorno(cfg), indent=2, ensure_ascii=False))
    except ErrorBench as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
