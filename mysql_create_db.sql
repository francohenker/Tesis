-- =====================================================
-- BASE DE DATOS: E-commerce (Tesis Comparativa SGBD)
-- Motor: MySQL 9.7.1 LTS (InnoDB)
-- Versión limpia: sin índices adicionales
-- (Solo se mantienen PKs y constraints UNIQUE)
-- =====================================================

-- Eliminar tablas si existen (orden inverso de dependencias)
DROP TABLE IF EXISTS devoluciones;
DROP TABLE IF EXISTS pagos;
DROP TABLE IF EXISTS movimientos_inventario;
DROP TABLE IF EXISTS reseñas_productos;
DROP TABLE IF EXISTS direcciones_envio;
DROP TABLE IF EXISTS producto_categoria;
DROP TABLE IF EXISTS detalle_venta;
DROP TABLE IF EXISTS venta;
DROP TABLE IF EXISTS productos;
DROP TABLE IF EXISTS categorias;
DROP TABLE IF EXISTS marcas;
DROP TABLE IF EXISTS usuarios;

-- =====================================================
-- TABLAS DIMENSIONALES / CATÁLOGO
-- =====================================================

CREATE TABLE usuarios (
    id_usuario          BIGINT NOT NULL AUTO_INCREMENT,
    nombre              VARCHAR(100) NOT NULL,
    apellido            VARCHAR(100) NOT NULL,
    email               VARCHAR(150) NOT NULL,
    telefono            VARCHAR(20),
    fecha_registro      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_ultima_actividad TIMESTAMP NULL,
    estado              VARCHAR(20) NOT NULL DEFAULT 'activo',
    PRIMARY KEY (id_usuario),
    UNIQUE KEY uq_usuarios_email (email),
    CONSTRAINT chk_usuarios_estado CHECK (estado IN ('activo', 'inactivo', 'suspendido'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE marcas (
    id_marca            INT NOT NULL AUTO_INCREMENT,
    nombre              VARCHAR(100) NOT NULL,
    pais_origen         VARCHAR(50),
    descripcion         TEXT,
    fecha_creacion      TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id_marca),
    UNIQUE KEY uq_marcas_nombre (nombre)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE categorias (
    id_categoria        INT NOT NULL AUTO_INCREMENT,
    nombre              VARCHAR(100) NOT NULL,
    id_categoria_padre  INT NULL,
    descripcion         TEXT,
    nivel               SMALLINT DEFAULT 1,
    PRIMARY KEY (id_categoria),
    UNIQUE KEY uq_categoria_padre_nombre (id_categoria_padre, nombre),
    CONSTRAINT fk_categorias_padre FOREIGN KEY (id_categoria_padre)
        REFERENCES categorias (id_categoria) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE productos (
    id_producto         BIGINT NOT NULL AUTO_INCREMENT,
    sku                 VARCHAR(50) NOT NULL,
    nombre              VARCHAR(200) NOT NULL,
    descripcion         TEXT,
    id_marca            INT NULL,
    precio_base         DECIMAL(12,2) NOT NULL,
    stock_actual        INT NOT NULL DEFAULT 0,
    peso_kg             DECIMAL(6,2),
    fecha_alta          TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_baja          TIMESTAMP NULL,
    estado              VARCHAR(20) DEFAULT 'disponible',
    PRIMARY KEY (id_producto),
    UNIQUE KEY uq_productos_sku (sku),
    CONSTRAINT fk_productos_marca FOREIGN KEY (id_marca)
        REFERENCES marcas (id_marca) ON DELETE SET NULL,
    CONSTRAINT chk_productos_precio CHECK (precio_base >= 0),
    CONSTRAINT chk_productos_stock CHECK (stock_actual >= 0),
    CONSTRAINT chk_productos_estado CHECK (estado IN ('disponible', 'agotado', 'descontinuado'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Relación N:M entre productos y categorías
CREATE TABLE producto_categoria (
    id_producto         BIGINT NOT NULL,
    id_categoria        INT NOT NULL,
    es_principal        BOOLEAN DEFAULT FALSE,
    PRIMARY KEY (id_producto, id_categoria),
    CONSTRAINT fk_pc_producto FOREIGN KEY (id_producto)
        REFERENCES productos (id_producto) ON DELETE CASCADE,
    CONSTRAINT fk_pc_categoria FOREIGN KEY (id_categoria)
        REFERENCES categorias (id_categoria) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

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
    fecha_creacion      TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id_direccion),
    CONSTRAINT fk_direcciones_usuario FOREIGN KEY (id_usuario)
        REFERENCES usuarios (id_usuario) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE venta (
    id_venta            BIGINT NOT NULL AUTO_INCREMENT,
    id_usuario          BIGINT NOT NULL,
    id_direccion        BIGINT NULL,
    fecha_venta         TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    subtotal            DECIMAL(12,2) NOT NULL,
    impuestos           DECIMAL(12,2) NOT NULL DEFAULT 0,
    descuento           DECIMAL(12,2) NOT NULL DEFAULT 0,
    total               DECIMAL(12,2) NOT NULL,
    estado              VARCHAR(30) NOT NULL DEFAULT 'pendiente',
    canal_venta         VARCHAR(30) DEFAULT 'web',
    notas               TEXT,
    PRIMARY KEY (id_venta),
    CONSTRAINT fk_venta_usuario FOREIGN KEY (id_usuario)
        REFERENCES usuarios (id_usuario),
    CONSTRAINT fk_venta_direccion FOREIGN KEY (id_direccion)
        REFERENCES direcciones_envio (id_direccion),
    CONSTRAINT chk_venta_subtotal CHECK (subtotal >= 0),
    CONSTRAINT chk_venta_impuestos CHECK (impuestos >= 0),
    CONSTRAINT chk_venta_descuento CHECK (descuento >= 0),
    CONSTRAINT chk_venta_total CHECK (total >= 0),
    CONSTRAINT chk_venta_estado CHECK (estado IN ('pendiente', 'pagada', 'enviada', 'entregada', 'cancelada', 'devuelta')),
    CONSTRAINT chk_venta_canal CHECK (canal_venta IN ('web', 'app', 'tienda_fisica', 'telefono'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

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
    CONSTRAINT fk_detalle_venta FOREIGN KEY (id_venta)
        REFERENCES venta (id_venta) ON DELETE CASCADE,
    CONSTRAINT fk_detalle_producto FOREIGN KEY (id_producto)
        REFERENCES productos (id_producto),
    CONSTRAINT chk_detalle_cantidad CHECK (cantidad > 0),
    CONSTRAINT chk_detalle_precio CHECK (precio_unitario >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE pagos (
    id_pago             BIGINT NOT NULL AUTO_INCREMENT,
    id_venta            BIGINT NOT NULL,
    metodo_pago         VARCHAR(30) NOT NULL,
    monto               DECIMAL(12,2) NOT NULL,
    estado              VARCHAR(20) NOT NULL DEFAULT 'pendiente',
    referencia_bancaria VARCHAR(100),
    fecha_pago          TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_aprobacion    TIMESTAMP NULL,
    PRIMARY KEY (id_pago),
    CONSTRAINT fk_pagos_venta FOREIGN KEY (id_venta)
        REFERENCES venta (id_venta),
    CONSTRAINT chk_pagos_metodo CHECK (metodo_pago IN ('tarjeta_credito', 'tarjeta_debito', 'paypal', 'transferencia', 'efectivo', 'cripto')),
    CONSTRAINT chk_pagos_monto CHECK (monto > 0),
    CONSTRAINT chk_pagos_estado CHECK (estado IN ('pendiente', 'aprobado', 'rechazado', 'reembolsado', 'cancelado'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

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
    fecha_movimiento    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id_movimiento),
    CONSTRAINT fk_movimientos_producto FOREIGN KEY (id_producto)
        REFERENCES productos (id_producto),
    CONSTRAINT fk_movimientos_usuario FOREIGN KEY (id_usuario_responsable)
        REFERENCES usuarios (id_usuario),
    CONSTRAINT chk_movimientos_tipo CHECK (tipo_movimiento IN ('entrada', 'salida', 'devolucion', 'ajuste', 'merma'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE reseñas_productos (
    id_reseña           BIGINT NOT NULL AUTO_INCREMENT,
    id_usuario          BIGINT NOT NULL,
    id_producto         BIGINT NOT NULL,
    id_venta            BIGINT NULL,
    calificacion        SMALLINT NOT NULL,
    titulo              VARCHAR(150),
    comentario          TEXT,
    imagen_url          VARCHAR(500),
    fecha_reseña        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_edicion       TIMESTAMP NULL,
    votos_utiles        INT DEFAULT 0,
    PRIMARY KEY (id_reseña),
    UNIQUE KEY uq_usuario_producto_reseña (id_usuario, id_producto),
    CONSTRAINT fk_reseñas_usuario FOREIGN KEY (id_usuario)
        REFERENCES usuarios (id_usuario) ON DELETE CASCADE,
    CONSTRAINT fk_reseñas_producto FOREIGN KEY (id_producto)
        REFERENCES productos (id_producto) ON DELETE CASCADE,
    CONSTRAINT fk_reseñas_venta FOREIGN KEY (id_venta)
        REFERENCES venta (id_venta) ON DELETE SET NULL,
    CONSTRAINT chk_reseñas_calificacion CHECK (calificacion BETWEEN 1 AND 5)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE devoluciones (
    id_devolucion       BIGINT NOT NULL AUTO_INCREMENT,
    id_detalle_venta    BIGINT NOT NULL,
    id_venta            BIGINT NOT NULL,
    motivo              VARCHAR(50) NOT NULL,
    descripcion         TEXT,
    estado              VARCHAR(30) DEFAULT 'solicitada',
    monto_reembolso     DECIMAL(12,2) NOT NULL,
    fecha_solicitud     TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_resolucion    TIMESTAMP NULL,
    PRIMARY KEY (id_devolucion),
    CONSTRAINT fk_devoluciones_detalle FOREIGN KEY (id_detalle_venta)
        REFERENCES detalle_venta (id_detalle),
    CONSTRAINT fk_devoluciones_venta FOREIGN KEY (id_venta)
        REFERENCES venta (id_venta),
    CONSTRAINT chk_devoluciones_motivo CHECK (motivo IN ('producto_defectuoso', 'no_conforme', 'equivocado', 'talla_incorrecta', 'otro')),
    CONSTRAINT chk_devoluciones_estado CHECK (estado IN ('solicitada', 'aprobada', 'en_transito', 'recibida', 'rechazada', 'reembolsada')),
    CONSTRAINT chk_devoluciones_monto CHECK (monto_reembolso >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================
-- FIN DEL SCRIPT
-- Los índices adicionales se crearán de forma controlada
-- según cada escenario experimental (OE5).
-- =====================================================
