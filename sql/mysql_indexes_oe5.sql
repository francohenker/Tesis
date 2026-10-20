-- =====================================================
-- ÍNDICES PARA OE5 - MySQL 9.7.2 LTS (InnoDB)
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
--   E3  Especializados sobre texto (sección 4): índices FULLTEXT de InnoDB.
--       Equivalente en PostgreSQL: GIN y GiST sobre tsvector
--       (ver postgres_indexes_oe5.sql).
--
-- POR QUÉ E0 INCLUYE ÍNDICES DE CLAVES FORÁNEAS
--   InnoDB exige un índice sobre cada columna de clave foránea y lo crea
--   automáticamente al definir la restricción. Esos índices no se pueden
--   quitar sin eliminar la FK, de modo que un E0 "sin índices" no existe
--   en MySQL. La sección 0 los vuelve explícitos y con nombre (prefijo
--   fk_), igual que en PostgreSQL, para que ambos motores partan del
--   mismo estado y para que el reset de la sección 1 no choque con el
--   error 1553 ("índice necesario para una clave foránea").
--
-- PROTOCOLO DE USO (repetir para cada estrategia)
--   1. Sección 0: una sola vez, después de cargar los datos.
--   2. Sección 1: eliminar los índices de las estrategias E1-E3.
--   3. Ejecutar UNA sola de las secciones 2, 3 o 4, registrando el
--      tiempo de creación de cada índice (el cliente mysql informa el
--      tiempo de cada sentencia).
--   4. Sección 6: actualizar estadísticas.
--   5. Sección 7: listar índices y tamaños; guardar el resultado.
--   6. Ejecutar las consultas de prueba.
--
-- Ejecutar con el cliente mysql (usa DELIMITER). Si se lanza desde un
-- driver, crear el procedimiento de la sección 1 sin las líneas DELIMITER.
--
-- Consultas de texto: MATCH() debe nombrar exactamente las columnas del
-- índice FULLTEXT, por ejemplo:
--   WHERE MATCH(descripcion) AGAINST (:termino IN NATURAL LANGUAGE MODE)
--
-- Registrar en el entorno experimental los parámetros que afectan la
-- construcción de índices (innodb_ddl_buffer_size, innodb_ddl_threads).
-- =====================================================


-- =====================================================
-- 0. BASE ESTRUCTURAL (E0): ÍNDICES DE SOPORTE DE CLAVES FORÁNEAS
-- =====================================================
-- Ejecutar una sola vez tras la carga. No se eliminan en la sección 1.
-- Al crear un índice explícito equivalente, InnoDB puede descartar el
-- índice implícito que había generado para la FK. Verificar con la
-- sección 7 que quede un único índice por columna de FK; si persiste un
-- duplicado implícito (su nombre coincide con la columna o la restricción),
-- eliminarlo con ALTER TABLE ... DROP INDEX <nombre>.
-- Se omiten las FK que ya son la primera columna de una PK/UNIQUE:
--   categorias.id_categoria_padre   (uq_categoria_padre_nombre)
--   producto_categoria.id_producto  (PK compuesta)
--   detalle_venta.id_venta          (uq_venta_producto)
--   reseñas_productos.id_usuario    (uq_usuario_producto_reseña)

CREATE INDEX fk_productos_marca
    ON productos (id_marca);

CREATE INDEX fk_producto_categoria_categoria
    ON producto_categoria (id_categoria);

CREATE INDEX fk_direcciones_usuario
    ON direcciones_envio (id_usuario);

CREATE INDEX fk_venta_usuario
    ON venta (id_usuario);

CREATE INDEX fk_venta_direccion
    ON venta (id_direccion);

CREATE INDEX fk_detalle_producto
    ON detalle_venta (id_producto);

CREATE INDEX fk_pagos_venta
    ON pagos (id_venta);

CREATE INDEX fk_movimientos_producto
    ON movimientos_inventario (id_producto);

CREATE INDEX fk_movimientos_usuario
    ON movimientos_inventario (id_usuario_responsable);

CREATE INDEX fk_reseñas_producto
    ON reseñas_productos (id_producto);

CREATE INDEX fk_reseñas_venta
    ON reseñas_productos (id_venta);

CREATE INDEX fk_devoluciones_detalle
    ON devoluciones (id_detalle_venta);

CREATE INDEX fk_devoluciones_venta
    ON devoluciones (id_venta);


-- =====================================================
-- 1. RESET: VOLVER A E0
-- =====================================================
-- MySQL no admite DROP INDEX IF EXISTS. El procedimiento elimina un
-- índice solo si existe, de modo que el reset sea repetible.
-- Elimina todos los índices de E1, E2 y E3. Conserva PK, UNIQUE y la
-- sección 0. Ejecutar antes de aplicar cualquier estrategia.

DELIMITER $$

DROP PROCEDURE IF EXISTS oe5_quitar_indice$$

CREATE PROCEDURE oe5_quitar_indice(IN p_tabla VARCHAR(64), IN p_indice VARCHAR(64))
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.statistics
        WHERE table_schema = DATABASE()
          AND table_name = p_tabla
          AND index_name = p_indice
    ) THEN
        SET @oe5_sql = CONCAT('ALTER TABLE `', p_tabla, '` DROP INDEX `', p_indice, '`');
        PREPARE oe5_stmt FROM @oe5_sql;
        EXECUTE oe5_stmt;
        DEALLOCATE PREPARE oe5_stmt;
    END IF;
END$$

DELIMITER ;

-- E1
CALL oe5_quitar_indice('usuarios', 'idx_usuarios_estado');
CALL oe5_quitar_indice('usuarios', 'idx_usuarios_fecha_registro');
CALL oe5_quitar_indice('productos', 'idx_productos_estado');
CALL oe5_quitar_indice('productos', 'idx_productos_precio');
CALL oe5_quitar_indice('venta', 'idx_venta_fecha');
CALL oe5_quitar_indice('venta', 'idx_venta_estado');
CALL oe5_quitar_indice('venta', 'idx_venta_canal');
CALL oe5_quitar_indice('pagos', 'idx_pagos_estado');
CALL oe5_quitar_indice('movimientos_inventario', 'idx_movimientos_fecha');
CALL oe5_quitar_indice('movimientos_inventario', 'idx_movimientos_tipo');
CALL oe5_quitar_indice('reseñas_productos', 'idx_reseñas_calificacion');
CALL oe5_quitar_indice('devoluciones', 'idx_devoluciones_estado');

-- E2
CALL oe5_quitar_indice('venta', 'idx_venta_usuario_fecha');
CALL oe5_quitar_indice('venta', 'idx_venta_estado_fecha');
CALL oe5_quitar_indice('venta', 'idx_venta_canal_fecha');
CALL oe5_quitar_indice('detalle_venta', 'idx_detalle_producto_venta');
CALL oe5_quitar_indice('productos', 'idx_productos_marca_estado');
CALL oe5_quitar_indice('movimientos_inventario', 'idx_movimientos_producto_tipo_fecha');
CALL oe5_quitar_indice('reseñas_productos', 'idx_reseñas_producto_calificacion');

-- E3
CALL oe5_quitar_indice('productos', 'idx_productos_nombre_fts');
CALL oe5_quitar_indice('productos', 'idx_productos_descripcion_fts');
CALL oe5_quitar_indice('reseñas_productos', 'idx_reseñas_comentario_fts');


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
CREATE INDEX idx_reseñas_calificacion
    ON reseñas_productos (calificacion);

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
-- líderes, igual que en PostgreSQL.

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

-- Alta + baja: reseñas de un producto por calificación
CREATE INDEX idx_reseñas_producto_calificacion
    ON reseñas_productos (id_producto, calificacion);


-- =====================================================
-- 4. E3 - ÍNDICES ESPECIALIZADOS FULLTEXT (3)
-- =====================================================
-- Equivalente nativo de InnoDB para búsqueda de texto. No es idéntico a
-- GIN/GiST: no aplica reducción de palabras a su raíz (stemming), usa su
-- propia lista de palabras vacías y el tamaño mínimo de token por
-- defecto es 3 (innodb_ft_min_token_size). La comparación con PostgreSQL
-- debe interpretarse como contraste entre soluciones nativas.
-- Al crear el primer FULLTEXT, InnoDB agrega la columna oculta
-- FTS_DOC_ID y su índice: verificar con SHOW CREATE TABLE si persiste
-- tras el reset y, de ser así, documentarlo (afecta el tamaño de la tabla).

CREATE FULLTEXT INDEX idx_productos_nombre_fts
    ON productos (nombre);

CREATE FULLTEXT INDEX idx_productos_descripcion_fts
    ON productos (descripcion);

CREATE FULLTEXT INDEX idx_reseñas_comentario_fts
    ON reseñas_productos (comentario);


-- =====================================================
-- 5. RECONSTRUCCIÓN DE ÍNDICES TRAS INSERCIONES MASIVAS (OE4)
-- =====================================================
-- Ejecutar después de la carga de escritura masiva (W3-E1, INSERT en
-- movimientos_inventario). Medir cada sentencia y ejecutar solo las que
-- correspondan a la estrategia activa.
-- DROP INDEX + ADD INDEX en una misma sentencia reconstruye únicamente
-- ese índice (operación en línea, sin reescribir la tabla); es el
-- equivalente más cercano a REINDEX INDEX de PostgreSQL.

ALTER TABLE movimientos_inventario
    DROP INDEX fk_movimientos_producto,
    ADD INDEX fk_movimientos_producto (id_producto);                  -- E0

ALTER TABLE movimientos_inventario
    DROP INDEX fk_movimientos_usuario,
    ADD INDEX fk_movimientos_usuario (id_usuario_responsable);        -- E0

ALTER TABLE movimientos_inventario
    DROP INDEX idx_movimientos_fecha,
    ADD INDEX idx_movimientos_fecha (fecha_movimiento);               -- E1

ALTER TABLE movimientos_inventario
    DROP INDEX idx_movimientos_tipo,
    ADD INDEX idx_movimientos_tipo (tipo_movimiento);                 -- E1

ALTER TABLE movimientos_inventario
    DROP INDEX idx_movimientos_producto_tipo_fecha,
    ADD INDEX idx_movimientos_producto_tipo_fecha
        (id_producto, tipo_movimiento, fecha_movimiento);             -- E2


-- =====================================================
-- 6. ACTUALIZAR ESTADÍSTICAS (tras crear los índices de una estrategia)
-- =====================================================
-- Necesario para que el optimizador conozca la distribución de las
-- columnas y para que information_schema / mysql.innodb_index_stats
-- reporten tamaños actualizados.

ANALYZE TABLE usuarios, marcas, categorias, productos, producto_categoria,
              direcciones_envio, venta, detalle_venta, pagos,
              movimientos_inventario, reseñas_productos, devoluciones;


-- =====================================================
-- 7. VERIFICACIÓN: ÍNDICES ACTIVOS Y TAMAÑOS
-- =====================================================
-- Guardar el resultado de cada estrategia (cantidad de índices,
-- definición y tamaño en disco) para la sección de resultados.

SELECT table_name AS tabla,
       index_name AS indice,
       index_type AS tipo,
       GROUP_CONCAT(column_name ORDER BY seq_in_index) AS columnas
FROM information_schema.statistics
WHERE table_schema = DATABASE()
GROUP BY table_name, index_name, index_type
ORDER BY table_name, index_name;

SELECT table_name AS tabla,
       index_name AS indice,
       stat_value * @@innodb_page_size AS bytes
FROM mysql.innodb_index_stats
WHERE database_name = DATABASE()
  AND stat_name = 'size'
ORDER BY bytes DESC;
