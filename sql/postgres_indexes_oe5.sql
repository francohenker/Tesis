-- =====================================================
-- ÍNDICES PARA OE5 - PostgreSQL 18
-- Tesis: Análisis Comparativo PostgreSQL vs MySQL
-- =====================================================
-- OBJETIVOS QUE CUBRE
--   OE5  Comparar el rendimiento bajo cuatro estrategias de indexación
--        (sin índices, B-Tree estándar, compuestos y especializados),
--        analizando el efecto sobre columnas de alta y baja cardinalidad.
--   OE4  Tiempo de construcción y de reconstrucción de índices.
--
-- ESTRATEGIAS (cada una se aplica de forma INDEPENDIENTE sobre E0)
--   E0  Estado de partida: PK + UNIQUE + índices de soporte de
--       claves foráneas (sección 0). "Sin índices" = sin índices
--       ADICIONALES a los estructurales.
--   E1  B-Tree estándar de una columna sobre columnas de filtro que
--       no son claves foráneas: 8 de baja, 1 de media y 3 de alta
--       cardinalidad (sección 2).
--   E2  Compuestos que combinan columnas de distinta cardinalidad (sección 3).
--   E3  Especializados sobre texto (sección 4), en dos variantes:
--         E3-GIN   índices GIN sobre to_tsvector('spanish', ...)
--         E3-GiST  índices GiST sobre to_tsvector('spanish', ...)
--       Equivalente en MySQL: FULLTEXT (ver mysql_indexes_oe5.sql).
--
-- POR QUÉ E0 INCLUYE ÍNDICES DE CLAVES FORÁNEAS
--   InnoDB exige un índice sobre cada columna de clave foránea y lo crea
--   automáticamente si no existe. PostgreSQL no lo hace. Para que el punto
--   de partida sea el mismo en ambos motores, la sección 0 crea
--   explícitamente en PostgreSQL los índices que InnoDB genera por su cuenta.
--   Si se omite la sección 0, E0 en PostgreSQL deja de ser comparable con E0
--   en MySQL.
--
-- PROTOCOLO DE USO (repetir para cada estrategia)
--   1. Sección 0: una sola vez, después de cargar los datos.
--   2. Sección 1: eliminar los índices de las estrategias E1-E3.
--   3. Ejecutar UNA sola de las secciones 2, 3, 4A o 4B, registrando el
--      tiempo de creación de cada índice (\timing).
--   4. Sección 6: actualizar estadísticas.
--   5. Sección 7: listar índices y tamaños; guardar el resultado.
--   6. Ejecutar las consultas de prueba.
--
-- Consultas de texto: el predicado debe coincidir EXACTAMENTE con la
-- expresión indexada, por ejemplo:
--   WHERE to_tsvector('spanish', coalesce(descripcion, ''))
--         @@ plainto_tsquery('spanish', :termino)
--
-- Registrar en el entorno experimental los parámetros que afectan la
-- construcción de índices (maintenance_work_mem,
-- max_parallel_maintenance_workers).
-- =====================================================

\timing on


-- =====================================================
-- 0. BASE ESTRUCTURAL (E0): ÍNDICES DE SOPORTE DE CLAVES FORÁNEAS
-- =====================================================
-- Ejecutar una sola vez tras la carga. No se eliminan en la sección 1.
-- Se omiten las FK que ya son la primera columna de una PK/UNIQUE:
--   categorias.id_categoria_padre   (uq_categoria_padre_nombre)
--   producto_categoria.id_producto  (PK compuesta)
--   detalle_venta.id_venta          (uq_venta_producto)
--   resenas_productos.id_usuario    (uq_usuario_producto_resena)

CREATE INDEX IF NOT EXISTS fk_productos_marca
    ON productos (id_marca);

CREATE INDEX IF NOT EXISTS fk_producto_categoria_categoria
    ON producto_categoria (id_categoria);

CREATE INDEX IF NOT EXISTS fk_direcciones_usuario
    ON direcciones_envio (id_usuario);

CREATE INDEX IF NOT EXISTS fk_venta_usuario
    ON venta (id_usuario);

CREATE INDEX IF NOT EXISTS fk_venta_direccion
    ON venta (id_direccion);

CREATE INDEX IF NOT EXISTS fk_detalle_producto
    ON detalle_venta (id_producto);

CREATE INDEX IF NOT EXISTS fk_pagos_venta
    ON pagos (id_venta);

CREATE INDEX IF NOT EXISTS fk_movimientos_producto
    ON movimientos_inventario (id_producto);

CREATE INDEX IF NOT EXISTS fk_movimientos_usuario
    ON movimientos_inventario (id_usuario_responsable);

CREATE INDEX IF NOT EXISTS fk_resenas_producto
    ON resenas_productos (id_producto);

CREATE INDEX IF NOT EXISTS fk_resenas_venta
    ON resenas_productos (id_venta);

CREATE INDEX IF NOT EXISTS fk_devoluciones_detalle
    ON devoluciones (id_detalle_venta);

CREATE INDEX IF NOT EXISTS fk_devoluciones_venta
    ON devoluciones (id_venta);


-- =====================================================
-- 1. RESET: VOLVER A E0
-- =====================================================
-- Elimina todos los índices de E1, E2 y E3. Conserva PK, UNIQUE y la
-- sección 0. Ejecutar antes de aplicar cualquier estrategia.

-- E1
DROP INDEX IF EXISTS idx_usuarios_estado;
DROP INDEX IF EXISTS idx_usuarios_fecha_registro;
DROP INDEX IF EXISTS idx_productos_estado;
DROP INDEX IF EXISTS idx_productos_precio;
DROP INDEX IF EXISTS idx_venta_fecha;
DROP INDEX IF EXISTS idx_venta_estado;
DROP INDEX IF EXISTS idx_venta_canal;
DROP INDEX IF EXISTS idx_pagos_estado;
DROP INDEX IF EXISTS idx_movimientos_fecha;
DROP INDEX IF EXISTS idx_movimientos_tipo;
DROP INDEX IF EXISTS idx_resenas_calificacion;
DROP INDEX IF EXISTS idx_devoluciones_estado;

-- E2
DROP INDEX IF EXISTS idx_venta_usuario_fecha;
DROP INDEX IF EXISTS idx_venta_estado_fecha;
DROP INDEX IF EXISTS idx_venta_canal_fecha;
DROP INDEX IF EXISTS idx_detalle_producto_venta;
DROP INDEX IF EXISTS idx_productos_marca_estado;
DROP INDEX IF EXISTS idx_movimientos_producto_tipo_fecha;
DROP INDEX IF EXISTS idx_resenas_producto_calificacion;

-- E3 (GIN y GiST)
DROP INDEX IF EXISTS idx_productos_nombre_fts;
DROP INDEX IF EXISTS idx_productos_descripcion_fts;
DROP INDEX IF EXISTS idx_resenas_comentario_fts;
DROP INDEX IF EXISTS idx_productos_nombre_gist;
DROP INDEX IF EXISTS idx_productos_descripcion_gist;
DROP INDEX IF EXISTS idx_resenas_comentario_gist;


-- =====================================================
-- 2. E1 - ÍNDICES B-TREE ESTÁNDAR (12)
-- =====================================================
-- Una columna por índice, sobre columnas de filtro que NO son claves
-- foráneas (las FK ya están cubiertas en E0). Se clasifican por
-- cardinalidad para analizar su efecto (OE5).

-- --- Baja cardinalidad (≤ 10 valores distintos) ---

-- 3 valores
CREATE INDEX idx_usuarios_estado
    ON usuarios (estado);

-- 3 valores
CREATE INDEX idx_productos_estado
    ON productos (estado);

-- 6 valores
CREATE INDEX idx_venta_estado
    ON venta (estado);

-- 4 valores
CREATE INDEX idx_venta_canal
    ON venta (canal_venta);

-- 4 valores
CREATE INDEX idx_pagos_estado
    ON pagos (estado);

-- 5 valores
CREATE INDEX idx_movimientos_tipo
    ON movimientos_inventario (tipo_movimiento);

-- 5 valores
CREATE INDEX idx_resenas_calificacion
    ON resenas_productos (calificacion);

-- 6 valores
CREATE INDEX idx_devoluciones_estado
    ON devoluciones (estado);

-- --- Cardinalidad media (decenas a miles de valores) ---

-- 1.800 valores
CREATE INDEX idx_movimientos_fecha
    ON movimientos_inventario (fecha_movimiento);

-- --- Alta cardinalidad (más de 10.000 valores) ---

-- 30.000 valores
CREATE INDEX idx_usuarios_fecha_registro
    ON usuarios (fecha_registro);

-- ≈ 432.000 valores
CREATE INDEX idx_venta_fecha
    ON venta (fecha_venta);

-- ≈ 475.000 valores
CREATE INDEX idx_productos_precio
    ON productos (precio_base);


-- =====================================================
-- 3. E2 - ÍNDICES COMPUESTOS (7)
-- =====================================================
-- Combinan columnas de distinta cardinalidad. Se agregan sobre E0 (no
-- sobre E1). Coexisten con los índices fk_* de las mismas columnas
-- líderes, igual que en MySQL.

-- Alta + alta: ventas de un usuario en un rango de fechas
CREATE INDEX idx_venta_usuario_fecha
    ON venta (id_usuario, fecha_venta);

-- Baja + alta: reportes de estado en el tiempo
CREATE INDEX idx_venta_estado_fecha
    ON venta (estado, fecha_venta);

-- Baja + alta: ventas por canal en un rango de fechas
CREATE INDEX idx_venta_canal_fecha
    ON venta (canal_venta, fecha_venta);

-- Alta + alta: JOIN y agregaciones por producto
CREATE INDEX idx_detalle_producto_venta
    ON detalle_venta (id_producto, id_venta);

-- Media + baja: catálogo filtrado por marca y estado
CREATE INDEX idx_productos_marca_estado
    ON productos (id_marca, estado);

-- Alta + baja + media: historial de un producto por tipo y fecha
CREATE INDEX idx_movimientos_producto_tipo_fecha
    ON movimientos_inventario (id_producto, tipo_movimiento, fecha_movimiento);

-- Alta + baja: resenas de un producto por calificación
CREATE INDEX idx_resenas_producto_calificacion
    ON resenas_productos (id_producto, calificacion);


-- =====================================================
-- 4A. E3-GIN - ÍNDICES ESPECIALIZADOS GIN (3)
-- =====================================================
-- Búsqueda de texto completo sobre tsvector. GIN está optimizado para
-- búsquedas; su construcción y actualización son más costosas.
-- fastupdate permanece en su valor por defecto (on); documentarlo.

CREATE INDEX idx_productos_nombre_fts
    ON productos USING GIN (to_tsvector('spanish', coalesce(nombre, '')));

CREATE INDEX idx_productos_descripcion_fts
    ON productos USING GIN (to_tsvector('spanish', coalesce(descripcion, '')));

CREATE INDEX idx_resenas_comentario_fts
    ON resenas_productos USING GIN (to_tsvector('spanish', coalesce(comentario, '')));


-- =====================================================
-- 4B. E3-GiST - ÍNDICES ESPECIALIZADOS GiST (3)
-- =====================================================
-- Misma expresión indexada que en 4A, con GiST (índice con pérdida que
-- requiere re-verificar filas). Según la documentación de PostgreSQL,
-- se construye y actualiza más rápido que GIN, pero las búsquedas son
-- más lentas. El esquema no tiene columnas geométricas ni de rango, por
-- lo que GiST se aplica sobre texto para poder compararlo con GIN.
-- NO ejecutar junto con 4A: cada variante se evalúa por separado.

CREATE INDEX idx_productos_nombre_gist
    ON productos USING GIST (to_tsvector('spanish', coalesce(nombre, '')));

CREATE INDEX idx_productos_descripcion_gist
    ON productos USING GIST (to_tsvector('spanish', coalesce(descripcion, '')));

CREATE INDEX idx_resenas_comentario_gist
    ON resenas_productos USING GIST (to_tsvector('spanish', coalesce(comentario, '')));


-- =====================================================
-- 5. RECONSTRUCCIÓN DE ÍNDICES TRAS INSERCIONES MASIVAS (OE4)
-- =====================================================
-- Ejecutar después de la carga de escritura masiva (W3-E1, INSERT en
-- movimientos_inventario). Medir cada sentencia con \timing y ejecutar
-- solo las que correspondan a la estrategia activa.
-- REINDEX INDEX reconstruye únicamente el índice, sin reescribir la
-- tabla; el equivalente más cercano en MySQL es DROP INDEX + ADD INDEX.

REINDEX INDEX fk_movimientos_producto;                    -- E0
REINDEX INDEX fk_movimientos_usuario;                     -- E0
REINDEX INDEX idx_movimientos_fecha;                      -- E1
REINDEX INDEX idx_movimientos_tipo;                       -- E1
REINDEX INDEX idx_movimientos_producto_tipo_fecha;        -- E2


-- =====================================================
-- 6. ACTUALIZAR ESTADÍSTICAS (tras crear los índices de una estrategia)
-- =====================================================
-- Necesario para que el planificador conozca la distribución de las
-- columnas y de las expresiones indexadas (tsvector).

ANALYZE;


-- =====================================================
-- 7. VERIFICACIÓN: ÍNDICES ACTIVOS Y TAMAÑOS
-- =====================================================
-- Guardar el resultado de cada estrategia (cantidad de índices,
-- definición y tamaño en disco) para la sección de resultados.

SELECT tablename AS tabla, indexname AS indice, indexdef AS definicion
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;

SELECT relname AS tabla,
       indexrelname AS indice,
       pg_relation_size(indexrelid) AS bytes,
       pg_size_pretty(pg_relation_size(indexrelid)) AS tamano
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC;
