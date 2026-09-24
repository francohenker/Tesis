-- =====================================================
-- POBLACIÓN DE DATOS - MySQL 9.7.1 LTS (InnoDB)
-- Tesis: Análisis Comparativo PostgreSQL vs MySQL
-- =====================================================
-- Volúmenes objetivo (ajustados):
--   usuarios .............. 30.000
--   marcas ................ 800
--   categorias ............ 300
--   productos ............. 500.000
--   producto_categoria .... ~750.000
--   direcciones_envio ..... ~36.000
--   venta ................. 5.000.000
--   detalle_venta ......... 15.000.000
--   pagos .................. ~4.500.000
--   movimientos_inventario  2.000.000
--   reseñas_productos ..... ~1.000.000
--   devoluciones .......... ~300.000
--
-- NOTA: Para las tablas grandes (venta y detalle_venta)
-- se recomienda usar LOAD DATA INFILE o un generador
-- externo. Se incluyen procedimientos de ejemplo.
-- =====================================================

SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION';
SET SESSION unique_checks = 0;
SET SESSION foreign_key_checks = 0;
SET SESSION autocommit = 0;


-- =====================================================
-- 1. MARCAS (800)
-- =====================================================
DROP TEMPORARY TABLE IF EXISTS tmp_numbers;
CREATE TEMPORARY TABLE tmp_numbers (n INT PRIMARY KEY);

INSERT INTO tmp_numbers (n)
WITH RECURSIVE seq AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 800
)
SELECT n FROM seq;

INSERT INTO marcas (nombre, pais_origen, descripcion)
SELECT
    CONCAT('Marca_', n),
    ELT(1 + (n % 10), 'Argentina','Brasil','Chile','Estados Unidos','China','Alemania','Japón','Corea del Sur','Italia','España'),
    CONCAT('Descripción de la marca número ', n)
FROM tmp_numbers;

COMMIT;


-- =====================================================
-- 2. CATEGORÍAS (300)
-- =====================================================
INSERT INTO categorias (nombre, id_categoria_padre, descripcion, nivel)
SELECT
    CONCAT('Cat_Padre_', n),
    NULL,
    CONCAT('Categoría principal ', n),
    1
FROM tmp_numbers
WHERE n <= 50;

INSERT INTO categorias (nombre, id_categoria_padre, descripcion, nivel)
SELECT
    CONCAT('Cat_Hijo_', n),
    1 + ((n - 1) % 50),
    CONCAT('Subcategoría ', n),
    2
FROM tmp_numbers
WHERE n <= 250;

COMMIT;


-- =====================================================
-- 3. USUARIOS (30.000)
-- =====================================================
TRUNCATE tmp_numbers;
INSERT INTO tmp_numbers (n)
WITH RECURSIVE seq AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 30000
)
SELECT n FROM seq;

INSERT INTO usuarios (nombre, apellido, email, telefono, fecha_registro, fecha_ultima_actividad, estado)
SELECT
    CONCAT('Nombre_', n),
    CONCAT('Apellido_', n),
    CONCAT('usuario', n, '@email.com'),
    CONCAT('11', LPAD(n % 100000000, 8, '0')),
    DATE_ADD('2020-01-01', INTERVAL (n % 2000) DAY) + INTERVAL (n % 86400) SECOND,
    DATE_ADD('2023-01-01', INTERVAL (n % 1000) DAY),
    ELT(1 + (n % 6), 'activo','activo','activo','activo','inactivo','suspendido')
FROM tmp_numbers;

COMMIT;


-- =====================================================
-- 4. PRODUCTOS (500.000)
-- =====================================================
TRUNCATE tmp_numbers;
INSERT INTO tmp_numbers (n)
WITH RECURSIVE seq AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 500000
)
SELECT n FROM seq;

INSERT INTO productos (sku, nombre, descripcion, id_marca, precio_base, stock_actual, peso_kg, fecha_alta, estado)
SELECT
    CONCAT('SKU-', LPAD(n, 8, '0')),
    CONCAT('Producto ', n),
    CONCAT('Descripción detallada del producto número ', n, '. Ideal para pruebas de rendimiento.'),
    1 + (n % 800),
    ROUND(100 + (RAND() * 50000), 2),
    FLOOR(RAND() * 500),
    ROUND(0.1 + (RAND() * 20), 2),
    DATE_ADD('2019-01-01', INTERVAL (n % 2500) DAY),
    ELT(1 + (n % 6), 'disponible','disponible','disponible','disponible','agotado','descontinuado')
FROM tmp_numbers;

COMMIT;


-- =====================================================
-- 5. PRODUCTO_CATEGORIA (~750.000)
-- =====================================================
INSERT INTO producto_categoria (id_producto, id_categoria, es_principal)
SELECT
    p.id_producto,
    1 + (p.id_producto % 300),
    TRUE
FROM productos p;

INSERT INTO producto_categoria (id_producto, id_categoria, es_principal)
SELECT
    p.id_producto,
    1 + ((p.id_producto + 50) % 300),
    FALSE
FROM productos p
WHERE p.id_producto % 2 = 0;

COMMIT;


-- =====================================================
-- 6. DIRECCIONES DE ENVÍO (~36.000)
-- =====================================================
INSERT INTO direcciones_envio (id_usuario, alias, calle, numero_exterior, colonia, ciudad, estado_provincia, codigo_postal, pais, es_principal)
SELECT
    u.id_usuario,
    ELT(1 + (u.id_usuario % 3), 'Casa','Trabajo','Otro'),
    CONCAT('Calle ', u.id_usuario % 5000),
    CAST((u.id_usuario % 9000) + 1 AS CHAR),
    CONCAT('Barrio ', u.id_usuario % 200),
    ELT(1 + (u.id_usuario % 8), 'Buenos Aires','Córdoba','Rosario','Mendoza','La Plata','Mar del Plata','Salta','Tucumán'),
    ELT(1 + (u.id_usuario % 8), 'Buenos Aires','Córdoba','Santa Fe','Mendoza','Buenos Aires','Buenos Aires','Salta','Tucumán'),
    LPAD((u.id_usuario % 9000) + 1000, 4, '0'),
    'Argentina',
    TRUE
FROM usuarios u;

INSERT INTO direcciones_envio (id_usuario, alias, calle, numero_exterior, colonia, ciudad, estado_provincia, codigo_postal, pais, es_principal)
SELECT
    u.id_usuario,
    'Secundaria',
    CONCAT('Av. Alternativa ', u.id_usuario % 3000),
    CAST((u.id_usuario % 5000) + 1 AS CHAR),
    CONCAT('Barrio Alt ', u.id_usuario % 150),
    ELT(1 + (u.id_usuario % 4), 'Buenos Aires','Córdoba','Rosario','Mendoza'),
    ELT(1 + (u.id_usuario % 4), 'Buenos Aires','Córdoba','Santa Fe','Mendoza'),
    LPAD((u.id_usuario % 8000) + 2000, 4, '0'),
    'Argentina',
    FALSE
FROM usuarios u
WHERE u.id_usuario % 5 = 0;

COMMIT;


-- =====================================================
-- 7. VENTAS (5.000.000) - procedimiento por lotes
-- =====================================================
DELIMITER //

CREATE PROCEDURE IF NOT EXISTS sp_cargar_ventas()
BEGIN
    DECLARE batch_size INT DEFAULT 100000;
    DECLARE total_rows INT DEFAULT 5000000;
    DECLARE current_start INT DEFAULT 1;
    DECLARE current_end INT;
    DECLARE i INT;

    WHILE current_start <= total_rows DO
        SET current_end = LEAST(current_start + batch_size - 1, total_rows);
        SET i = current_start;

        START TRANSACTION;
        WHILE i <= current_end DO
            INSERT INTO venta (id_usuario, id_direccion, fecha_venta, subtotal, impuestos, descuento, total, estado, canal_venta)
            VALUES (
                1 + ((i - 1) % 30000),
                NULL,
                DATE_ADD('2021-01-01', INTERVAL (i % 1500) DAY) + INTERVAL (i % 86400) SECOND,
                ROUND(500 + (RAND() * 80000), 2),
                ROUND(RAND() * 15000, 2),
                ROUND(RAND() * 5000, 2),
                ROUND(500 + (RAND() * 90000), 2),
                ELT(1 + (i % 8), 'pendiente','pagada','pagada','pagada','enviada','entregada','cancelada','devuelta'),
                ELT(1 + (i % 7), 'web','web','web','app','app','tienda_fisica','telefono')
            );
            SET i = i + 1;
        END WHILE;
        COMMIT;

        SELECT CONCAT('Ventas insertadas: ', current_start, ' - ', current_end) AS progreso;
        SET current_start = current_end + 1;
    END WHILE;
END //

DELIMITER ;

-- Descomentar para ejecutar (puede demorar bastante):
-- CALL sp_cargar_ventas();


-- =====================================================
-- 8. DETALLE_VENTA (15.000.000) - procedimiento de ejemplo
-- =====================================================
-- Se recomienda generar con LOAD DATA INFILE o Python.
-- Procedimiento de referencia (lento para 15M):

/*
DELIMITER //
CREATE PROCEDURE IF NOT EXISTS sp_cargar_detalles()
BEGIN
    DECLARE v_id BIGINT;
    DECLARE done INT DEFAULT 0;
    DECLARE cur CURSOR FOR SELECT id_venta FROM venta ORDER BY id_venta;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_id;
        IF done THEN LEAVE read_loop; END IF;

        INSERT INTO detalle_venta (id_venta, id_producto, cantidad, precio_unitario, descuento_item, subtotal_item)
        VALUES (
            v_id,
            1 + (v_id % 500000),
            1 + (v_id % 5),
            ROUND(100 + RAND()*15000, 2),
            ROUND(RAND()*500, 2),
            ROUND(100 + RAND()*20000, 2)
        );

        IF v_id % 10 < 8 THEN
            INSERT INTO detalle_venta (id_venta, id_producto, cantidad, precio_unitario, descuento_item, subtotal_item)
            VALUES (
                v_id,
                1 + ((v_id + 91) % 500000),
                1 + (v_id % 3),
                ROUND(80 + RAND()*12000, 2),
                ROUND(RAND()*300, 2),
                ROUND(80 + RAND()*15000, 2)
            );
        END IF;

        IF v_id % 10 < 4 THEN
            INSERT INTO detalle_venta (id_venta, id_producto, cantidad, precio_unitario, descuento_item, subtotal_item)
            VALUES (
                v_id,
                1 + ((v_id + 53) % 500000),
                1 + (v_id % 2),
                ROUND(50 + RAND()*8000, 2),
                0,
                ROUND(50 + RAND()*10000, 2)
            );
        END IF;

        IF v_id % 10000 = 0 THEN
            COMMIT;
            SELECT CONCAT('Detalles hasta venta ', v_id) AS progreso;
        END IF;
    END LOOP;
    CLOSE cur;
    COMMIT;
END //
DELIMITER ;
*/


-- =====================================================
-- 9. PAGOS (ejemplo sobre las ventas existentes)
-- =====================================================
INSERT INTO pagos (id_venta, metodo_pago, monto, estado, referencia_bancaria, fecha_pago)
SELECT
    v.id_venta,
    ELT(1 + (v.id_venta % 7), 'tarjeta_credito','tarjeta_credito','tarjeta_debito','paypal','transferencia','efectivo','cripto'),
    v.total,
    ELT(1 + (v.id_venta % 7), 'aprobado','aprobado','aprobado','aprobado','pendiente','rechazado','reembolsado'),
    CONCAT('REF-', v.id_venta),
    v.fecha_venta
FROM venta v
WHERE v.id_venta % 10 < 9;

COMMIT;


-- =====================================================
-- 10. MOVIMIENTOS DE INVENTARIO (2.000.000)
-- =====================================================
TRUNCATE tmp_numbers;
INSERT INTO tmp_numbers (n)
WITH RECURSIVE seq AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 2000000
)
SELECT n FROM seq;

INSERT INTO movimientos_inventario (id_producto, tipo_movimiento, cantidad, cantidad_anterior, cantidad_nueva, id_almacen, motivo, fecha_movimiento)
SELECT
    1 + (n % 500000),
    ELT(1 + (n % 7), 'entrada','salida','salida','salida','devolucion','ajuste','merma'),
    1 + (n % 50),
    100 + (n % 400),
    50 + (n % 450),
    'CENTRAL',
    CONCAT('Movimiento automático de prueba ', n),
    DATE_ADD('2021-01-01', INTERVAL (n % 1800) DAY)
FROM tmp_numbers;

COMMIT;


-- =====================================================
-- 11. RESEÑAS (~1.000.000)
-- =====================================================
TRUNCATE tmp_numbers;
INSERT INTO tmp_numbers (n)
WITH RECURSIVE seq AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 1000000
)
SELECT n FROM seq;

INSERT IGNORE INTO reseñas_productos (id_usuario, id_producto, calificacion, titulo, comentario, fecha_reseña, votos_utiles)
SELECT
    1 + (n % 30000),
    1 + (n % 500000),
    1 + (n % 5),
    CONCAT('Reseña ', n),
    CONCAT('Comentario de evaluación del producto. Experiencia de compra número ', n),
    DATE_ADD('2021-06-01', INTERVAL (n % 1200) DAY),
    n % 50
FROM tmp_numbers;

COMMIT;


-- =====================================================
-- 12. DEVOLUCIONES (~300.000) - ejemplo
-- =====================================================
INSERT INTO devoluciones (id_detalle_venta, id_venta, motivo, descripcion, estado, monto_reembolso, fecha_solicitud)
SELECT
    d.id_detalle,
    d.id_venta,
    ELT(1 + (d.id_detalle % 5), 'producto_defectuoso','no_conforme','equivocado','talla_incorrecta','otro'),
    'Devolución generada para pruebas de rendimiento',
    ELT(1 + (d.id_detalle % 6), 'solicitada','aprobada','en_transito','recibida','rechazada','reembolsada'),
    d.subtotal_item * 0.9,
    DATE_ADD('2022-01-01', INTERVAL (d.id_detalle % 900) DAY)
FROM detalle_venta d
WHERE d.id_detalle % 50 = 0
LIMIT 300000;

COMMIT;


-- =====================================================
-- RESTAURAR CONFIGURACIONES
-- =====================================================
SET SESSION unique_checks = 1;
SET SESSION foreign_key_checks = 1;
SET SESSION autocommit = 1;

ANALYZE TABLE usuarios, marcas, categorias, productos, producto_categoria,
              direcciones_envio, venta, detalle_venta, pagos,
              movimientos_inventario, reseñas_productos, devoluciones;


-- =====================================================
-- VERIFICACIÓN DE VOLÚMENES
-- =====================================================
SELECT 'usuarios' AS tabla, COUNT(*) AS registros FROM usuarios
UNION ALL SELECT 'marcas', COUNT(*) FROM marcas
UNION ALL SELECT 'categorias', COUNT(*) FROM categorias
UNION ALL SELECT 'productos', COUNT(*) FROM productos
UNION ALL SELECT 'producto_categoria', COUNT(*) FROM producto_categoria
UNION ALL SELECT 'direcciones_envio', COUNT(*) FROM direcciones_envio
UNION ALL SELECT 'venta', COUNT(*) FROM venta
UNION ALL SELECT 'detalle_venta', COUNT(*) FROM detalle_venta
UNION ALL SELECT 'pagos', COUNT(*) FROM pagos
UNION ALL SELECT 'movimientos_inventario', COUNT(*) FROM movimientos_inventario
UNION ALL SELECT 'reseñas_productos', COUNT(*) FROM reseñas_productos
UNION ALL SELECT 'devoluciones', COUNT(*) FROM devoluciones
ORDER BY 1;
