"""Criterios de validez de una ejecución (Tabla 3.29 de la tesis).

Una ejecución inválida se descarta y se repite (con la misma semilla),
registrando la causa. Los valores extremos de una ejecución válida NO se
eliminan. Algunos criterios no descartan: solo agregan una advertencia que
queda registrada en el resultado (holgura del cliente, checkpoint).
"""
from __future__ import annotations

from typing import Any


def evaluar(cfg, *, carga: str, tipo_motor: str, estados_trabajadores: list[str], conteo: dict, errores: dict,
            medicion_s: float | None, duracion_efectiva_s: float, recursos: dict, estado_inicial_ok: bool,
            reposo_cpu_pct: float, contadores_delta: dict, abortada: bool, hay_cpus_cliente: bool) -> dict[str, Any]:
    v, sis = cfg.get("validez"), cfg.get("sistema")
    criterios: dict[str, Any] = {}
    motivos: list[str] = []
    adv: list[str] = []

    malos = [e for e in estados_trabajadores if e != "ok"]
    criterios["trabajadores"] = {"ok": not malos, "estados_no_ok": malos[:5]}
    if malos:
        motivos.append("trabajador_fallido")
    if abortada:
        criterios["timeout"] = {"ok": False}
        motivos.append("tiempo_maximo_excedido")

    total = conteo["ok"] + conteo["negocio"] + conteo["tecnicos"]
    pct = 100.0 * conteo["tecnicos"] / total if total else 100.0
    ok = pct <= v["errores_tecnicos_max_pct"] and total > 0
    criterios["errores_tecnicos"] = {"ok": ok, "pct": round(pct, 4), "umbral_pct": v["errores_tecnicos_max_pct"]}
    if not ok:
        motivos.append("errores_tecnicos" if total else "sin_operaciones")

    criterios["aislamiento"] = {"ok": True, "reposo_cpu_pct": round(reposo_cpu_pct, 2),
                                "umbral_pct": cfg.get("general.reposo_cpu_max_pct")}

    swap = recursos["swap"]
    ok = (swap["pswpin"] + swap["pswpout"]) <= sis["swap_tolerancia"]
    criterios["paginacion"] = {"ok": ok, **swap}
    if not ok:
        motivos.append("paginacion")

    if recursos["ventana_s"] >= 3:   # con ventanas más cortas que unas pocas muestras la cobertura no es evaluable
        cob = recursos["muestras_monitor"] / max(1, int(recursos["ventana_s"]))
        ok = cob >= v["cobertura_monitor_min"]
        criterios["cobertura_monitor"] = {"ok": ok, "cobertura": round(cob, 3), "umbral": v["cobertura_monitor_min"]}
        if not ok:
            motivos.append("cobertura_monitor")
    else:
        criterios["cobertura_monitor"] = {"ok": None, "nota": f"ventana de {recursos['ventana_s']} s demasiado corta"}

    if medicion_s:
        rel = duracion_efectiva_s / medicion_s
        ok = rel >= v["ventana_efectiva_min"]
        criterios["ventana_efectiva"] = {"ok": ok, "relacion": round(rel, 4), "umbral": v["ventana_efectiva_min"]}
        if not ok:
            motivos.append("ventana_efectiva")

    criterios["estado_inicial"] = {"ok": estado_inicial_ok}
    if not estado_inicial_ok:
        motivos.append("estado_inicial")

    cli = recursos.get("cliente_cpu_pct")
    if hay_cpus_cliente and cli is not None:
        ok = cli < sis["holgura_cliente_max_pct"]
        criterios["holgura_cliente"] = {"ok": ok, "cpu_pct": cli, "umbral_pct": sis["holgura_cliente_max_pct"]}
        if not ok:
            adv.append("holgura_cliente_insuficiente")
    else:
        criterios["holgura_cliente"] = {"ok": None, "nota": "no evaluable: defina sistema.cpus_clientes"}

    if carga == "W4" and tipo_motor == "postgresql":
        n = contadores_delta.get("checkpoints_timed", 0) + contadores_delta.get("checkpoints_req", 0)
        criterios["checkpoint"] = {"ok": n >= 1, "checkpoints": n}
        if n < 1:
            adv.append("sin_checkpoint_en_ventana_ampliar_ventana_en_ambos_motores")

    return {"valida": not motivos, "motivo_descarte": ",".join(motivos) if motivos else None,
            "advertencias": adv, "criterios": criterios}
