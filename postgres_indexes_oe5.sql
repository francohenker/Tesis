-- =====================================================
-- ÍNDICES PARA OE5 - PostgreSQL 18
-- Tesis: Análisis Comparativo PostgreSQL vs MySQL
-- =====================================================
-- Estrategias contempladas:
--   1. Sin índices adicionales          → estado actual (script de creación limpio)
--   2. Índices B-Tree estándar
--   3. Índices compuestos
--   4. Índices especializados (GIN / GiST)
--
-- Uso recomendado:
--   - Ejecutar solo la sección correspondiente a cada experimento
--   - Antes de cambiar de estrategia, eliminar los índices de la anterior
-- =====================================================


-- =====================================================
-- 2. ÍNDICES B-TREE ESTÁNDAR
-- =====================================================
-- Cubren las columnas más utilizadas en filtros, JOINs y
-- búsquedas por igualdad o rango (lecturas simples y
-- parte de las consultas analíticas).

CREATE INDEX IF NOT EXISTS idx_usuarios_estado
    ON usuarios (estado);

CREATE INDEX IF NOT EXISTS idx_usuarios_fecha_registro
    ON usuarios (fecha_registro);

CREATE INDEX IF NOT EXISTS idx_productos_marca
    ON productos (id_marca);

CREATE INDEX IF NOT EXISTS idx_productos_estado
    ON productos (estado);

CREATE INDEX IF NOT EXISTS idx_productos_precio
    ON productos (precio_base);

CREATE INDEX IF NOT EXISTS idx_categorias_padre
    ON categorias (id_categoria_padre);

CREATE INDEX IF NOT EXISTS idx_direcciones_usuario
    ON direcciones_envio (id_usuario);

CREATE INDEX IF NOT EXISTS idx_venta_usuario
    ON venta (id_usuario);

CREATE INDEX IF NOT EXISTS idx_venta_fecha
    ON venta (fecha_venta);

CREATE INDEX IF NOT EXISTS idx_venta_estado
    ON venta (estado);

CREATE INDEX IF NOT EXISTS idx_venta_canal
    ON venta (canal_venta);

CREATE INDEX IF NOT EXISTS idx_detalle_producto
    ON detalle_venta (id_producto);

CREATE INDEX IF NOT EXISTS idx_pagos_venta
    ON pagos (id_venta);

CREATE INDEX IF NOT EXISTS idx_pagos_estado
    ON pagos (estado);

CREATE INDEX IF NOT EXISTS idx_movimientos_producto
    ON movimientos_inventario (id_producto);

CREATE INDEX IF NOT EXISTS idx_movimientos_fecha
    ON movimientos_inventario (fecha_movimiento);

CREATE INDEX IF NOT EXISTS idx_movimientos_tipo
    ON movimientos_inventario (tipo_movimiento);

CREATE INDEX IF NOT EXISTS idx_reseñas_producto
    ON reseñas_productos (id_producto);

CREATE INDEX IF NOT EXISTS idx_reseñas_calificacion
    ON reseñas_productos (calificacion);

CREATE INDEX IF NOT EXISTS idx_devoluciones_venta
    ON devoluciones (id_venta);

CREATE INDEX IF NOT EXISTS idx_devoluciones_estado
    ON devoluciones (estado);


-- =====================================================
-- 3. ÍNDICES COMPUESTOS
-- =====================================================
-- Orientados a consultas analíticas y filtros combinados
-- (alta selectividad cuando se usan varias columnas juntas).

-- Ventas de un usuario en un rango de fechas
CREATE INDEX IF NOT EXISTS idx_venta_usuario_fecha
    ON venta (id_usuario, fecha_venta);

-- Ventas por estado + fecha (reportes de estado en el tiempo)
CREATE INDEX IF NOT EXISTS idx_venta_estado_fecha
    ON venta (estado, fecha_venta);

-- Detalle de venta: producto + venta (útil en JOINs y agregaciones)
CREATE INDEX IF NOT EXISTS idx_detalle_producto_venta
    ON detalle_venta (id_producto, id_venta);

-- Productos por marca + estado (catálogo filtrado)
CREATE INDEX IF NOT EXISTS idx_productos_marca_estado
    ON productos (id_marca, estado);

-- Movimientos de un producto por tipo y fecha
CREATE INDEX IF NOT EXISTS idx_movimientos_producto_tipo_fecha
    ON movimientos_inventario (id_producto, tipo_movimiento, fecha_movimiento);

-- Reseñas de un producto ordenadas por calificación
CREATE INDEX IF NOT EXISTS idx_reseñas_producto_calificacion
    ON reseñas_productos (id_producto, calificacion);


-- =====================================================
-- 4. ÍNDICES ESPECIALIZADOS (GIN / GiST)
-- =====================================================
-- Demuestran capacidades avanzadas de PostgreSQL.
-- Se usan principalmente en búsquedas de texto y
-- consultas sobre columnas de baja/alta cardinalidad
-- con patrones más complejos.

-- Full-Text Search sobre nombre y descripción de productos
-- (requiere la extensión / configuración por defecto 'spanish' o 'english')
CREATE INDEX IF NOT EXISTS idx_productos_nombre_fts
    ON productos USING GIN (to_tsvector('spanish', coalesce(nombre, '')));

CREATE INDEX IF NOT EXISTS idx_productos_descripcion_fts
    ON productos USING GIN (to_tsvector('spanish', coalesce(descripcion, '')));

-- Full-Text Search sobre comentarios de reseñas
CREATE INDEX IF NOT EXISTS idx_reseñas_comentario_fts
    ON reseñas_productos USING GIN (to_tsvector('spanish', coalesce(comentario, '')));

-- Ejemplo de índice GiST (útil si más adelante se agregan
-- columnas geométricas o de rango). Por ahora se deja
-- comentado como referencia:
-- CREATE INDEX IF NOT EXISTS idx_ejemplo_gist
--     ON alguna_tabla USING GIST (columna_geometrica);


-- =====================================================
-- SCRIPT DE LIMPIEZA (eliminar todos los índices de OE5)
-- =====================================================
-- Ejecutar cuando se quiera volver al estado "sin índices
-- adicionales" o antes de aplicar otra estrategia.

/*
DROP INDEX IF EXISTS idx_usuarios_estado;
DROP INDEX IF EXISTS idx_usuarios_fecha_registro;
DROP INDEX IF EXISTS idx_productos_marca;
DROP INDEX IF EXISTS idx_productos_estado;
DROP INDEX IF EXISTS idx_productos_precio;
DROP INDEX IF EXISTS idx_categorias_padre;
DROP INDEX IF EXISTS idx_direcciones_usuario;
DROP INDEX IF EXISTS idx_venta_usuario;
DROP INDEX IF EXISTS idx_venta_fecha;
DROP INDEX IF EXISTS idx_venta_estado;
DROP INDEX IF EXISTS idx_venta_canal;
DROP INDEX IF EXISTS idx_detalle_producto;
DROP INDEX IF EXISTS idx_pagos_venta;
DROP INDEX IF EXISTS idx_pagos_estado;
DROP INDEX IF EXISTS idx_movimientos_producto;
DROP INDEX IF EXISTS idx_movimientos_fecha;
DROP INDEX IF EXISTS idx_movimientos_tipo;
DROP INDEX IF EXISTS idx_reseñas_producto;
DROP INDEX IF EXISTS idx_reseñas_calificacion;
DROP INDEX IF EXISTS idx_devoluciones_venta;
DROP INDEX IF EXISTS idx_devoluciones_estado;

DROP INDEX IF EXISTS idx_venta_usuario_fecha;
DROP INDEX IF EXISTS idx_venta_estado_fecha;
DROP INDEX IF EXISTS idx_detalle_producto_venta;
DROP INDEX IF EXISTS idx_productos_marca_estado;
DROP INDEX IF EXISTS idx_movimientos_producto_tipo_fecha;
DROP INDEX IF EXISTS idx_reseñas_producto_calificacion;

DROP INDEX IF EXISTS idx_productos_nombre_fts;
DROP INDEX IF EXISTS idx_productos_descripcion_fts;
DROP INDEX IF EXISTS idx_reseñas_comentario_fts;
*/
