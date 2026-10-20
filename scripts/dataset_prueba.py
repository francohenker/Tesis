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

MYSQL_SCHEMA = """
CREATE TABLE usuarios (id_usuario BIGINT AUTO_INCREMENT PRIMARY KEY, nombre VARCHAR(100) NOT NULL, apellido VARCHAR(100) NOT NULL,
  email VARCHAR(150) NOT NULL, telefono VARCHAR(20), fecha_registro DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  fecha_ultima_actividad DATETIME, estado VARCHAR(20) NOT NULL DEFAULT 'activo' CHECK (estado IN ('activo','inactivo','suspendido')),
  CONSTRAINT uq_usuarios_email UNIQUE (email));
CREATE TABLE marcas (id_marca INT AUTO_INCREMENT PRIMARY KEY, nombre VARCHAR(100) NOT NULL, pais_origen VARCHAR(50), descripcion TEXT,
  fecha_creacion DATETIME DEFAULT CURRENT_TIMESTAMP, CONSTRAINT uq_marcas_nombre UNIQUE (nombre));
CREATE TABLE categorias (id_categoria INT AUTO_INCREMENT PRIMARY KEY, nombre VARCHAR(100) NOT NULL, id_categoria_padre INT,
  descripcion TEXT, nivel SMALLINT DEFAULT 1, CONSTRAINT uq_categoria_padre_nombre UNIQUE (id_categoria_padre, nombre),
  FOREIGN KEY (id_categoria_padre) REFERENCES categorias(id_categoria) ON DELETE SET NULL);
CREATE TABLE productos (id_producto BIGINT AUTO_INCREMENT PRIMARY KEY, sku VARCHAR(50) NOT NULL, nombre VARCHAR(200) NOT NULL,
  descripcion TEXT, id_marca INT, precio_base DECIMAL(12,2) NOT NULL CHECK (precio_base >= 0),
  stock_actual INT NOT NULL DEFAULT 0 CHECK (stock_actual >= 0), peso_kg DECIMAL(6,2), fecha_alta DATETIME DEFAULT CURRENT_TIMESTAMP,
  fecha_baja DATETIME, estado VARCHAR(20) DEFAULT 'disponible' CHECK (estado IN ('disponible','agotado','descontinuado')),
  CONSTRAINT uq_productos_sku UNIQUE (sku), FOREIGN KEY (id_marca) REFERENCES marcas(id_marca) ON DELETE SET NULL);
CREATE TABLE producto_categoria (id_producto BIGINT NOT NULL, id_categoria INT NOT NULL, es_principal BOOLEAN DEFAULT FALSE,
  PRIMARY KEY (id_producto, id_categoria), FOREIGN KEY (id_producto) REFERENCES productos(id_producto) ON DELETE CASCADE,
  FOREIGN KEY (id_categoria) REFERENCES categorias(id_categoria) ON DELETE CASCADE);
CREATE TABLE direcciones_envio (id_direccion BIGINT AUTO_INCREMENT PRIMARY KEY, id_usuario BIGINT NOT NULL, alias VARCHAR(50),
  calle VARCHAR(200) NOT NULL, numero_exterior VARCHAR(20), numero_interior VARCHAR(20), colonia VARCHAR(100), ciudad VARCHAR(100) NOT NULL,
  estado_provincia VARCHAR(100) NOT NULL, codigo_postal VARCHAR(10) NOT NULL, pais VARCHAR(50) DEFAULT 'Argentina',
  es_principal BOOLEAN DEFAULT FALSE, fecha_creacion DATETIME DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (id_usuario) REFERENCES usuarios(id_usuario) ON DELETE CASCADE);
CREATE TABLE venta (id_venta BIGINT AUTO_INCREMENT PRIMARY KEY, id_usuario BIGINT NOT NULL, id_direccion BIGINT,
  fecha_venta DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, subtotal DECIMAL(12,2) NOT NULL CHECK (subtotal >= 0),
  impuestos DECIMAL(12,2) NOT NULL DEFAULT 0 CHECK (impuestos >= 0), descuento DECIMAL(12,2) NOT NULL DEFAULT 0 CHECK (descuento >= 0),
  total DECIMAL(12,2) NOT NULL CHECK (total >= 0),
  estado VARCHAR(30) NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente','pagada','enviada','entregada','cancelada','devuelta')),
  canal_venta VARCHAR(30) DEFAULT 'web' CHECK (canal_venta IN ('web','app','tienda_fisica','telefono')), notas TEXT,
  FOREIGN KEY (id_usuario) REFERENCES usuarios(id_usuario), FOREIGN KEY (id_direccion) REFERENCES direcciones_envio(id_direccion));
CREATE TABLE detalle_venta (id_detalle BIGINT AUTO_INCREMENT PRIMARY KEY, id_venta BIGINT NOT NULL, id_producto BIGINT NOT NULL,
  cantidad INT NOT NULL CHECK (cantidad > 0), precio_unitario DECIMAL(12,2) NOT NULL CHECK (precio_unitario >= 0),
  descuento_item DECIMAL(12,2) DEFAULT 0, subtotal_item DECIMAL(12,2) NOT NULL, CONSTRAINT uq_venta_producto UNIQUE (id_venta, id_producto),
  FOREIGN KEY (id_venta) REFERENCES venta(id_venta) ON DELETE CASCADE, FOREIGN KEY (id_producto) REFERENCES productos(id_producto));
CREATE TABLE pagos (id_pago BIGINT AUTO_INCREMENT PRIMARY KEY, id_venta BIGINT NOT NULL,
  metodo_pago VARCHAR(30) NOT NULL CHECK (metodo_pago IN ('tarjeta_credito','tarjeta_debito','paypal','transferencia','efectivo','cripto')),
  monto DECIMAL(12,2) NOT NULL CHECK (monto > 0),
  estado VARCHAR(20) NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente','aprobado','rechazado','reembolsado','cancelado')),
  referencia_bancaria VARCHAR(100), fecha_pago DATETIME DEFAULT CURRENT_TIMESTAMP, fecha_aprobacion DATETIME,
  FOREIGN KEY (id_venta) REFERENCES venta(id_venta));
CREATE TABLE movimientos_inventario (id_movimiento BIGINT AUTO_INCREMENT PRIMARY KEY, id_producto BIGINT NOT NULL,
  tipo_movimiento VARCHAR(20) NOT NULL CHECK (tipo_movimiento IN ('entrada','salida','devolucion','ajuste','merma')),
  cantidad INT NOT NULL, cantidad_anterior INT, cantidad_nueva INT, id_almacen VARCHAR(30) DEFAULT 'CENTRAL',
  id_usuario_responsable BIGINT, motivo TEXT, fecha_movimiento DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (id_producto) REFERENCES productos(id_producto), FOREIGN KEY (id_usuario_responsable) REFERENCES usuarios(id_usuario));
CREATE TABLE `reseñas_productos` (`id_reseña` BIGINT AUTO_INCREMENT PRIMARY KEY, id_usuario BIGINT NOT NULL, id_producto BIGINT NOT NULL,
  id_venta BIGINT, calificacion SMALLINT NOT NULL CHECK (calificacion BETWEEN 1 AND 5), titulo VARCHAR(150), comentario TEXT,
  imagen_url VARCHAR(500), `fecha_reseña` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, fecha_edicion DATETIME, votos_utiles INT DEFAULT 0,
  CONSTRAINT `uq_usuario_producto_reseña` UNIQUE (id_usuario, id_producto),
  FOREIGN KEY (id_usuario) REFERENCES usuarios(id_usuario) ON DELETE CASCADE,
  FOREIGN KEY (id_producto) REFERENCES productos(id_producto) ON DELETE CASCADE,
  FOREIGN KEY (id_venta) REFERENCES venta(id_venta) ON DELETE SET NULL);
CREATE TABLE devoluciones (id_devolucion BIGINT AUTO_INCREMENT PRIMARY KEY, id_detalle_venta BIGINT NOT NULL, id_venta BIGINT NOT NULL,
  motivo VARCHAR(50) NOT NULL CHECK (motivo IN ('producto_defectuoso','no_conforme','equivocado','talla_incorrecta','otro')),
  descripcion TEXT, estado VARCHAR(30) DEFAULT 'solicitada', monto_reembolso DECIMAL(12,2) NOT NULL CHECK (monto_reembolso >= 0),
  fecha_solicitud DATETIME DEFAULT CURRENT_TIMESTAMP, fecha_resolucion DATETIME,
  FOREIGN KEY (id_detalle_venta) REFERENCES detalle_venta(id_detalle), FOREIGN KEY (id_venta) REFERENCES venta(id_venta));
"""


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
    if con.tipo == "postgresql":
        con.ejecutar((Path(__file__).resolve().parent.parent / "sql" / "postgres_create_db.sql").read_text(encoding="utf-8"))
    else:
        con.ejecutar("SET FOREIGN_KEY_CHECKS = 0")
        for t in ("devoluciones", "pagos", "movimientos_inventario", "`reseñas_productos`", "direcciones_envio",
                  "producto_categoria", "detalle_venta", "venta", "productos", "categorias", "marcas", "usuarios"):
            con.ejecutar(f"DROP TABLE IF EXISTS {t}")
        con.ejecutar("SET FOREIGN_KEY_CHECKS = 1")
        for s in [x.strip() for x in MYSQL_SCHEMA.split(";\n") if x.strip()]:
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
    lotes(con, "`reseñas_productos`" if con.tipo == "mysql" else "reseñas_productos", ["id_usuario", "id_producto", "calificacion", "comentario"],
          [(u, p, rng.randint(1, 5), f"Comentario sobre el producto {p} muy bueno") for u, p in sorted(pares)])
    lotes(con, "devoluciones", ["id_detalle_venta", "id_venta", "motivo", "monto_reembolso"],
          [(k, det[k - 1][0], rng.choice(["producto_defectuoso", "no_conforme", "otro"]), Decimal("50.00")) for k in range(1, min(len(det), 200) + 1)])
    for t in ("usuarios", "productos", "venta", "movimientos_inventario"):
        print(t, con.consultar(f"SELECT COUNT(*) FROM {t}")[0][0])
    con.cerrar()


if __name__ == "__main__":
    main()
