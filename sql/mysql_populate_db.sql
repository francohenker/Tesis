-- =====================================================
-- POBLACIÓN DE DATOS - MySQL 9.7.2 LTS (InnoDB)
-- Tesis: Análisis Comparativo PostgreSQL vs MySQL
-- =====================================================
-- Volúmenes (Tabla 3.2):
--   usuarios .............. 30.000
--   marcas ................ 800
--   categorias ............ 300
--   productos ............. 500.000
--   producto_categoria .... 1.000.000   (2 categorías por producto)
--   direcciones_envio ..... 36.000
--   venta ................. 5.000.000
--   detalle_venta ......... 15.000.000  (3 ítems por venta)
--   pagos ................. 4.500.000   (90 % de las ventas)
--   movimientos_inventario  2.000.000
--   resenas_productos ..... 1.000.000
--   devoluciones .......... 220.000
--
-- DATOS IDÉNTICOS EN AMBOS MOTORES (sección 3.2.2)
--   Traducción exacta de postgres_populate_db.sql: no se usa RAND(); cada
--   valor es una función determinista del número de fila (aritmética entera
--   y la función hk(x, s), definida igual en ambos motores) y las claves
--   primarias se asignan de forma explícita. La sección 15 calcula una huella
--   por tabla que debe coincidir con la de PostgreSQL.
--
-- EJECUCIÓN (como root, con el cliente mysql porque usa DELIMITER, sobre la
-- base creada con mysql_create_db.sql):
--   mysql tesis < sql/mysql_populate_db.sql
-- Los volúmenes pueden reducirse para pruebas, p. ej.
--   mysql --init-command="SET @ventas=50000" tesis < sql/mysql_populate_db.sql
-- pero solo los valores por defecto corresponden a la tesis y a la huella
-- esperada. Restricciones: productos par, ventas múltiplo de 10 y
-- resenas <= mcm(usuarios, productos).
--
-- Las tablas no tienen claves foráneas durante la carga: se agregan en la
-- sección 0 de mysql_indexes_oe5.sql (ver mysql_create_db.sql). La
-- integridad referencial se verifica en la sección 15.
-- =====================================================

SET @usuarios     = COALESCE(@usuarios, 30000);
SET @marcas       = COALESCE(@marcas, 800);
SET @productos    = COALESCE(@productos, 500000);
SET @ventas       = COALESCE(@ventas, 5000000);
SET @movimientos  = COALESCE(@movimientos, 2000000);
SET @resenas      = COALESCE(@resenas, 1000000);
SET @devoluciones = COALESCE(@devoluciones, 220000);

SET NAMES utf8mb4;                     -- el archivo está en UTF-8 (literales con acentos)
SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION';
-- La carga no se escribe en el registro binario: así no deja archivos de
-- binlog de varios GB dentro del directorio de datos (y de las imágenes).
SET SESSION sql_log_bin = 0;


-- =====================================================
-- 0. FUNCIÓN DE DISPERSIÓN Y TABLAS DE NÚMEROS
-- =====================================================
-- hk(x, s): entero en [0, 2^32) derivado de la fila x y de la columna s.
-- Mismo mezclador de 32 bits que en PostgreSQL.

DROP FUNCTION IF EXISTS hk;
DROP PROCEDURE IF EXISTS aux_verificar_hk;

DELIMITER //

CREATE FUNCTION hk(x BIGINT, s INT) RETURNS BIGINT
DETERMINISTIC NO SQL
BEGIN
    DECLARE h BIGINT DEFAULT (x * 64 + s) % 4294967296;
    SET h = ((h ^ (h >> 16)) * 73244475) % 4294967296;
    SET h = ((h ^ (h >> 16)) * 73244475) % 4294967296;
    RETURN h ^ (h >> 16);
END //

-- Valores de control: deben coincidir con los de PostgreSQL.
CREATE PROCEDURE aux_verificar_hk()
BEGIN
    IF hk(1, 0) <> 2462609589 OR hk(123456, 7) <> 1691283220 OR hk(15000000, 63) <> 2885124033 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'hk() no reproduce los valores de referencia';
    END IF;
END //

DELIMITER ;

CALL aux_verificar_hk();
DROP PROCEDURE aux_verificar_hk;

-- aux_mil: 0..999. aux_numeros: 1..N, con N el mayor volumen generado fila
-- a fila (equivale a generate_series de PostgreSQL).
DROP TABLE IF EXISTS aux_mil;
DROP TABLE IF EXISTS aux_numeros;
CREATE TABLE aux_mil (n INT NOT NULL PRIMARY KEY) ENGINE=InnoDB;
CREATE TABLE aux_numeros (n BIGINT NOT NULL PRIMARY KEY) ENGINE=InnoDB;

INSERT INTO aux_mil (n)
WITH RECURSIVE s (n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM s WHERE n < 999)
SELECT n FROM s;

SET @max_n = GREATEST(@usuarios, @marcas, 300, @productos, @ventas, @movimientos, @resenas);

INSERT INTO aux_numeros (n)
SELECT a.n * 1000000 + b.n * 1000 + c.n + 1
FROM aux_mil a CROSS JOIN aux_mil b CROSS JOIN aux_mil c
WHERE a.n <= (@max_n - 1) DIV 1000000
  AND a.n * 1000000 + b.n * 1000 + c.n < @max_n
ORDER BY 1;


-- =====================================================
-- 1. MARCAS (800)
-- =====================================================
INSERT INTO marcas (id_marca, nombre, pais_origen, descripcion, fecha_creacion)
SELECT
    n,
    CONCAT('Marca_', n),
    ELT(1 + n % 10, 'Argentina','Brasil','Chile','Estados Unidos','China','Alemania','Japón','Corea del Sur','Italia','España'),
    CONCAT('Descripción de la marca número ', n),
    TIMESTAMP '2018-01-01 00:00:00' + INTERVAL (n % 365) DAY
FROM aux_numeros
WHERE n <= @marcas
ORDER BY n;


-- =====================================================
-- 2. CATEGORÍAS (300) - jerarquía de 2 niveles
-- =====================================================
INSERT INTO categorias (id_categoria, nombre, id_categoria_padre, descripcion, nivel)
SELECT n, CONCAT('Cat_Padre_', n), NULL, CONCAT('Categoría principal ', n), 1
FROM aux_numeros
WHERE n <= 50
ORDER BY n;

INSERT INTO categorias (id_categoria, nombre, id_categoria_padre, descripcion, nivel)
SELECT 50 + n, CONCAT('Cat_Hijo_', n), 1 + (n - 1) % 50, CONCAT('Subcategoría ', n), 2
FROM aux_numeros
WHERE n <= 250
ORDER BY n;


-- =====================================================
-- 3. USUARIOS (30.000)
-- =====================================================
INSERT INTO usuarios (id_usuario, nombre, apellido, email, telefono, fecha_registro, fecha_ultima_actividad, estado)
SELECT
    n,
    CONCAT('Nombre_', n),
    CONCAT('Apellido_', n),
    CONCAT('usuario', n, '@email.com'),
    CONCAT('11', LPAD(n % 100000000, 8, '0')),
    TIMESTAMP '2020-01-01 00:00:00' + INTERVAL (n % 2000) DAY + INTERVAL (n % 86400) SECOND,
    TIMESTAMP '2023-01-01 00:00:00' + INTERVAL (n % 1000) DAY,
    ELT(1 + n % 6, 'activo','activo','activo','activo','inactivo','suspendido')
FROM aux_numeros
WHERE n <= @usuarios
ORDER BY n;


-- =====================================================
-- 4. PRODUCTOS (500.000)
-- =====================================================
-- 625 productos por marca. Precio en [100,00; 50.100,00] (≈ 475.000
-- valores distintos), stock en [0; 500], estado independiente de la marca.
INSERT INTO productos (id_producto, sku, nombre, descripcion, id_marca, precio_base, stock_actual, peso_kg, fecha_alta, estado)
SELECT
    n,
    CONCAT('SKU-', LPAD(n, 8, '0')),
    CONCAT('Producto ', n),
    CONCAT('Descripción detallada del producto número ', n, '. Ideal para pruebas de rendimiento.'),
    1 + n % @marcas,
    (10000 + hk(n, 1) % 5000001) / 100,
    hk(n, 2) % 501,
    (10 + hk(n, 3) % 2001) / 100,
    TIMESTAMP '2019-01-01 00:00:00' + INTERVAL (n % 2500) DAY,
    ELT(1 + hk(n, 4) % 6, 'disponible','disponible','disponible','disponible','agotado','descontinuado')
FROM aux_numeros
WHERE n <= @productos
ORDER BY n;


-- =====================================================
-- 5. PRODUCTO_CATEGORIA (1.000.000)
-- =====================================================
INSERT INTO producto_categoria (id_producto, id_categoria, es_principal)
SELECT p.n, 1 + (p.n + k.n) % 300, (k.n = 0)
FROM aux_numeros p
CROSS JOIN aux_mil k
WHERE p.n <= @productos AND k.n <= 1
ORDER BY 1, 2;


-- =====================================================
-- 6. DIRECCIONES DE ENVÍO (36.000)
-- =====================================================
-- Principal: id_direccion = id_usuario. Secundaria (1 de cada 5 usuarios):
-- id_direccion = usuarios + id_usuario / 5.
INSERT INTO direcciones_envio (id_direccion, id_usuario, alias, calle, numero_exterior, colonia, ciudad, estado_provincia, codigo_postal, pais, es_principal, fecha_creacion)
SELECT
    n,
    n,
    ELT(1 + n % 3, 'Casa','Trabajo','Otro'),
    CONCAT('Calle ', n % 5000),
    CAST((n % 9000) + 1 AS CHAR),
    CONCAT('Barrio ', n % 200),
    ELT(1 + n % 8, 'Buenos Aires','Córdoba','Rosario','Mendoza','La Plata','Mar del Plata','Salta','Tucumán'),
    ELT(1 + n % 8, 'Buenos Aires','Córdoba','Santa Fe','Mendoza','Buenos Aires','Buenos Aires','Salta','Tucumán'),
    LPAD((n % 9000) + 1000, 4, '0'),
    'Argentina',
    TRUE,
    TIMESTAMP '2020-01-01 00:00:00' + INTERVAL (n % 2000) DAY + INTERVAL (n % 86400) SECOND
FROM aux_numeros
WHERE n <= @usuarios
ORDER BY n;

INSERT INTO direcciones_envio (id_direccion, id_usuario, alias, calle, numero_exterior, colonia, ciudad, estado_provincia, codigo_postal, pais, es_principal, fecha_creacion)
SELECT
    @usuarios + n DIV 5,
    n,
    'Secundaria',
    CONCAT('Av. Alternativa ', n % 3000),
    CAST((n % 5000) + 1 AS CHAR),
    CONCAT('Barrio Alt ', n % 150),
    ELT(1 + n % 4, 'Buenos Aires','Córdoba','Rosario','Mendoza'),
    ELT(1 + n % 4, 'Buenos Aires','Córdoba','Santa Fe','Mendoza'),
    LPAD((n % 8000) + 2000, 4, '0'),
    'Argentina',
    FALSE,
    TIMESTAMP '2020-01-31 00:00:00' + INTERVAL (n % 2000) DAY + INTERVAL (n % 86400) SECOND
FROM aux_numeros
WHERE n <= @usuarios AND n % 5 = 0
ORDER BY n;


-- =====================================================
-- 7. TABLA AUXILIAR DE ÍTEMS (se elimina en la sección 14)
-- =====================================================
-- Una fila por venta con sus 3 ítems, para que la cabecera (subtotal,
-- descuento, impuestos, total) sea la suma exacta de sus ítems.
-- Importes en centavos. Ítem k de la venta v: id_detalle = (k-1)*ventas + v.
--   b, o2, o3  producto 1 = 1+b; 2 = 1+(b+o2) % productos; 3 = 1+(b+o3) % productos
--              (o2 en [1, P/2-1] y o3 en [P/2, P-2]: tres productos distintos)
--   c1..c3     cantidad [1; 5]
--   u1..u3     precio unitario [50,00; 15.050,00]
--   t1..t3     porcentaje de descuento: 0 (11 de 31 casos) o [1; 20]
--   ds1..ds3   descuento del ítem = cantidad * precio * t / 100 (truncado)
DROP TABLE IF EXISTS aux_items;
CREATE TABLE aux_items (
    v   BIGINT NOT NULL PRIMARY KEY,
    b   BIGINT NOT NULL, o2 BIGINT NOT NULL, o3 BIGINT NOT NULL,
    c1  BIGINT NOT NULL, c2 BIGINT NOT NULL, c3 BIGINT NOT NULL,
    u1  BIGINT NOT NULL, u2 BIGINT NOT NULL, u3 BIGINT NOT NULL,
    t1  BIGINT NOT NULL, t2 BIGINT NOT NULL, t3 BIGINT NOT NULL,
    ds1 BIGINT AS ((c1 * u1 * t1) DIV 100) STORED,
    ds2 BIGINT AS ((c2 * u2 * t2) DIV 100) STORED,
    ds3 BIGINT AS ((c3 * u3 * t3) DIV 100) STORED
) ENGINE=InnoDB;

INSERT INTO aux_items (v, b, o2, o3, c1, c2, c3, u1, u2, u3, t1, t2, t3)
SELECT
    n,
    hk(n, 30) % @productos,
    1 + hk(n, 31) % (@productos DIV 2 - 1),
    @productos DIV 2 + hk(n, 32) % (@productos DIV 2 - 1),
    1 + hk(n, 33) % 5,
    1 + hk(@ventas + n, 33) % 5,
    1 + hk(2 * @ventas + n, 33) % 5,
    5000 + hk(n, 34) % 1500001,
    5000 + hk(@ventas + n, 34) % 1500001,
    5000 + hk(2 * @ventas + n, 34) % 1500001,
    GREATEST(hk(n, 35) % 31 - 10, 0),
    GREATEST(hk(@ventas + n, 35) % 31 - 10, 0),
    GREATEST(hk(2 * @ventas + n, 35) % 31 - 10, 0)
FROM aux_numeros
WHERE n <= @ventas
ORDER BY n;


-- =====================================================
-- 8. VENTAS (5.000.000)
-- =====================================================
-- fecha_venta: 1.500 días desde 2021-01-01 (≈ 432.000 valores distintos).
-- Usuario, estado y canal son independientes entre sí y de la fecha.
-- subtotal = Σ cantidad*precio; descuento = Σ descuentos de ítem;
-- impuestos = 21 % de (subtotal - descuento), redondeado al centavo.
INSERT INTO venta (id_venta, id_usuario, id_direccion, fecha_venta, subtotal, impuestos, descuento, total, estado, canal_venta)
SELECT
    v,
    1 + hk(v, 10) % @usuarios,
    NULL,
    TIMESTAMP '2021-01-01 00:00:00' + INTERVAL (v % 1500) DAY + INTERVAL (v % 86400) SECOND,
    bruto / 100,
    imp / 100,
    descu / 100,
    (bruto - descu + imp) / 100,
    ELT(1 + hk(v, 11) % 8, 'pendiente','pagada','pagada','pagada','enviada','entregada','cancelada','devuelta'),
    ELT(1 + hk(v, 12) % 7, 'web','web','web','app','app','tienda_fisica','telefono')
FROM (
    SELECT v,
           c1 * u1 + c2 * u2 + c3 * u3 AS bruto,
           ds1 + ds2 + ds3 AS descu,
           ((c1 * u1 + c2 * u2 + c3 * u3 - ds1 - ds2 - ds3) * 21 + 50) DIV 100 AS imp
    FROM aux_items
) AS t
ORDER BY v;


-- =====================================================
-- 9. DETALLE_VENTA (15.000.000) - 3 ítems por venta
-- =====================================================
INSERT INTO detalle_venta (id_detalle, id_venta, id_producto, cantidad, precio_unitario, descuento_item, subtotal_item)
SELECT v, v, 1 + b, c1, u1 / 100, ds1 / 100, (c1 * u1 - ds1) / 100
FROM aux_items
ORDER BY v;

INSERT INTO detalle_venta (id_detalle, id_venta, id_producto, cantidad, precio_unitario, descuento_item, subtotal_item)
SELECT @ventas + v, v, 1 + (b + o2) % @productos, c2, u2 / 100, ds2 / 100, (c2 * u2 - ds2) / 100
FROM aux_items
ORDER BY v;

INSERT INTO detalle_venta (id_detalle, id_venta, id_producto, cantidad, precio_unitario, descuento_item, subtotal_item)
SELECT 2 * @ventas + v, v, 1 + (b + o3) % @productos, c3, u3 / 100, ds3 / 100, (c3 * u3 - ds3) / 100
FROM aux_items
ORDER BY v;


-- =====================================================
-- 10. PAGOS (4.500.000)
-- =====================================================
-- Se excluye exactamente el 10 % de las ventas, elegido con una permutación
-- de 1..ventas (multiplicador coprimo con ventas), sin relación con la fecha.
INSERT INTO pagos (id_venta, metodo_pago, monto, estado, referencia_bancaria, fecha_pago, fecha_aprobacion)
SELECT
    id_venta,
    ELT(im, 'tarjeta_credito','tarjeta_credito','tarjeta_debito','paypal','transferencia','efectivo','cripto'),
    total,
    ELT(ie, 'aprobado','aprobado','aprobado','aprobado','pendiente','rechazado','reembolsado'),
    CONCAT('REF-', id_venta),
    fecha_venta + INTERVAL sp SECOND,
    CASE WHEN ie IN (1, 2, 3, 4, 7) THEN fecha_venta + INTERVAL (sp + sa) SECOND END
FROM (
    SELECT id_venta, total, fecha_venta,
           1 + hk(id_venta, 41) % 7 AS im,
           1 + hk(id_venta, 42) % 7 AS ie,
           hk(id_venta, 43) % 7200 AS sp,
           hk(id_venta, 44) % 3600 AS sa
    FROM venta
    WHERE ((id_venta - 1) * 2654435761) % @ventas >= @ventas DIV 10
) AS p
ORDER BY id_venta;


-- =====================================================
-- 11. MOVIMIENTOS DE INVENTARIO (2.000.000)
-- =====================================================
INSERT INTO movimientos_inventario (id_movimiento, id_producto, tipo_movimiento, cantidad, cantidad_anterior, cantidad_nueva, id_almacen, motivo, fecha_movimiento)
SELECT
    n,
    1 + n % @productos,
    ELT(1 + n % 7, 'entrada','salida','salida','salida','devolucion','ajuste','merma'),
    1 + n % 50,
    100 + n % 400,
    50 + n % 450,
    'CENTRAL',
    CONCAT('Movimiento automático de prueba ', n),
    TIMESTAMP '2021-01-01 00:00:00' + INTERVAL (n % 1800) DAY
FROM aux_numeros
WHERE n <= @movimientos
ORDER BY n;


-- =====================================================
-- 12. RESEÑAS (1.000.000)
-- =====================================================
-- (usuario, producto) = (1 + n % usuarios, 1 + n % productos) no se repite
-- mientras resenas <= mcm(usuarios, productos) = 1.500.000.
INSERT INTO resenas_productos (id_resena, id_usuario, id_producto, calificacion, titulo, comentario, fecha_resena, votos_utiles)
SELECT
    n,
    1 + n % @usuarios,
    1 + n % @productos,
    1 + hk(n, 50) % 5,
    CONCAT('Reseña ', n),
    CONCAT('Comentario de evaluación del producto. Experiencia de compra número ', n),
    TIMESTAMP '2021-06-01 00:00:00' + INTERVAL (n % 1200) DAY,
    n % 50
FROM aux_numeros
WHERE n <= @resenas
ORDER BY n;


-- =====================================================
-- 13. DEVOLUCIONES (220.000)
-- =====================================================
-- Exactamente @devoluciones ítems, elegidos con una permutación de
-- 1..detalles (multiplicador coprimo con 3*ventas).
INSERT INTO devoluciones (id_detalle_venta, id_venta, motivo, descripcion, estado, monto_reembolso, fecha_solicitud)
SELECT
    d.id_detalle,
    d.id_venta,
    ELT(1 + hk(d.id_detalle, 60) % 5, 'producto_defectuoso','no_conforme','equivocado','talla_incorrecta','otro'),
    'Devolución generada para pruebas de rendimiento',
    ELT(1 + hk(d.id_detalle, 61) % 6, 'solicitada','aprobada','en_transito','recibida','rechazada','reembolsada'),
    ROUND(d.subtotal_item * 0.9, 2),
    v.fecha_venta + INTERVAL (1 + hk(d.id_detalle, 62) % 30) DAY
FROM detalle_venta d
JOIN venta v ON v.id_venta = d.id_venta
WHERE ((d.id_detalle - 1) * 2654435761) % (3 * @ventas) < @devoluciones
ORDER BY d.id_detalle;


-- =====================================================
-- 14. CIERRE: AUTO_INCREMENT, LIMPIEZA Y ESTADÍSTICAS
-- =====================================================
-- Un valor menor que el máximo hace que InnoDB fije el contador en
-- máximo + 1, igual que setval en PostgreSQL (INSERT ... SELECT puede dejar
-- reservados valores de más). Las inserciones de W3 y W4 usan el contador.
ALTER TABLE usuarios AUTO_INCREMENT = 1;
ALTER TABLE marcas AUTO_INCREMENT = 1;
ALTER TABLE categorias AUTO_INCREMENT = 1;
ALTER TABLE productos AUTO_INCREMENT = 1;
ALTER TABLE direcciones_envio AUTO_INCREMENT = 1;
ALTER TABLE venta AUTO_INCREMENT = 1;
ALTER TABLE detalle_venta AUTO_INCREMENT = 1;
ALTER TABLE pagos AUTO_INCREMENT = 1;
ALTER TABLE movimientos_inventario AUTO_INCREMENT = 1;
ALTER TABLE resenas_productos AUTO_INCREMENT = 1;
ALTER TABLE devoluciones AUTO_INCREMENT = 1;

DROP TABLE aux_items;
DROP TABLE aux_numeros;
DROP TABLE aux_mil;
DROP FUNCTION hk;

ANALYZE TABLE usuarios, marcas, categorias, productos, producto_categoria,
              direcciones_envio, venta, detalle_venta, pagos,
              movimientos_inventario, resenas_productos, devoluciones;


-- =====================================================
-- 15. VERIFICACIÓN DE LA CARGA (sección 3.2.2)
-- =====================================================
-- a) Volúmenes: «registros» debe coincidir con «esperado» (Tabla 3.2).
SELECT t.tabla, t.registros, e.esperado,
       CASE WHEN t.registros = e.esperado THEN 'OK' ELSE 'ERROR' END AS resultado
FROM (
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
    UNION ALL SELECT 'resenas_productos', COUNT(*) FROM resenas_productos
    UNION ALL SELECT 'devoluciones', COUNT(*) FROM devoluciones
) AS t
JOIN (
    SELECT 'usuarios' AS tabla, @usuarios AS esperado
    UNION ALL SELECT 'marcas', @marcas
    UNION ALL SELECT 'categorias', 300
    UNION ALL SELECT 'productos', @productos
    UNION ALL SELECT 'producto_categoria', 2 * @productos
    UNION ALL SELECT 'direcciones_envio', @usuarios + @usuarios DIV 5
    UNION ALL SELECT 'venta', @ventas
    UNION ALL SELECT 'detalle_venta', 3 * @ventas
    UNION ALL SELECT 'pagos', @ventas - @ventas DIV 10
    UNION ALL SELECT 'movimientos_inventario', @movimientos
    UNION ALL SELECT 'resenas_productos', @resenas
    UNION ALL SELECT 'devoluciones', @devoluciones
) AS e ON e.tabla = t.tabla
ORDER BY t.tabla;

-- b) Integridad referencial: las 17 claves foráneas, 0 violaciones en cada una.
SELECT fk, violaciones, CASE WHEN violaciones = 0 THEN 'OK' ELSE 'ERROR' END AS resultado
FROM (
    SELECT 'categorias.id_categoria_padre' AS fk, COUNT(*) AS violaciones FROM categorias c
        WHERE c.id_categoria_padre IS NOT NULL AND NOT EXISTS (SELECT 1 FROM categorias p WHERE p.id_categoria = c.id_categoria_padre)
    UNION ALL SELECT 'productos.id_marca', COUNT(*) FROM productos c
        WHERE c.id_marca IS NOT NULL AND NOT EXISTS (SELECT 1 FROM marcas p WHERE p.id_marca = c.id_marca)
    UNION ALL SELECT 'producto_categoria.id_producto', COUNT(*) FROM producto_categoria c
        WHERE NOT EXISTS (SELECT 1 FROM productos p WHERE p.id_producto = c.id_producto)
    UNION ALL SELECT 'producto_categoria.id_categoria', COUNT(*) FROM producto_categoria c
        WHERE NOT EXISTS (SELECT 1 FROM categorias p WHERE p.id_categoria = c.id_categoria)
    UNION ALL SELECT 'direcciones_envio.id_usuario', COUNT(*) FROM direcciones_envio c
        WHERE NOT EXISTS (SELECT 1 FROM usuarios p WHERE p.id_usuario = c.id_usuario)
    UNION ALL SELECT 'venta.id_usuario', COUNT(*) FROM venta c
        WHERE NOT EXISTS (SELECT 1 FROM usuarios p WHERE p.id_usuario = c.id_usuario)
    UNION ALL SELECT 'venta.id_direccion', COUNT(*) FROM venta c
        WHERE c.id_direccion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM direcciones_envio p WHERE p.id_direccion = c.id_direccion)
    UNION ALL SELECT 'detalle_venta.id_venta', COUNT(*) FROM detalle_venta c
        WHERE NOT EXISTS (SELECT 1 FROM venta p WHERE p.id_venta = c.id_venta)
    UNION ALL SELECT 'detalle_venta.id_producto', COUNT(*) FROM detalle_venta c
        WHERE NOT EXISTS (SELECT 1 FROM productos p WHERE p.id_producto = c.id_producto)
    UNION ALL SELECT 'pagos.id_venta', COUNT(*) FROM pagos c
        WHERE NOT EXISTS (SELECT 1 FROM venta p WHERE p.id_venta = c.id_venta)
    UNION ALL SELECT 'movimientos_inventario.id_producto', COUNT(*) FROM movimientos_inventario c
        WHERE NOT EXISTS (SELECT 1 FROM productos p WHERE p.id_producto = c.id_producto)
    UNION ALL SELECT 'movimientos_inventario.id_usuario_responsable', COUNT(*) FROM movimientos_inventario c
        WHERE c.id_usuario_responsable IS NOT NULL AND NOT EXISTS (SELECT 1 FROM usuarios p WHERE p.id_usuario = c.id_usuario_responsable)
    UNION ALL SELECT 'resenas_productos.id_usuario', COUNT(*) FROM resenas_productos c
        WHERE NOT EXISTS (SELECT 1 FROM usuarios p WHERE p.id_usuario = c.id_usuario)
    UNION ALL SELECT 'resenas_productos.id_producto', COUNT(*) FROM resenas_productos c
        WHERE NOT EXISTS (SELECT 1 FROM productos p WHERE p.id_producto = c.id_producto)
    UNION ALL SELECT 'resenas_productos.id_venta', COUNT(*) FROM resenas_productos c
        WHERE c.id_venta IS NOT NULL AND NOT EXISTS (SELECT 1 FROM venta p WHERE p.id_venta = c.id_venta)
    UNION ALL SELECT 'devoluciones.id_detalle_venta', COUNT(*) FROM devoluciones c
        WHERE NOT EXISTS (SELECT 1 FROM detalle_venta p WHERE p.id_detalle = c.id_detalle_venta)
    UNION ALL SELECT 'devoluciones.id_venta', COUNT(*) FROM devoluciones c
        WHERE NOT EXISTS (SELECT 1 FROM venta p WHERE p.id_venta = c.id_venta)
) AS f
ORDER BY fk;

-- c) Huella del contenido: un número por tabla, calculado con la misma
--    fórmula en ambos motores. Con los volúmenes de la tesis debe coincidir
--    con «esperado», que es la huella obtenida en PostgreSQL.
--    Cada fila aporta (id % 9973 + 1) * (suma de sus columnas: importes en
--    centavos, fechas en segundos desde 2000-01-01 y textos como
--    longitud*1000 + código del primer carácter).
SELECT h.tabla, h.huella, e.esperado,
       CASE WHEN h.huella = e.esperado THEN 'OK' ELSE 'DISTINTA' END AS resultado
FROM (
    SELECT 'usuarios' AS tabla, SUM((id_usuario % 9973 + 1) * (
        COALESCE(TIMESTAMPDIFF(SECOND, '2000-01-01 00:00:00', fecha_registro), 0)
      + COALESCE(TIMESTAMPDIFF(SECOND, '2000-01-01 00:00:00', fecha_ultima_actividad), 0)
      + COALESCE(CHAR_LENGTH(nombre) * 1000 + ASCII(nombre), 0) + COALESCE(CHAR_LENGTH(apellido) * 1000 + ASCII(apellido), 0)
      + COALESCE(CHAR_LENGTH(email) * 1000 + ASCII(email), 0) + COALESCE(CHAR_LENGTH(telefono) * 1000 + ASCII(telefono), 0)
      + COALESCE(CHAR_LENGTH(estado) * 1000 + ASCII(estado), 0))) AS huella FROM usuarios
    UNION ALL SELECT 'marcas', SUM((id_marca % 9973 + 1) * (
        COALESCE(CHAR_LENGTH(nombre) * 1000 + ASCII(nombre), 0) + COALESCE(CHAR_LENGTH(pais_origen) * 1000 + ASCII(pais_origen), 0)
      + COALESCE(CHAR_LENGTH(descripcion) * 1000 + ASCII(descripcion), 0)
      + COALESCE(TIMESTAMPDIFF(SECOND, '2000-01-01 00:00:00', fecha_creacion), 0))) FROM marcas
    UNION ALL SELECT 'categorias', SUM((id_categoria % 9973 + 1) * (
        COALESCE(CHAR_LENGTH(nombre) * 1000 + ASCII(nombre), 0) + COALESCE(id_categoria_padre, 0)
      + COALESCE(CHAR_LENGTH(descripcion) * 1000 + ASCII(descripcion), 0) + COALESCE(nivel, 0))) FROM categorias
    UNION ALL SELECT 'productos', SUM((id_producto % 9973 + 1) * (
        COALESCE(CHAR_LENGTH(sku) * 1000 + ASCII(sku), 0) + COALESCE(CHAR_LENGTH(nombre) * 1000 + ASCII(nombre), 0)
      + COALESCE(CHAR_LENGTH(descripcion) * 1000 + ASCII(descripcion), 0) + COALESCE(id_marca, 0)
      + COALESCE(CAST(precio_base * 100 AS SIGNED), 0) + stock_actual + COALESCE(CAST(peso_kg * 100 AS SIGNED), 0)
      + COALESCE(TIMESTAMPDIFF(SECOND, '2000-01-01 00:00:00', fecha_alta), 0)
      + COALESCE(TIMESTAMPDIFF(SECOND, '2000-01-01 00:00:00', fecha_baja), 0)
      + COALESCE(CHAR_LENGTH(estado) * 1000 + ASCII(estado), 0))) FROM productos
    UNION ALL SELECT 'producto_categoria', SUM((id_producto % 9973 + 1) * (
        id_categoria * 2 + COALESCE(es_principal, 0))) FROM producto_categoria
    UNION ALL SELECT 'direcciones_envio', SUM((id_direccion % 9973 + 1) * (
        id_usuario + COALESCE(CHAR_LENGTH(alias) * 1000 + ASCII(alias), 0) + COALESCE(CHAR_LENGTH(calle) * 1000 + ASCII(calle), 0)
      + COALESCE(CHAR_LENGTH(numero_exterior) * 1000 + ASCII(numero_exterior), 0)
      + COALESCE(CHAR_LENGTH(numero_interior) * 1000 + ASCII(numero_interior), 0)
      + COALESCE(CHAR_LENGTH(colonia) * 1000 + ASCII(colonia), 0) + COALESCE(CHAR_LENGTH(ciudad) * 1000 + ASCII(ciudad), 0)
      + COALESCE(CHAR_LENGTH(estado_provincia) * 1000 + ASCII(estado_provincia), 0)
      + COALESCE(CHAR_LENGTH(codigo_postal) * 1000 + ASCII(codigo_postal), 0) + COALESCE(CHAR_LENGTH(pais) * 1000 + ASCII(pais), 0)
      + COALESCE(es_principal, 0) + COALESCE(TIMESTAMPDIFF(SECOND, '2000-01-01 00:00:00', fecha_creacion), 0))) FROM direcciones_envio
    UNION ALL SELECT 'venta', SUM((id_venta % 9973 + 1) * (
        id_usuario + COALESCE(id_direccion, 0) + TIMESTAMPDIFF(SECOND, '2000-01-01 00:00:00', fecha_venta)
      + CAST(subtotal * 100 AS SIGNED) + CAST(impuestos * 100 AS SIGNED) + CAST(descuento * 100 AS SIGNED) + CAST(total * 100 AS SIGNED)
      + COALESCE(CHAR_LENGTH(estado) * 1000 + ASCII(estado), 0) + COALESCE(CHAR_LENGTH(canal_venta) * 1000 + ASCII(canal_venta), 0)
      + COALESCE(CHAR_LENGTH(notas) * 1000 + ASCII(notas), 0))) FROM venta
    UNION ALL SELECT 'detalle_venta', SUM((id_detalle % 9973 + 1) * (
        id_venta + id_producto + cantidad + CAST(precio_unitario * 100 AS SIGNED)
      + COALESCE(CAST(descuento_item * 100 AS SIGNED), 0) + CAST(subtotal_item * 100 AS SIGNED))) FROM detalle_venta
    UNION ALL SELECT 'pagos', SUM((id_pago % 9973 + 1) * (
        id_venta + COALESCE(CHAR_LENGTH(metodo_pago) * 1000 + ASCII(metodo_pago), 0) + CAST(monto * 100 AS SIGNED)
      + COALESCE(CHAR_LENGTH(estado) * 1000 + ASCII(estado), 0)
      + COALESCE(CHAR_LENGTH(referencia_bancaria) * 1000 + ASCII(referencia_bancaria), 0)
      + COALESCE(TIMESTAMPDIFF(SECOND, '2000-01-01 00:00:00', fecha_pago), 0)
      + COALESCE(TIMESTAMPDIFF(SECOND, '2000-01-01 00:00:00', fecha_aprobacion), 0))) FROM pagos
    UNION ALL SELECT 'movimientos_inventario', SUM((id_movimiento % 9973 + 1) * (
        id_producto + COALESCE(CHAR_LENGTH(tipo_movimiento) * 1000 + ASCII(tipo_movimiento), 0) + cantidad
      + COALESCE(cantidad_anterior, 0) + COALESCE(cantidad_nueva, 0) + COALESCE(CHAR_LENGTH(id_almacen) * 1000 + ASCII(id_almacen), 0)
      + COALESCE(id_usuario_responsable, 0) + COALESCE(CHAR_LENGTH(motivo) * 1000 + ASCII(motivo), 0)
      + TIMESTAMPDIFF(SECOND, '2000-01-01 00:00:00', fecha_movimiento))) FROM movimientos_inventario
    UNION ALL SELECT 'resenas_productos', SUM((id_resena % 9973 + 1) * (
        id_usuario + id_producto + COALESCE(id_venta, 0) + calificacion
      + COALESCE(CHAR_LENGTH(titulo) * 1000 + ASCII(titulo), 0) + COALESCE(CHAR_LENGTH(comentario) * 1000 + ASCII(comentario), 0)
      + COALESCE(CHAR_LENGTH(imagen_url) * 1000 + ASCII(imagen_url), 0)
      + TIMESTAMPDIFF(SECOND, '2000-01-01 00:00:00', fecha_resena)
      + COALESCE(TIMESTAMPDIFF(SECOND, '2000-01-01 00:00:00', fecha_edicion), 0) + COALESCE(votos_utiles, 0))) FROM resenas_productos
    UNION ALL SELECT 'devoluciones', SUM((id_devolucion % 9973 + 1) * (
        id_detalle_venta + id_venta + COALESCE(CHAR_LENGTH(motivo) * 1000 + ASCII(motivo), 0)
      + COALESCE(CHAR_LENGTH(descripcion) * 1000 + ASCII(descripcion), 0) + COALESCE(CHAR_LENGTH(estado) * 1000 + ASCII(estado), 0)
      + CAST(monto_reembolso * 100 AS SIGNED)
      + COALESCE(TIMESTAMPDIFF(SECOND, '2000-01-01 00:00:00', fecha_solicitud), 0)
      + COALESCE(TIMESTAMPDIFF(SECOND, '2000-01-01 00:00:00', fecha_resolucion), 0))) FROM devoluciones
) AS h
LEFT JOIN (
    SELECT 'usuarios' AS tabla, CAST(222693132671311018 AS DECIMAL(40,0)) AS esperado
    UNION ALL SELECT 'marcas', 187546517283200
    UNION ALL SELECT 'categorias', 1267499125
    UNION ALL SELECT 'productos', 1765666347836257535
    UNION ALL SELECT 'producto_categoria', 1500073410875
    UNION ALL SELECT 'direcciones_envio', 121152879567515831
    UNION ALL SELECT 'venta', 18539439471879191847
    UNION ALL SELECT 'detalle_venta', 431542742352416553
    UNION ALL SELECT 'pagos', 28216751434322407651
    UNION ALL SELECT 'movimientos_inventario', 7379599233490238972
    UNION ALL SELECT 'resenas_productos', 3623203920947812480
    UNION ALL SELECT 'devoluciones', 810905063011644821
) AS e ON e.tabla = h.tabla
ORDER BY h.tabla;
