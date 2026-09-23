-- =====================================================
-- ÍNDICES PARA OE5 - MySQL 9.7.1 LTS (InnoDB)
-- Tesis: Análisis Comparativo PostgreSQL vs MySQL
-- =====================================================
-- Estrategias contempladas:
--   1. Sin índices adicionales          → estado actual (script de creación limpio)
--   2. Índices B-Tree estándar
--   3. Índices compuestos
--   4. Índices especializados (FULLTEXT)
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

CREATE INDEX idx_usuarios_estado
    ON usuarios (estado);

CREATE INDEX idx_usuarios_fecha_registro
    ON usuarios (fecha_registro);

CREATE INDEX idx_productos_marca
    ON productos (id_marca);

CREATE INDEX idx_productos_estado
    ON productos (estado);

CREATE INDEX idx_productos_precio
    ON productos (precio_base);

CREATE INDEX idx_categorias_padre
    ON categorias (id_categoria_padre);

CREATE INDEX idx_direcciones_usuario
    ON direcciones_envio (id_usuario);

CREATE INDEX idx_venta_usuario
    ON venta (id_usuario);

CREATE INDEX idx_venta_fecha
    ON venta (fecha_venta);

CREATE INDEX idx_venta_estado
    ON venta (estado);

CREATE INDEX idx_venta_canal
    ON venta (canal_venta);

CREATE INDEX idx_detalle_producto
    ON detalle_venta (id_producto);

CREATE INDEX idx_pagos_venta
    ON pagos (id_venta);

CREATE INDEX idx_pagos_estado
    ON pagos (estado);

CREATE INDEX idx_movimientos_producto
    ON movimientos_inventario (id_producto);

CREATE INDEX idx_movimientos_fecha
    ON movimientos_inventario (fecha_movimiento);

CREATE INDEX idx_movimientos_tipo
    ON movimientos_inventario (tipo_movimiento);

CREATE INDEX idx_reseñas_producto
    ON reseñas_productos (id_producto);

CREATE INDEX idx_reseñas_calificacion
    ON reseñas_productos (calificacion);

CREATE INDEX idx_devoluciones_venta
    ON devoluciones (id_venta);

CREATE INDEX idx_devoluciones_estado
    ON devoluciones (estado);


-- =====================================================
-- 3. ÍNDICES COMPUESTOS
-- =====================================================
-- Orientados a consultas analíticas y filtros combinados
-- (alta selectividad cuando se usan varias columnas juntas).

-- Ventas de un usuario en un rango de fechas
CREATE INDEX idx_venta_usuario_fecha
    ON venta (id_usuario, fecha_venta);

-- Ventas por estado + fecha (reportes de estado en el tiempo)
CREATE INDEX idx_venta_estado_fecha
    ON venta (estado, fecha_venta);

-- Detalle de venta: producto + venta (útil en JOINs y agregaciones)
CREATE INDEX idx_detalle_producto_venta
    ON detalle_venta (id_producto, id_venta);

-- Productos por marca + estado (catálogo filtrado)
CREATE INDEX idx_productos_marca_estado
    ON productos (id_marca, estado);

-- Movimientos de un producto por tipo y fecha
CREATE INDEX idx_movimientos_producto_tipo_fecha
    ON movimientos_inventario (id_producto, tipo_movimiento, fecha_movimiento);

-- Reseñas de un producto ordenadas por calificación
CREATE INDEX idx_reseñas_producto_calificacion
    ON reseñas_productos (id_producto, calificacion);


-- =====================================================
-- 4. ÍNDICES ESPECIALIZADOS (FULLTEXT)
-- =====================================================
-- Demuestran capacidades avanzadas de MySQL para
-- búsquedas de texto completo.
-- Nota: FULLTEXT en InnoDB está disponible y es el
-- equivalente funcional más cercano a GIN de PostgreSQL
-- para este tipo de consultas.

-- Full-Text Search sobre nombre y descripción de productos
CREATE FULLTEXT INDEX idx_productos_nombre_fts
    ON productos (nombre);

CREATE FULLTEXT INDEX idx_productos_descripcion_fts
    ON productos (descripcion);

-- Full-Text Search sobre comentarios de reseñas
CREATE FULLTEXT INDEX idx_reseñas_comentario_fts
    ON reseñas_productos (comentario);


-- =====================================================
-- SCRIPT DE LIMPIEZA (eliminar todos los índices de OE5)
-- =====================================================
-- Ejecutar cuando se quiera volver al estado "sin índices
-- adicionales" o antes de aplicar otra estrategia.

/*
ALTER TABLE usuarios DROP INDEX idx_usuarios_estado;
ALTER TABLE usuarios DROP INDEX idx_usuarios_fecha_registro;

ALTER TABLE productos DROP INDEX idx_productos_marca;
ALTER TABLE productos DROP INDEX idx_productos_estado;
ALTER TABLE productos DROP INDEX idx_productos_precio;
ALTER TABLE productos DROP INDEX idx_productos_nombre_fts;
ALTER TABLE productos DROP INDEX idx_productos_descripcion_fts;

ALTER TABLE categorias DROP INDEX idx_categorias_padre;

ALTER TABLE direcciones_envio DROP INDEX idx_direcciones_usuario;

ALTER TABLE venta DROP INDEX idx_venta_usuario;
ALTER TABLE venta DROP INDEX idx_venta_fecha;
ALTER TABLE venta DROP INDEX idx_venta_estado;
ALTER TABLE venta DROP INDEX idx_venta_canal;
ALTER TABLE venta DROP INDEX idx_venta_usuario_fecha;
ALTER TABLE venta DROP INDEX idx_venta_estado_fecha;

ALTER TABLE detalle_venta DROP INDEX idx_detalle_producto;
ALTER TABLE detalle_venta DROP INDEX idx_detalle_producto_venta;

ALTER TABLE pagos DROP INDEX idx_pagos_venta;
ALTER TABLE pagos DROP INDEX idx_pagos_estado;

ALTER TABLE movimientos_inventario DROP INDEX idx_movimientos_producto;
ALTER TABLE movimientos_inventario DROP INDEX idx_movimientos_fecha;
ALTER TABLE movimientos_inventario DROP INDEX idx_movimientos_tipo;
ALTER TABLE movimientos_inventario DROP INDEX idx_movimientos_producto_tipo_fecha;

ALTER TABLE reseñas_productos DROP INDEX idx_reseñas_producto;
ALTER TABLE reseñas_productos DROP INDEX idx_reseñas_calificacion;
ALTER TABLE reseñas_productos DROP INDEX idx_reseñas_producto_calificacion;
ALTER TABLE reseñas_productos DROP INDEX idx_reseñas_comentario_fts;

ALTER TABLE devoluciones DROP INDEX idx_devoluciones_venta;
ALTER TABLE devoluciones DROP INDEX idx_devoluciones_estado;
*/
