#!/usr/bin/env python3
"""Dataset REDUCIDO para probar la cadena de herramientas (NO es el dataset de la tesis).

Crea el esquema y carga una versión pequeña de los datos, con las mismas tablas y
los mismos rangos que usa el cliente. Sirve para verificar el orquestador de punta
a punta en una máquina cualquiera. El dataset real se carga con los scripts
postgres_create_db.sql / postgres_populate_db.sql (y su equivalente MySQL).

Uso:  python scripts/dataset_prueba.py --config config/prueba.toml --motor pg [--escala 1]
"""
from __future__ import annotations

import argparse
import datetime as dt
import random
import sys
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from bench.config import Config  # noqa: E402
from bench.db import Conexion  # noqa: E402
from bench.imagenes import sentencias  # noqa: E402


def lotes(con: Conexion, tabla: str, cols: list[str], filas: list[tuple], tam: int = 500) -> None:
    ph = "(" + ", ".join(["%s"] * len(cols)) + ")"
    for i in range(0, len(filas), tam):
        parte = filas[i:i + tam]
        plano = [x for f in parte for x in f]
        con.ejecutar(f"INSERT INTO {tabla} ({', '.join(cols)}) VALUES " + ", ".join([ph] * len(parte)), plano)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--motor", required=True)
    ap.add_argument("--escala", type=float, default=1.0)
    a = ap.parse_args()
    cfg = Config.cargar(a.config)
    m = cfg.motor(a.motor)
    d = cfg.get("dataset")
    con = Conexion(m, exigir_cext=False)
    rng = random.Random(20260101)
    raiz_sql = Path(__file__).resolve().parent.parent / "sql"
    if con.tipo == "postgresql":
        con.ejecutar((raiz_sql / "postgres_create_db.sql").read_text(encoding="utf-8"))
    else:
        for s in sentencias((raiz_sql / "mysql_create_db.sql").read_text(encoding="utf-8")):
            con.ejecutar(s)
    U, M, P, V = d["usuarios"], d["marcas"], d["productos"], d["ventas"]
    bv, bm = dt.datetime.fromisoformat(d["fecha_base_venta"]), dt.datetime.fromisoformat(d["fecha_base_mov"])
    corte = bv + dt.timedelta(days=round(d["frac_corte_e3"] * d["dias_venta"]))
    lotes(con, "usuarios", ["nombre", "apellido", "email", "estado"],
          [(f"Nombre{i}", f"Apellido{i}", f"usuario{i}@ejemplo.com", rng.choice(["activo", "activo", "inactivo", "suspendido"])) for i in range(1, U + 1)])
    lotes(con, "marcas", ["nombre", "pais_origen"], [(f"Marca{i}", rng.choice(["AR", "US", "JP", "DE"])) for i in range(1, M + 1)])
    lotes(con, "categorias", ["nombre", "nivel"], [(f"Categoria{i}", 1) for i in range(1, 11)])
    lotes(con, "productos", ["sku", "nombre", "descripcion", "id_marca", "precio_base", "stock_actual", "estado"],
          [(f"SKU-{i:07d}", f"Producto {i} serie {i % 97}", f"Descripcion del producto numero {i} categoria {i % 50} calidad premium",
            rng.randint(1, M), Decimal(f"{rng.uniform(d['precio_min'], d['precio_max']):.2f}"), rng.randint(100, 1000),
            rng.choice(["disponible", "disponible", "disponible", "agotado", "descontinuado"])) for i in range(1, P + 1)])
    lotes(con, "producto_categoria", ["id_producto", "id_categoria", "es_principal"],
          [(i, rng.randint(1, 10), True) for i in range(1, P + 1)])
    lotes(con, "direcciones_envio", ["id_usuario", "calle", "ciudad", "estado_provincia", "codigo_postal"],
          [(i, f"Calle {i}", "Posadas", "Misiones", "3300") for i in range(1, U + 1)])
    estados = ["pendiente", "pagada", "enviada", "entregada", "cancelada", "devuelta"]
    ventas = []
    for i in range(1, V + 1):
        sub = Decimal(f"{rng.uniform(100, 30000):.2f}")
        imp = (sub * Decimal("0.21")).quantize(Decimal("0.01"))
        ventas.append((rng.randint(1, U), bv + dt.timedelta(days=rng.randint(0, d["dias_venta"] - 1), seconds=rng.randint(0, 86399)),
                       sub, imp, sub + imp, rng.choice(estados), rng.choice(["web", "app", "tienda_fisica", "telefono"])))
    lotes(con, "venta", ["id_usuario", "fecha_venta", "subtotal", "impuestos", "total", "estado", "canal_venta"], ventas)
    det = []
    for v in range(1, V + 1):
        for p in rng.sample(range(1, P + 1), rng.randint(1, 3)):
            c = rng.randint(1, 4)
            pu = Decimal(f"{rng.uniform(100, 15000):.2f}")
            det.append((v, p, c, pu, pu * c))
    lotes(con, "detalle_venta", ["id_venta", "id_producto", "cantidad", "precio_unitario", "subtotal_item"], det)
    lotes(con, "pagos", ["id_venta", "metodo_pago", "monto", "estado"],
          [(v, rng.choice(["tarjeta_credito", "paypal", "efectivo"]), Decimal("100.00"), "aprobado") for v in range(1, V + 1)])
    mov = int(P * 3)
    lotes(con, "movimientos_inventario", ["id_producto", "tipo_movimiento", "cantidad", "cantidad_anterior", "cantidad_nueva", "fecha_movimiento"],
          [(rng.randint(1, P), rng.choice(["entrada", "salida", "devolucion", "ajuste", "merma"]), rng.randint(1, 50), 100, 120,
            bm + dt.timedelta(days=rng.randint(0, d["dias_mov"] - 1), seconds=rng.randint(0, 86399))) for _ in range(mov)])
    pares = set()
    while len(pares) < min(P, U * 5, int(P * 0.75)):
        pares.add((rng.randint(1, U), rng.randint(1, P)))
    lotes(con, "resenas_productos", ["id_usuario", "id_producto", "calificacion", "comentario"],
          [(u, p, rng.randint(1, 5), f"Comentario sobre el producto {p} muy bueno") for u, p in sorted(pares)])
    lotes(con, "devoluciones", ["id_detalle_venta", "id_venta", "motivo", "monto_reembolso"],
          [(k, det[k - 1][0], rng.choice(["producto_defectuoso", "no_conforme", "otro"]), Decimal("50.00")) for k in range(1, min(len(det), 200) + 1)])
    for t in ("usuarios", "productos", "venta", "movimientos_inventario"):
        print(t, con.consultar(f"SELECT COUNT(*) FROM {t}")[0][0])
    con.cerrar()


if __name__ == "__main__":
    main()
