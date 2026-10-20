-- =====================================================
-- BASE DE DATOS: E-commerce (Tesis Comparativa SGBD)
-- Motor: PostgreSQL 18
-- Versión limpia: sin índices adicionales
-- (Solo se mantienen PKs y constraints UNIQUE)
-- =====================================================

-- Eliminar tablas si existen (orden inverso de dependencias)
DROP TABLE IF EXISTS devoluciones CASCADE;
DROP TABLE IF EXISTS pagos CASCADE;
DROP TABLE IF EXISTS movimientos_inventario CASCADE;
DROP TABLE IF EXISTS reseñas_productos CASCADE;
DROP TABLE IF EXISTS direcciones_envio CASCADE;
DROP TABLE IF EXISTS producto_categoria CASCADE;
DROP TABLE IF EXISTS detalle_venta CASCADE;
DROP TABLE IF EXISTS venta CASCADE;
DROP TABLE IF EXISTS productos CASCADE;
DROP TABLE IF EXISTS categorias CASCADE;
DROP TABLE IF EXISTS marcas CASCADE;
DROP TABLE IF EXISTS usuarios CASCADE;

-- =====================================================
-- TABLAS DIMENSIONALES / CATÁLOGO
-- =====================================================

CREATE TABLE usuarios (
    id_usuario          BIGSERIAL PRIMARY KEY,
    nombre              VARCHAR(100) NOT NULL,
    apellido            VARCHAR(100) NOT NULL,
    email               VARCHAR(150) NOT NULL,
    telefono            VARCHAR(20),
    fecha_registro      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_ultima_actividad TIMESTAMP,
    estado              VARCHAR(20) NOT NULL DEFAULT 'activo'
                        CHECK (estado IN ('activo', 'inactivo', 'suspendido')),
    CONSTRAINT uq_usuarios_email UNIQUE (email),
    CONSTRAINT chk_email_format CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);

CREATE TABLE marcas (
    id_marca            SERIAL PRIMARY KEY,
    nombre              VARCHAR(100) NOT NULL,
    pais_origen         VARCHAR(50),
    descripcion         TEXT,
    fecha_creacion      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_marcas_nombre UNIQUE (nombre)
);

CREATE TABLE categorias (
    id_categoria        SERIAL PRIMARY KEY,
    nombre              VARCHAR(100) NOT NULL,
    id_categoria_padre  INTEGER REFERENCES categorias(id_categoria) ON DELETE SET NULL,
    descripcion         TEXT,
    nivel               SMALLINT DEFAULT 1,
    CONSTRAINT uq_categoria_padre_nombre UNIQUE (id_categoria_padre, nombre)
);

CREATE TABLE productos (
    id_producto         BIGSERIAL PRIMARY KEY,
    sku                 VARCHAR(50) NOT NULL,
    nombre              VARCHAR(200) NOT NULL,
    descripcion         TEXT,
    id_marca            INTEGER REFERENCES marcas(id_marca) ON DELETE SET NULL,
    precio_base         NUMERIC(12,2) NOT NULL CHECK (precio_base >= 0),
    stock_actual        INTEGER NOT NULL DEFAULT 0 CHECK (stock_actual >= 0),
    peso_kg             NUMERIC(6,2),
    fecha_alta          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    fecha_baja          TIMESTAMP,
    estado              VARCHAR(20) DEFAULT 'disponible'
                        CHECK (estado IN ('disponible', 'agotado', 'descontinuado')),
    CONSTRAINT uq_productos_sku UNIQUE (sku)
);

-- Relación N:M entre productos y categorías
CREATE TABLE producto_categoria (
    id_producto         BIGINT NOT NULL REFERENCES productos(id_producto) ON DELETE CASCADE,
    id_categoria        INTEGER NOT NULL REFERENCES categorias(id_categoria) ON DELETE CASCADE,
    es_principal        BOOLEAN DEFAULT FALSE,
    PRIMARY KEY (id_producto, id_categoria)
);

-- =====================================================
-- TABLAS TRANSACCIONALES
-- =====================================================

CREATE TABLE direcciones_envio (
    id_direccion        BIGSERIAL PRIMARY KEY,
    id_usuario          BIGINT NOT NULL REFERENCES usuarios(id_usuario) ON DELETE CASCADE,
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
    fecha_creacion      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE venta (
    id_venta            BIGSERIAL PRIMARY KEY,
    id_usuario          BIGINT NOT NULL REFERENCES usuarios(id_usuario),
    id_direccion        BIGINT REFERENCES direcciones_envio(id_direccion),
    fecha_venta         TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    subtotal            NUMERIC(12,2) NOT NULL CHECK (subtotal >= 0),
    impuestos           NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (impuestos >= 0),
    descuento           NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (descuento >= 0),
    total               NUMERIC(12,2) NOT NULL CHECK (total >= 0),
    estado              VARCHAR(30) NOT NULL DEFAULT 'pendiente'
                        CHECK (estado IN ('pendiente', 'pagada', 'enviada', 'entregada', 'cancelada', 'devuelta')),
    canal_venta         VARCHAR(30) DEFAULT 'web'
                        CHECK (canal_venta IN ('web', 'app', 'tienda_fisica', 'telefono')),
    notas               TEXT
);

CREATE TABLE detalle_venta (
    id_detalle          BIGSERIAL PRIMARY KEY,
    id_venta            BIGINT NOT NULL REFERENCES venta(id_venta) ON DELETE CASCADE,
    id_producto         BIGINT NOT NULL REFERENCES productos(id_producto),
    cantidad            INTEGER NOT NULL CHECK (cantidad > 0),
    precio_unitario     NUMERIC(12,2) NOT NULL CHECK (precio_unitario >= 0),
    descuento_item      NUMERIC(12,2) DEFAULT 0,
    subtotal_item       NUMERIC(12,2) NOT NULL,
    CONSTRAINT uq_venta_producto UNIQUE (id_venta, id_producto)
);

CREATE TABLE pagos (
    id_pago             BIGSERIAL PRIMARY KEY,
    id_venta            BIGINT NOT NULL REFERENCES venta(id_venta),
    metodo_pago         VARCHAR(30) NOT NULL
                        CHECK (metodo_pago IN ('tarjeta_credito', 'tarjeta_debito', 'paypal', 'transferencia', 'efectivo', 'cripto')),
    monto               NUMERIC(12,2) NOT NULL CHECK (monto > 0),
    estado              VARCHAR(20) NOT NULL DEFAULT 'pendiente'
                        CHECK (estado IN ('pendiente', 'aprobado', 'rechazado', 'reembolsado', 'cancelado')),
    referencia_bancaria VARCHAR(100),
    fecha_pago          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    fecha_aprobacion    TIMESTAMP
);

CREATE TABLE movimientos_inventario (
    id_movimiento       BIGSERIAL PRIMARY KEY,
    id_producto         BIGINT NOT NULL REFERENCES productos(id_producto),
    tipo_movimiento     VARCHAR(20) NOT NULL
                        CHECK (tipo_movimiento IN ('entrada', 'salida', 'devolucion', 'ajuste', 'merma')),
    cantidad            INTEGER NOT NULL,
    cantidad_anterior   INTEGER,
    cantidad_nueva      INTEGER,
    id_almacen          VARCHAR(30) DEFAULT 'CENTRAL',
    id_usuario_responsable BIGINT REFERENCES usuarios(id_usuario),
    motivo              TEXT,
    fecha_movimiento    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE reseñas_productos (
    id_reseña           BIGSERIAL PRIMARY KEY,
    id_usuario          BIGINT NOT NULL REFERENCES usuarios(id_usuario) ON DELETE CASCADE,
    id_producto         BIGINT NOT NULL REFERENCES productos(id_producto) ON DELETE CASCADE,
    id_venta            BIGINT REFERENCES venta(id_venta) ON DELETE SET NULL,
    calificacion        SMALLINT NOT NULL CHECK (calificacion BETWEEN 1 AND 5),
    titulo              VARCHAR(150),
    comentario          TEXT,
    imagen_url          VARCHAR(500),
    fecha_reseña        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_edicion       TIMESTAMP,
    votos_utiles        INTEGER DEFAULT 0,
    CONSTRAINT uq_usuario_producto_reseña UNIQUE (id_usuario, id_producto)
);

CREATE TABLE devoluciones (
    id_devolucion       BIGSERIAL PRIMARY KEY,
    id_detalle_venta    BIGINT NOT NULL REFERENCES detalle_venta(id_detalle),
    id_venta            BIGINT NOT NULL REFERENCES venta(id_venta),
    motivo              VARCHAR(50) NOT NULL
                        CHECK (motivo IN ('producto_defectuoso', 'no_conforme', 'equivocado', 'talla_incorrecta', 'otro')),
    descripcion         TEXT,
    estado              VARCHAR(30) DEFAULT 'solicitada'
                        CHECK (estado IN ('solicitada', 'aprobada', 'en_transito', 'recibida', 'rechazada', 'reembolsada')),
    monto_reembolso     NUMERIC(12,2) NOT NULL CHECK (monto_reembolso >= 0),
    fecha_solicitud     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    fecha_resolucion    TIMESTAMP
);

-- =====================================================
-- FIN DEL SCRIPT
-- Los índices adicionales se crearán de forma controlada
-- según cada escenario experimental (OE5).
-- =====================================================
