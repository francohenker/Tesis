-- =====================================================
-- BASE DE DATOS: E-commerce (Tesis Comparativa SGBD)
-- Motor: MySQL 9.7.2 LTS (InnoDB)
-- Versión limpia: sin índices adicionales
-- (Solo se mantienen PKs y constraints UNIQUE)
-- =====================================================
-- La base se crea una sola vez (Tabla 3.1):
--
--   CREATE DATABASE tesis CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_bin;
--
-- utf8mb4_0900_bin ordena por punto de código, distingue mayúsculas y
-- acentos y no rellena con espacios: el mismo criterio que la locale
-- builtin C.UTF-8 de PostgreSQL. La collation por defecto de MySQL
-- (utf8mb4_0900_ai_ci) no distingue mayúsculas ni acentos.
--
-- Equivalencias de tipos (Tabla 3.1): TIMESTAMP de PostgreSQL ->
-- DATETIME(6) (sin zona horaria y con la misma precisión de microsegundos).
-- Identificadores sin «ñ»: resenas_productos, id_resena, fecha_resena.
--
-- CLAVES FORÁNEAS: este script NO las declara. Si se declararan aquí,
-- InnoDB crearía un índice automático por cada una antes de la carga y el
-- estado E0 no se podría construir igual que en PostgreSQL. Las 17 claves
-- foráneas (con las mismas acciones referenciales que en PostgreSQL) se
-- agregan en la sección 0 de mysql_indexes_oe5.sql, después de crear los
-- índices fk_*, que pasan a ser sus índices de soporte. La integridad
-- referencial de la carga se verifica al final de mysql_populate_db.sql.
-- =====================================================

SET NAMES utf8mb4;

-- Eliminar tablas si existen (orden inverso de dependencias)
SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS devoluciones;
DROP TABLE IF EXISTS pagos;
DROP TABLE IF EXISTS movimientos_inventario;
DROP TABLE IF EXISTS resenas_productos;
DROP TABLE IF EXISTS detalle_venta;
DROP TABLE IF EXISTS venta;
DROP TABLE IF EXISTS direcciones_envio;
DROP TABLE IF EXISTS producto_categoria;
DROP TABLE IF EXISTS productos;
DROP TABLE IF EXISTS categorias;
DROP TABLE IF EXISTS marcas;
DROP TABLE IF EXISTS usuarios;
SET FOREIGN_KEY_CHECKS = 1;

-- =====================================================
-- TABLAS DIMENSIONALES / CATÁLOGO
-- =====================================================

CREATE TABLE usuarios (
    id_usuario          BIGINT NOT NULL AUTO_INCREMENT,
    nombre              VARCHAR(100) NOT NULL,
    apellido            VARCHAR(100) NOT NULL,
    email               VARCHAR(150) NOT NULL,
    telefono            VARCHAR(20),
    fecha_registro      DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    fecha_ultima_actividad DATETIME(6) NULL,
    estado              VARCHAR(20) NOT NULL DEFAULT 'activo',
    PRIMARY KEY (id_usuario),
    UNIQUE KEY uq_usuarios_email (email),
    CONSTRAINT chk_usuarios_estado CHECK (estado IN ('activo', 'inactivo', 'suspendido')),
    CONSTRAINT chk_email_format CHECK (REGEXP_LIKE(email, '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$', 'i'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE marcas (
    id_marca            INT NOT NULL AUTO_INCREMENT,
    nombre              VARCHAR(100) NOT NULL,
    pais_origen         VARCHAR(50),
    descripcion         TEXT,
    fecha_creacion      DATETIME(6) NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id_marca),
    UNIQUE KEY uq_marcas_nombre (nombre)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE categorias (
    id_categoria        INT NOT NULL AUTO_INCREMENT,
    nombre              VARCHAR(100) NOT NULL,
    id_categoria_padre  INT NULL,
    descripcion         TEXT,
    nivel               SMALLINT DEFAULT 1,
    PRIMARY KEY (id_categoria),
    UNIQUE KEY uq_categoria_padre_nombre (id_categoria_padre, nombre)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE productos (
    id_producto         BIGINT NOT NULL AUTO_INCREMENT,
    sku                 VARCHAR(50) NOT NULL,
    nombre              VARCHAR(200) NOT NULL,
    descripcion         TEXT,
    id_marca            INT NULL,
    precio_base         DECIMAL(12,2) NOT NULL,
    stock_actual        INT NOT NULL DEFAULT 0,
    peso_kg             DECIMAL(6,2),
    fecha_alta          DATETIME(6) NULL DEFAULT CURRENT_TIMESTAMP(6),
    fecha_baja          DATETIME(6) NULL,
    estado              VARCHAR(20) DEFAULT 'disponible',
    PRIMARY KEY (id_producto),
    UNIQUE KEY uq_productos_sku (sku),
    CONSTRAINT chk_productos_precio CHECK (precio_base >= 0),
    CONSTRAINT chk_productos_stock CHECK (stock_actual >= 0),
    CONSTRAINT chk_productos_estado CHECK (estado IN ('disponible', 'agotado', 'descontinuado'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

-- Relación N:M entre productos y categorías
CREATE TABLE producto_categoria (
    id_producto         BIGINT NOT NULL,
    id_categoria        INT NOT NULL,
    es_principal        BOOLEAN DEFAULT FALSE,
    PRIMARY KEY (id_producto, id_categoria)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

-- =====================================================
-- TABLAS TRANSACCIONALES
-- =====================================================

CREATE TABLE direcciones_envio (
    id_direccion        BIGINT NOT NULL AUTO_INCREMENT,
    id_usuario          BIGINT NOT NULL,
    alias               VARCHAR(50),
    calle               VARCHAR(200) NOT NULL,
    numero_exterior     VARCHAR(20),
    numero_interior     VARCHAR(20),
    colonia             VARCHAR(100),
    ciudad              VARCHAR(100) NOT NULL,
    estado_provincia    VARCHAR(100) NOT NULL,
    codigo_postal       VARCHAR(10) NOT NULL,
    pais                VARCHAR(50) DEFAULT 'Argentina',
    es_principal        BOOLEAN DEFAULT FALSE,
    fecha_creacion      DATETIME(6) NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id_direccion)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE venta (
    id_venta            BIGINT NOT NULL AUTO_INCREMENT,
    id_usuario          BIGINT NOT NULL,
    id_direccion        BIGINT NULL,
    fecha_venta         DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    subtotal            DECIMAL(12,2) NOT NULL,
    impuestos           DECIMAL(12,2) NOT NULL DEFAULT 0,
    descuento           DECIMAL(12,2) NOT NULL DEFAULT 0,
    total               DECIMAL(12,2) NOT NULL,
    estado              VARCHAR(30) NOT NULL DEFAULT 'pendiente',
    canal_venta         VARCHAR(30) DEFAULT 'web',
    notas               TEXT,
    PRIMARY KEY (id_venta),
    CONSTRAINT chk_venta_subtotal CHECK (subtotal >= 0),
    CONSTRAINT chk_venta_impuestos CHECK (impuestos >= 0),
    CONSTRAINT chk_venta_descuento CHECK (descuento >= 0),
    CONSTRAINT chk_venta_total CHECK (total >= 0),
    CONSTRAINT chk_venta_estado CHECK (estado IN ('pendiente', 'pagada', 'enviada', 'entregada', 'cancelada', 'devuelta')),
    CONSTRAINT chk_venta_canal CHECK (canal_venta IN ('web', 'app', 'tienda_fisica', 'telefono'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE detalle_venta (
    id_detalle          BIGINT NOT NULL AUTO_INCREMENT,
    id_venta            BIGINT NOT NULL,
    id_producto         BIGINT NOT NULL,
    cantidad            INT NOT NULL,
    precio_unitario     DECIMAL(12,2) NOT NULL,
    descuento_item      DECIMAL(12,2) DEFAULT 0,
    subtotal_item       DECIMAL(12,2) NOT NULL,
    PRIMARY KEY (id_detalle),
    UNIQUE KEY uq_venta_producto (id_venta, id_producto),
    CONSTRAINT chk_detalle_cantidad CHECK (cantidad > 0),
    CONSTRAINT chk_detalle_precio CHECK (precio_unitario >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE pagos (
    id_pago             BIGINT NOT NULL AUTO_INCREMENT,
    id_venta            BIGINT NOT NULL,
    metodo_pago         VARCHAR(30) NOT NULL,
    monto               DECIMAL(12,2) NOT NULL,
    estado              VARCHAR(20) NOT NULL DEFAULT 'pendiente',
    referencia_bancaria VARCHAR(100),
    fecha_pago          DATETIME(6) NULL DEFAULT CURRENT_TIMESTAMP(6),
    fecha_aprobacion    DATETIME(6) NULL,
    PRIMARY KEY (id_pago),
    CONSTRAINT chk_pagos_metodo CHECK (metodo_pago IN ('tarjeta_credito', 'tarjeta_debito', 'paypal', 'transferencia', 'efectivo', 'cripto')),
    CONSTRAINT chk_pagos_monto CHECK (monto > 0),
    CONSTRAINT chk_pagos_estado CHECK (estado IN ('pendiente', 'aprobado', 'rechazado', 'reembolsado', 'cancelado'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE movimientos_inventario (
    id_movimiento       BIGINT NOT NULL AUTO_INCREMENT,
    id_producto         BIGINT NOT NULL,
    tipo_movimiento     VARCHAR(20) NOT NULL,
    cantidad            INT NOT NULL,
    cantidad_anterior   INT,
    cantidad_nueva      INT,
    id_almacen          VARCHAR(30) DEFAULT 'CENTRAL',
    id_usuario_responsable BIGINT NULL,
    motivo              TEXT,
    fecha_movimiento    DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id_movimiento),
    CONSTRAINT chk_movimientos_tipo CHECK (tipo_movimiento IN ('entrada', 'salida', 'devolucion', 'ajuste', 'merma'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE resenas_productos (
    id_resena           BIGINT NOT NULL AUTO_INCREMENT,
    id_usuario          BIGINT NOT NULL,
    id_producto         BIGINT NOT NULL,
    id_venta            BIGINT NULL,
    calificacion        SMALLINT NOT NULL,
    titulo              VARCHAR(150),
    comentario          TEXT,
    imagen_url          VARCHAR(500),
    fecha_resena        DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    fecha_edicion       DATETIME(6) NULL,
    votos_utiles        INT DEFAULT 0,
    PRIMARY KEY (id_resena),
    UNIQUE KEY uq_usuario_producto_resena (id_usuario, id_producto),
    CONSTRAINT chk_resenas_calificacion CHECK (calificacion BETWEEN 1 AND 5)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE devoluciones (
    id_devolucion       BIGINT NOT NULL AUTO_INCREMENT,
    id_detalle_venta    BIGINT NOT NULL,
    id_venta            BIGINT NOT NULL,
    motivo              VARCHAR(50) NOT NULL,
    descripcion         TEXT,
    estado              VARCHAR(30) DEFAULT 'solicitada',
    monto_reembolso     DECIMAL(12,2) NOT NULL,
    fecha_solicitud     DATETIME(6) NULL DEFAULT CURRENT_TIMESTAMP(6),
    fecha_resolucion    DATETIME(6) NULL,
    PRIMARY KEY (id_devolucion),
    CONSTRAINT chk_devoluciones_motivo CHECK (motivo IN ('producto_defectuoso', 'no_conforme', 'equivocado', 'talla_incorrecta', 'otro')),
    CONSTRAINT chk_devoluciones_estado CHECK (estado IN ('solicitada', 'aprobada', 'en_transito', 'recibida', 'rechazada', 'reembolsada')),
    CONSTRAINT chk_devoluciones_monto CHECK (monto_reembolso >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

-- =====================================================
-- FIN DEL SCRIPT
-- Los índices adicionales se crearán de forma controlada
-- según cada escenario experimental (OE5).
-- =====================================================
