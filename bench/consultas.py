"""Operaciones de las cargas de trabajo (sección 3.4.2 de la tesis).

Cada operación tiene un identificador (L1..L9, A1..A4, T1, U1, SB1), su SQL
(con marcadores %s, comunes a psycopg2 y mysql-connector) y un generador de
parámetros determinista: dado el mismo generador aleatorio, produce los mismos
valores para PostgreSQL y para MySQL.
"""
from __future__ import annotations

import datetime as dt
import random
from dataclasses import dataclass
from decimal import Decimal
from typing import Callable


@dataclass(frozen=True)
class Dominio:
    """Rangos de valores de los datos (coinciden con el script de población)."""
    usuarios: int = 30000
    marcas: int = 800
    productos: int = 500000
    ventas: int = 5000000
    fecha_base_venta: dt.datetime = dt.datetime(2021, 1, 1)
    dias_venta: int = 1500
    fecha_base_mov: dt.datetime = dt.datetime(2021, 1, 1)
    dias_mov: int = 1800
    precio_min: int = 100
    precio_max: int = 50100
    frac_precio: float = 0.002
    frac_fecha_venta: float = 0.01
    frac_fecha_mov: float = 0.05
    frac_corte_e3: float = 0.48
    estados_venta: tuple = ("pendiente", "pagada", "enviada", "entregada", "cancelada", "devuelta")
    canales: tuple = ("web", "app", "tienda_fisica", "telefono")
    tipos_mov: tuple = ("entrada", "salida", "devolucion", "ajuste", "merma")
    metodos_pago: tuple = ("tarjeta_credito", "tarjeta_debito", "paypal", "transferencia", "efectivo", "cripto")
    terminos_fts: tuple = ()

    @classmethod
    def desde_config(cls, cfg) -> "Dominio":
        d = cfg.get("dataset")
        return cls(
            usuarios=d["usuarios"], marcas=d["marcas"], productos=d["productos"], ventas=d["ventas"],
            fecha_base_venta=dt.datetime.fromisoformat(d["fecha_base_venta"]), dias_venta=d["dias_venta"],
            fecha_base_mov=dt.datetime.fromisoformat(d["fecha_base_mov"]), dias_mov=d["dias_mov"],
            precio_min=d["precio_min"], precio_max=d["precio_max"], frac_precio=d["frac_precio"],
            frac_fecha_venta=d["frac_fecha_venta"], frac_fecha_mov=d["frac_fecha_mov"],
            frac_corte_e3=d["frac_corte_e3"], terminos_fts=tuple(d.get("terminos_fts", [])))

    @property
    def corte_e3(self) -> dt.datetime:
        return self.fecha_base_venta + dt.timedelta(days=round(self.frac_corte_e3 * self.dias_venta))


def _dec(x: float) -> Decimal:
    return Decimal(f"{x:.2f}")


def _rango_fechas(rng: random.Random, base: dt.datetime, dias_total: int, frac: float):
    ancho = max(1, round(frac * dias_total))
    ini = rng.randint(0, max(0, dias_total - ancho))
    d = base + dt.timedelta(days=ini)
    return d, d + dt.timedelta(days=ancho)


# ---- generadores de parámetros (reciben el generador aleatorio y el dominio)
def g_vacio(rng, d):
    return ()


def g_id_producto(rng, d):
    return (rng.randint(1, d.productos),)


def g_id_usuario(rng, d):
    return (rng.randint(1, d.usuarios),)


def g_rango_precio(rng, d):
    ancho = (d.precio_max - d.precio_min) * d.frac_precio
    ini = rng.uniform(d.precio_min, d.precio_max - ancho)
    return (_dec(ini), _dec(ini + ancho))


def g_marca(rng, d):
    return (rng.randint(1, d.marcas),)


def g_estado_venta(rng, d):
    return (rng.choice(d.estados_venta),)


def g_canal_fechas(rng, d):
    desde, hasta = _rango_fechas(rng, d.fecha_base_venta, d.dias_venta, d.frac_fecha_venta)
    return (rng.choice(d.canales), desde, hasta)


def g_mov(rng, d):
    desde, hasta = _rango_fechas(rng, d.fecha_base_mov, d.dias_mov, d.frac_fecha_mov)
    return (rng.randint(1, d.productos), rng.choice(d.tipos_mov), desde, hasta)


def g_desde_venta(rng, d):
    return (d.fecha_base_venta + dt.timedelta(days=rng.randint(0, d.dias_venta - 1)),)


def g_id_venta(rng, d):
    return (rng.randint(1, d.ventas),)


def g_termino(rng, d):
    if d.terminos_fts:
        return (rng.choice(d.terminos_fts),)
    # token numérico de >= 3 dígitos: respeta innodb_ft_min_token_size=3
    return (str(rng.randint(100, max(100, d.productos))),)


@dataclass(frozen=True)
class OpEjecutable:
    id: str
    sql: str
    gen: Callable
    lee: bool = True


_SQL: dict[str, tuple[str, Callable | None, bool]] = {
    "L1": ("SELECT * FROM productos WHERE id_producto = %s", g_id_producto, True),
    "L2": ("SELECT id_venta, fecha_venta, total, estado FROM venta WHERE id_usuario = %s "
           "ORDER BY fecha_venta DESC LIMIT 20", g_id_usuario, True),
    "L3": ("SELECT id_producto, nombre, precio_base FROM productos "
           "WHERE precio_base BETWEEN %s AND %s ORDER BY precio_base LIMIT 50", g_rango_precio, True),
    "L4": ("SELECT id_producto, nombre, precio_base FROM productos "
           "WHERE id_marca = %s AND estado = 'disponible' ORDER BY precio_base LIMIT 50", g_marca, True),
    "L5": ("SELECT COUNT(*) FROM venta WHERE estado = %s", g_estado_venta, True),
    "L6": ("SELECT id_venta, total FROM venta WHERE canal_venta = %s "
           "AND fecha_venta BETWEEN %s AND %s ORDER BY fecha_venta LIMIT 100", g_canal_fechas, True),
    "L7": ("SELECT id_movimiento, cantidad, fecha_movimiento FROM movimientos_inventario "
           "WHERE id_producto = %s AND tipo_movimiento = %s "
           "AND fecha_movimiento BETWEEN %s AND %s ORDER BY fecha_movimiento", g_mov, True),
    "L8": ("SELECT calificacion, COUNT(*) AS cantidad FROM reseñas_productos "
           "WHERE id_producto = %s GROUP BY calificacion ORDER BY calificacion", g_id_producto, True),
    "A1": ("SELECT EXTRACT(YEAR FROM fecha_venta) AS anio, EXTRACT(MONTH FROM fecha_venta) AS mes, "
           "canal_venta, COUNT(*) AS ventas, SUM(total) AS monto FROM venta "
           "WHERE estado IN ('pagada', 'enviada', 'entregada') "
           "GROUP BY anio, mes, canal_venta ORDER BY anio, mes, canal_venta", g_vacio, True),
    "A2": ("SELECT p.id_producto, p.nombre, m.nombre AS marca, SUM(d.subtotal_item) AS ingresos "
           "FROM detalle_venta d JOIN venta v ON v.id_venta = d.id_venta "
           "JOIN productos p ON p.id_producto = d.id_producto JOIN marcas m ON m.id_marca = p.id_marca "
           "WHERE v.fecha_venta >= %s AND v.estado <> 'cancelada' "
           "GROUP BY p.id_producto, p.nombre, m.nombre ORDER BY ingresos DESC LIMIT 20", g_desde_venta, True),
    "A3": ("SELECT v.id_usuario, SUM(v.total) AS gasto FROM venta v GROUP BY v.id_usuario "
           "HAVING SUM(v.total) > (SELECT AVG(t.gasto) FROM (SELECT SUM(total) AS gasto "
           "FROM venta GROUP BY id_usuario) t) ORDER BY gasto DESC LIMIT 50", g_vacio, True),
    "A4": ("SELECT m.nombre AS marca, dv.motivo, COUNT(*) AS devoluciones, SUM(dv.monto_reembolso) AS reembolsado "
           "FROM devoluciones dv JOIN detalle_venta d ON d.id_detalle = dv.id_detalle_venta "
           "JOIN productos p ON p.id_producto = d.id_producto JOIN marcas m ON m.id_marca = p.id_marca "
           "GROUP BY m.nombre, dv.motivo ORDER BY reembolsado DESC LIMIT 20", g_vacio, True),
    "U1": ("UPDATE venta SET estado = 'enviada' WHERE id_venta = %s AND estado = 'pagada'", g_id_venta, False),
    "SB1": ("SELECT c FROM sbtest1 WHERE id = %s", None, True),   # equivale a oltp_point_select
}

CARGAS: dict[str, list[str]] = {
    "W1": ["L1", "L2", "L3", "L4", "L5", "L6", "L7", "L8"],
    "W2": ["A1", "A2", "A3", "A4"],
    "W4": ["L1", "L2", "L4", "T1", "U1"],
    "T9": ["L9"],
    "SB1": ["SB1"],
}
FASES_W3 = ["E1", "R", "E2", "E3", "E4"]
CARGAS_VALIDAS = ("W1", "W2", "W3", "W4", "T9", "SB1")


def sql_l9(tipo_motor: str, estrategia: str) -> tuple[str, bool]:
    """Búsqueda de texto. Devuelve (sql, usa_patron_like).

    PostgreSQL: misma expresión to_tsvector en todas las estrategias (sin índice
    recorre la tabla calculando el vector de cada fila; con GIN/GiST usa el índice).
    MySQL: MATCH ... AGAINST exige un índice FULLTEXT, que no existe en E0;
    la línea base sin índice usa LIKE '%término%'.
    """
    if tipo_motor == "postgresql":
        return ("SELECT id_producto, nombre FROM productos "
                "WHERE to_tsvector('spanish', coalesce(descripcion, '')) "
                "@@ plainto_tsquery('spanish', %s) LIMIT 50", False)
    if estrategia.startswith("E3"):
        return ("SELECT id_producto, nombre FROM productos "
                "WHERE MATCH(descripcion) AGAINST (%s IN NATURAL LANGUAGE MODE) LIMIT 50", False)
    return ("SELECT id_producto, nombre FROM productos WHERE descripcion LIKE %s LIMIT 50", True)


def construir_ops(tipo_motor: str, estrategia: str, filas_sbtest: int = 1) -> dict[str, OpEjecutable]:
    """Operaciones listas para ejecutar, ajustadas al motor y a la estrategia."""
    ops: dict[str, OpEjecutable] = {}
    for oid, (sql, gen, lee) in _SQL.items():
        if oid == "SB1":
            def g_sb(rng, d, _n=filas_sbtest):
                return (rng.randint(1, _n),)
            ops[oid] = OpEjecutable(oid, sql, g_sb, True)
        else:
            ops[oid] = OpEjecutable(oid, sql, gen, lee)
    sql9, like = sql_l9(tipo_motor, estrategia)
    if like:
        def g_like(rng, d):
            (t,) = g_termino(rng, d)
            return (f"%{t}%",)
        ops["L9"] = OpEjecutable("L9", sql9, g_like, True)
    else:
        ops["L9"] = OpEjecutable("L9", sql9, g_termino, True)
    return ops


def elegir_op_w4(rng: random.Random, mezcla: dict) -> str:
    r = rng.random()
    if r < mezcla["lectura"]:
        return rng.choice(("L1", "L2", "L4"))
    if r < mezcla["lectura"] + mezcla["compra"]:
        return "T1"
    return "U1"


def preparar_t1(rng: random.Random, d: Dominio) -> dict:
    """Parámetros de la transacción de compra (se generan antes de medir)."""
    p = rng.randint(1, d.productos)
    q = rng.randint(1, 5)
    k = rng.randint(2, 3)
    productos = [p]
    while len(productos) < k:
        x = rng.randint(1, d.productos)
        if x not in productos:
            productos.append(x)
    items, subtotal = [], Decimal("0.00")
    for i, prod in enumerate(productos):
        cant = q if i == 0 else rng.randint(1, 3)
        precio = _dec(rng.uniform(100, 15000))
        sub = (precio * cant).quantize(Decimal("0.01"))
        subtotal += sub
        items.append((prod, cant, precio, sub))
    impuestos = (subtotal * Decimal("0.21")).quantize(Decimal("0.01"))
    return {"producto": p, "cantidad": q, "items": items, "subtotal": subtotal, "impuestos": impuestos,
            "total": subtotal + impuestos, "usuario": rng.randint(1, d.usuarios),
            "canal": rng.choice(d.canales), "metodo": rng.choice(d.metodos_pago)}


_SQL_T1_VENTA = ("INSERT INTO venta (id_usuario, subtotal, impuestos, descuento, total, estado, canal_venta) "
                 "VALUES (%s, %s, %s, 0, %s, 'pagada', %s)")


def ejecutar_t1(con, p: dict) -> str:
    """Transacción de compra T1 (Tabla 3.23). Devuelve 'ok' o 'negocio'.

    Si el descuento de stock no afecta filas (stock insuficiente) la transacción
    se revierte y se informa como evento de negocio, no como error de rendimiento.
    """
    con.ejecutar("BEGIN" if con.tipo == "postgresql" else "START TRANSACTION")
    con.consultar("SELECT stock_actual FROM productos WHERE id_producto = %s", (p["producto"],))
    args = (p["usuario"], p["subtotal"], p["impuestos"], p["total"], p["canal"])
    if con.tipo == "postgresql":
        ((id_venta,),) = con.consultar(_SQL_T1_VENTA + " RETURNING id_venta", args)
    else:
        con.ejecutar(_SQL_T1_VENTA, args)
        id_venta = con.ultimo_id
    marcadores = ", ".join(["(%s, %s, %s, %s, %s)"] * len(p["items"]))
    plano: list = []
    for prod, cant, precio, sub in p["items"]:
        plano += [id_venta, prod, cant, precio, sub]
    con.ejecutar("INSERT INTO detalle_venta (id_venta, id_producto, cantidad, precio_unitario, subtotal_item) "
                 "VALUES " + marcadores, plano)
    filas = con.ejecutar("UPDATE productos SET stock_actual = stock_actual - %s "
                         "WHERE id_producto = %s AND stock_actual >= %s",
                         (p["cantidad"], p["producto"], p["cantidad"]))
    if filas == 0:
        con.ejecutar("ROLLBACK")
        return "negocio"
    con.ejecutar("INSERT INTO movimientos_inventario (id_producto, tipo_movimiento, cantidad) VALUES (%s, 'salida', %s)",
                 (p["producto"], p["cantidad"]))
    con.ejecutar("INSERT INTO pagos (id_venta, metodo_pago, monto, estado) VALUES (%s, %s, %s, 'aprobado')",
                 (id_venta, p["metodo"], p["total"]))
    con.ejecutar("COMMIT")
    return "ok"
