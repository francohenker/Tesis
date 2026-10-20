"""Cliente de carga: un proceso por conexión (secciones 3.4 y 3.6.2 de la tesis).

Ciclo de vida de cada trabajador (sincronizado por una barrera con el
orquestador, que es la parte n+1):

    A  conectar ............................ [barrera A]
       calentamiento (no se mide)
       línea base del driver (SELECT 1 x N)
    B  fin de calentamiento y línea base ... [barrera B]
       (el orquestador captura contadores e inicia el monitor)
    C  inicio común de la ventana ......... [barrera C]  (t_ventana compartido)
       ventana de medición
    D  fin ................................. [barrera D]

W3 reemplaza la ventana por fases (E1, R, E2, E3, E4) con una barrera de
inicio y otra de fin por fase.

Las latencias se acumulan en memoria y se escriben a disco al terminar,
para no introducir E/S durante la medición.
"""
from __future__ import annotations

import array
import os
import random
import threading
import time
from pathlib import Path
from typing import Any

from .config import Config
from .consultas import CARGAS, FASES_W3, Dominio, construir_ops, ejecutar_t1, elegir_op_w4, preparar_t1
from .db import Conexion, clasificar_error
from .util import derivar_semilla, escribir_json

OK, TEC, NEG = 0, 1, 2
OP_IDS = ["L1", "L2", "L3", "L4", "L5", "L6", "L7", "L8", "L9", "A1", "A2", "A3", "A4",
          "T1", "U1", "SB1", "E1", "E2", "E3", "E4"]
OP_INDICE = {o: i for i, o in enumerate(OP_IDS)}

assert array.array("I").itemsize == 4, "Se requiere unsigned int de 4 bytes"


class Registro:
    """Bitácora de operaciones de un cliente (columnas)."""

    def __init__(self) -> None:
        self.op = array.array("B")
        self.st = array.array("B")
        self.t = array.array("I")      # µs desde el inicio de la ventana
        self.lat = array.array("I")    # latencia en µs


class Ejecutor:
    """Ejecuta y mide operaciones sobre una conexión."""

    MAX_FALLOS_SEGUIDOS = 200

    def __init__(self, con: Conexion, ops: dict, dom: Dominio, rec: Registro, res: dict):
        self.con, self.ops, self.dom, self.rec, self.res = con, ops, dom, rec, res
        self.t0_ns = 0
        self.fallos_seguidos = 0

    def medir(self, oid: str, accion):
        """Mide `accion` y la registra. `accion` devuelve 'ok'|'negocio' o una tupla (estado, dato)."""
        t_rel = max(0, (time.monotonic_ns() - self.t0_ns) // 1000)
        ini = time.perf_counter_ns()
        resultado: Any = None
        try:
            resultado = accion()
            lat = (time.perf_counter_ns() - ini) // 1000
            estado = resultado[0] if isinstance(resultado, tuple) else resultado
            st = NEG if estado == "negocio" else OK
            if st == NEG:
                self.res["negocio"] += 1
            self.fallos_seguidos = 0
        except Exception as e:  # noqa: BLE001 - se clasifica y se cuenta
            lat = (time.perf_counter_ns() - ini) // 1000
            st = TEC
            tipo = clasificar_error(self.con.tipo, e)
            self.res["errores"][tipo] += 1
            if self.res.get("primer_error") is None:
                self.res["primer_error"] = f"{type(e).__name__}: {str(e)[:200]}"
            self.fallos_seguidos += 1
            self._recuperar(tipo)
            if self.fallos_seguidos > self.MAX_FALLOS_SEGUIDOS:
                raise RuntimeError(f"{self.fallos_seguidos} errores seguidos; último: {self.res['primer_error']}")
        self.rec.op.append(OP_INDICE[oid])
        self.rec.st.append(st)
        self.rec.t.append(min(t_rel, 0xFFFFFFFF))
        self.rec.lat.append(min(lat, 0xFFFFFFFF))
        self.res["t_ultimo_fin_ns"] = time.monotonic_ns()
        return resultado

    def _recuperar(self, tipo: str) -> None:
        if tipo == "conexion":
            for _ in range(5):
                try:
                    self.con.reconectar()
                    self.res["reconexiones"] += 1
                    return
                except Exception:
                    time.sleep(0.2)
            return
        try:
            self.con.ejecutar("ROLLBACK")
        except Exception:
            try:
                self.con.reconectar()
                self.res["reconexiones"] += 1
            except Exception:
                time.sleep(0.2)

    def op(self, oid: str, rng: random.Random):
        """Operación simple o T1; los parámetros se generan ANTES de medir."""
        if oid == "T1":
            p = preparar_t1(rng, self.dom)
            return self.medir(oid, lambda: ejecutar_t1(self.con, p))
        o = self.ops[oid]
        params = o.gen(rng, self.dom)
        con = self.con
        if o.lee:
            return self.medir(oid, lambda: (con.consultar(o.sql, params), "ok")[1])
        return self.medir(oid, lambda: (con.ejecutar(o.sql, params), "ok")[1])


# ----------------------------------------------------------- calentamiento
def _sin_medir(con: Conexion, ops: dict, dom: Dominio, oid: str, rng: random.Random) -> None:
    try:
        if oid == "T1":
            ejecutar_t1(con, preparar_t1(rng, dom))
            return
        o = ops[oid]
        params = o.gen(rng, dom)
        con.consultar(o.sql, params) if o.lee else con.ejecutar(o.sql, params)
    except Exception:
        try:
            con.ejecutar("ROLLBACK")
        except Exception:
            pass


def calentar(spec: dict, con: Conexion, ops: dict, dom: Dominio, cfg: Config) -> None:
    carga, k = spec["carga"], spec["indice"]
    rng = random.Random(derivar_semilla(spec["seed_run"], "calentamiento", k))
    if carga == "W3":
        if k == 0:  # una lectura secuencial de las tablas involucradas
            for t in ("movimientos_inventario", "productos", "venta"):
                con.consultar(f"SELECT COUNT(*) FROM {t}")
        return
    ids = CARGAS[carga]
    if carga == "W2":  # una pasada de A1..A4 con otros parámetros
        orden = ids[:]
        rng.shuffle(orden)
        for oid in orden:
            _sin_medir(con, ops, dom, oid, rng)
        return
    fin = time.monotonic() + spec["calentamiento_s"]
    mezcla = cfg.get("w4")
    while time.monotonic() < fin and not spec["abort"].is_set():
        if carga == "W4":
            _sin_medir(con, ops, dom, elegir_op_w4(rng, mezcla), rng)
        else:
            orden = ids[:]
            rng.shuffle(orden)
            for oid in orden:
                if time.monotonic() >= fin:
                    break
                _sin_medir(con, ops, dom, oid, rng)


def linea_base_driver(con: Conexion, n: int) -> list[int]:
    """n ejecuciones de SELECT 1: costo fijo de driver, red local y protocolo (µs)."""
    out = []
    for _ in range(n):
        ini = time.perf_counter_ns()
        con.consultar("SELECT 1")
        out.append((time.perf_counter_ns() - ini) // 1000)
    return out


# --------------------------------------------------------------- bucles
def _bucle_tiempo(ej: Ejecutor, spec: dict, rng: random.Random, t_fin_ns: int, cfg: Config) -> None:
    carga, ids, abort, mezcla = spec["carga"], CARGAS[spec["carga"]], spec["abort"], cfg.get("w4")
    while True:
        if carga == "W4":
            oid = elegir_op_w4(rng, mezcla)
            if time.monotonic_ns() >= t_fin_ns or abort.is_set():
                return
            ej.op(oid, rng)
        else:
            orden = ids[:]
            rng.shuffle(orden)
            for oid in orden:
                if time.monotonic_ns() >= t_fin_ns or abort.is_set():
                    return
                ej.op(oid, rng)


def _bucle_w2(ej: Ejecutor, spec: dict, rng: random.Random, cfg: Config) -> None:
    lista = CARGAS["W2"] * cfg.get("ventanas.w2_repeticiones_por_consulta")
    rng.shuffle(lista)
    for oid in lista:
        if spec["abort"].is_set():
            return
        ej.op(oid, rng)


def particion_contigua(inicio: int, fin: int, n: int, k: int) -> tuple[int, int] | None:
    """Parte k de n de [inicio, fin] en rangos contiguos y disjuntos (None si queda vacía)."""
    total = fin - inicio + 1
    if total <= 0:
        return None
    tam = -(-total // n)
    lo = inicio + k * tam
    hi = min(fin, lo + tam - 1)
    return (lo, hi) if lo <= hi else None


def _sql_insert_mov(b: int) -> str:
    return ("INSERT INTO movimientos_inventario (id_producto, tipo_movimiento, cantidad, cantidad_anterior, "
            "cantidad_nueva, motivo) VALUES " + ", ".join(["(%s, %s, %s, %s, %s, %s)"] * b))


def _fases_w3(ej: Ejecutor, spec: dict, rng: random.Random, cfg: Config, dom: Dominio) -> None:
    k, n = spec["indice"], spec["n"]
    barrera, tl = spec["barrera"], spec["t_largo"]
    w3, con = cfg.get("w3"), ej.con
    for fase in FASES_W3:
        if fase == "R":
            continue  # la ejecuta el orquestador mientras los clientes esperan
        barrera.wait(tl)                                  # inicio de fase
        t_ini = time.monotonic_ns()
        filas = ops_fase = 0
        if fase == "E1":
            total = w3["filas_e1"]
            restante = total // n + (1 if k < total % n else 0)
            lote, cache_sql = w3["lote_e1"], {}
            while restante > 0 and not spec["abort"].is_set():
                b = min(lote, restante)
                sql = cache_sql.setdefault(b, _sql_insert_mov(b))
                plano: list = []
                for _ in range(b):
                    plano += [rng.randint(1, dom.productos), rng.choice(dom.tipos_mov), rng.randint(1, 50),
                              rng.randint(100, 499), rng.randint(50, 499), "Carga masiva W3"]
                r = ej.medir("E1", lambda s=sql, p=plano, bb=b: (con.ejecutar(s, p), ("ok", bb))[1])
                if isinstance(r, tuple):
                    filas += r[1]
                ops_fase += 1
                restante -= b
        elif fase == "E2":
            sel = random.Random(derivar_semilla(spec["seed_run"], "w3", "marcas")).sample(
                range(1, dom.marcas + 1), min(w3["marcas_e2"], dom.marcas))
            for marca in sel[k::n]:
                if spec["abort"].is_set():
                    break
                r = ej.medir("E2", lambda m=marca: ("ok", con.ejecutar(
                    "UPDATE productos SET precio_base = precio_base * %s WHERE id_marca = %s",
                    (w3["factor_precio_e2"], m))))
                if isinstance(r, tuple):
                    filas += r[1]
                ops_fase += 1
        elif fase == "E3":
            rango = particion_contigua(1, dom.ventas, n, k)
            if rango:
                r = ej.medir("E3", lambda: ("ok", con.ejecutar(
                    "UPDATE venta SET estado = 'entregada' WHERE estado = 'enviada' "
                    "AND fecha_venta < %s AND id_venta BETWEEN %s AND %s",
                    (dom.corte_e3, rango[0], rango[1]))))
                if isinstance(r, tuple):
                    filas += r[1]
                ops_fase += 1
        elif fase == "E4":
            rango = particion_contigua(spec["id_base"].value + 1, spec["id_max"].value, n, k)
            if rango:
                r = ej.medir("E4", lambda: ("ok", con.ejecutar(
                    "DELETE FROM movimientos_inventario WHERE id_movimiento BETWEEN %s AND %s",
                    (rango[0], rango[1]))))
                if isinstance(r, tuple):
                    filas += r[1]
                ops_fase += 1
        ej.res["fases"][fase] = {"t_ini_ns": t_ini, "t_fin_ns": time.monotonic_ns(),
                                 "filas": max(filas, 0), "ops": ops_fase}
        barrera.wait(tl)                                  # fin de fase


# ------------------------------------------------------------------ main
def trabajador(spec: dict) -> None:
    """Punto de entrada del proceso trabajador (importable: se usa el método 'spawn')."""
    k = spec["indice"]
    tmp = Path(spec["dir_tmp"])
    tmp.mkdir(parents=True, exist_ok=True)
    rec = Registro()
    res: dict = {"indice": k, "estado": "ok", "error": None, "primer_error": None,
                 "errores": {"deadlock": 0, "timeout": 0, "conexion": 0, "otro": 0},
                 "negocio": 0, "reconexiones": 0, "fases": {}, "baseline_us": [],
                 "t_ultimo_fin_ns": 0, "t_ventana_ns": 0}
    try:
        _vida(spec, rec, res)
    except threading.BrokenBarrierError:
        res["estado"] = "barrera_rota"
    except BaseException as e:  # noqa: BLE001
        res["estado"] = "error"
        res["error"] = f"{type(e).__name__}: {e}"
        try:
            spec["barrera"].abort()
        except Exception:
            pass
    finally:
        for nombre, arr in (("op", rec.op), ("st", rec.st), ("t", rec.t), ("lat", rec.lat)):
            with open(tmp / f"w{k}.{nombre}", "wb") as f:
                arr.tofile(f)
        escribir_json(tmp / f"w{k}.json", res)


def _vida(spec: dict, rec: Registro, res: dict) -> None:
    cfg = Config(spec["cfg_datos"], Path(spec["cfg_ruta"]) if spec["cfg_ruta"] else None)
    k, cpus = spec["indice"], spec.get("cpus") or []
    if cpus and hasattr(os, "sched_setaffinity"):
        try:
            os.sched_setaffinity(0, set(int(c) for c in cpus))
        except OSError:
            pass
    motor_cfg = cfg.motor(spec["motor"])
    dom = Dominio.desde_config(cfg)
    con = Conexion(motor_cfg, base=spec.get("base"), exigir_cext=spec["exigir_cext"])
    ops = construir_ops(motor_cfg["tipo"], spec["estrategia"], spec.get("filas_sbtest", 1))
    ej = Ejecutor(con, ops, dom, rec, res)
    barrera, tl, carga = spec["barrera"], spec["t_largo"], spec["carga"]

    barrera.wait(spec["t_conexion"])                                  # A
    if spec["calentar"]:
        calentar(spec, con, ops, dom, cfg)
    res["baseline_us"] = linea_base_driver(con, spec["linea_base_n"])
    barrera.wait(tl)                                                  # B
    barrera.wait(tl)                                                  # C
    t_ventana = spec["t_ventana"].value
    res["t_ventana_ns"] = t_ventana
    ej.t0_ns = t_ventana
    while time.monotonic_ns() < t_ventana:
        time.sleep(0.0005)

    rng = random.Random(derivar_semilla(spec["seed_run"], "cliente", k))
    if carga == "W3":
        _fases_w3(ej, spec, rng, cfg, dom)
        return
    if carga == "W2":
        _bucle_w2(ej, spec, rng, cfg)
    else:
        _bucle_tiempo(ej, spec, rng, t_ventana + int(spec["medicion_s"] * 1e9), cfg)
    barrera.wait(tl)                                                  # D
