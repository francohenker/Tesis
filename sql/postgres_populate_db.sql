-- =====================================================
-- POBLACIÓN DE DATOS - PostgreSQL 18
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
--   No se usa random(). Cada valor es una función determinista del número
--   de fila: aritmética entera y la función de dispersión hk(x, s), definida
--   igual en mysql_populate_db.sql. Las claves primarias se asignan de forma
--   explícita. Así, este script y su equivalente MySQL generan exactamente
--   las mismas filas, lo que se comprueba con la huella de la sección 15.
--
-- EJECUCIÓN (como superusuario, sobre la base creada con postgres_create_db.sql):
--   psql -d tesis -f sql/postgres_populate_db.sql
-- Los volúmenes pueden reducirse para pruebas (-v ventas=50000 ...), pero
-- solo los valores por defecto corresponden a la tesis y a la huella esperada.
-- Restricciones: productos par, ventas múltiplo de 10 y
-- resenas <= mcm(usuarios, productos).
-- =====================================================

\set ON_ERROR_STOP on
\timing on

\if :{?usuarios}     \else \set usuarios     30000   \endif
\if :{?marcas}       \else \set marcas       800     \endif
\if :{?productos}    \else \set productos    500000  \endif
\if :{?ventas}       \else \set ventas       5000000 \endif
\if :{?movimientos}  \else \set movimientos  2000000 \endif
\if :{?resenas}      \else \set resenas      1000000 \endif
\if :{?devoluciones} \else \set devoluciones 220000  \endif

SET client_encoding = 'UTF8';          -- el archivo está en UTF-8 (literales con acentos)
SET synchronous_commit = off;
-- Durante la carga no se ejecutan los disparadores de las claves foráneas,
-- igual que en MySQL, donde se agregan después. La integridad referencial
-- se verifica en la sección 14. Requiere superusuario.
SET session_replication_role = replica;


-- =====================================================
-- 0. FUNCIÓN DE DISPERSIÓN (idéntica en MySQL)
-- =====================================================
-- hk(x, s): entero en [0, 2^32) derivado de la fila x y de la columna s.
-- Es un mezclador de 32 bits (xorshift-multiplicación): valores
-- distribuidos de forma uniforme y sin correlación entre columnas.

CREATE OR REPLACE FUNCTION hk(x bigint, s integer) RETURNS bigint
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    h bigint := (x * 64 + s) % 4294967296;
BEGIN
    h := ((h # (h >> 16)) * 73244475) % 4294967296;
    h := ((h # (h >> 16)) * 73244475) % 4294967296;
    RETURN h # (h >> 16);
END $$;

-- Valores de control: deben coincidir con los de MySQL.
DO $$
BEGIN
    IF hk(1, 0) <> 2462609589 OR hk(123456, 7) <> 1691283220 OR hk(15000000, 63) <> 2885124033 THEN
        RAISE EXCEPTION 'hk() no reproduce los valores de referencia';
    END IF;
END $$;


-- =====================================================
-- 1. MARCAS (800)
-- =====================================================
INSERT INTO marcas (id_marca, nombre, pais_origen, descripcion, fecha_creacion)
SELECT
    g,
    'Marca_' || g,
    (ARRAY['Argentina','Brasil','Chile','Estados Unidos','China','Alemania','Japón','Corea del Sur','Italia','España'])[1 + g % 10],
    'Descripción de la marca número ' || g,
    TIMESTAMP '2018-01-01' + (g % 365) * INTERVAL '1 day'
FROM generate_series(1, :marcas) AS g;


-- =====================================================
-- 2. CATEGORÍAS (300) - jerarquía de 2 niveles
-- =====================================================
INSERT INTO categorias (id_categoria, nombre, id_categoria_padre, descripcion, nivel)
SELECT g, 'Cat_Padre_' || g, NULL, 'Categoría principal ' || g, 1
FROM generate_series(1, 50) AS g;

INSERT INTO categorias (id_categoria, nombre, id_categoria_padre, descripcion, nivel)
SELECT 50 + g, 'Cat_Hijo_' || g, 1 + (g - 1) % 50, 'Subcategoría ' || g, 2
FROM generate_series(1, 250) AS g;


-- =====================================================
-- 3. USUARIOS (30.000)
-- =====================================================
INSERT INTO usuarios (id_usuario, nombre, apellido, email, telefono, fecha_registro, fecha_ultima_actividad, estado)
SELECT
    g,
    'Nombre_' || g,
    'Apellido_' || g,
    'usuario' || g || '@email.com',
    '11' || lpad((g % 100000000)::text, 8, '0'),
    TIMESTAMP '2020-01-01' + (g % 2000) * INTERVAL '1 day' + (g % 86400) * INTERVAL '1 second',
    TIMESTAMP '2023-01-01' + (g % 1000) * INTERVAL '1 day',
    (ARRAY['activo','activo','activo','activo','inactivo','suspendido'])[1 + g % 6]
FROM generate_series(1, :usuarios) AS g;


-- =====================================================
-- 4. PRODUCTOS (500.000)
-- =====================================================
-- 625 productos por marca. Precio en [100,00; 50.100,00] (≈ 475.000
-- valores distintos), stock en [0; 500], estado independiente de la marca.
INSERT INTO productos (id_producto, sku, nombre, descripcion, id_marca, precio_base, stock_actual, peso_kg, fecha_alta, estado)
SELECT
    g,
    'SKU-' || lpad(g::text, 8, '0'),
    'Producto ' || g,
    'Descripción detallada del producto número ' || g || '. Ideal para pruebas de rendimiento.',
    1 + g % :marcas,
    (10000 + hk(g, 1) % 5000001)::numeric / 100,
    hk(g, 2) % 501,
    (10 + hk(g, 3) % 2001)::numeric / 100,
    TIMESTAMP '2019-01-01' + (g % 2500) * INTERVAL '1 day',
    (ARRAY['disponible','disponible','disponible','disponible','agotado','descontinuado'])[(1 + hk(g, 4) % 6)::int]
FROM generate_series(1, :productos) AS g;


-- =====================================================
-- 5. PRODUCTO_CATEGORIA (1.000.000)
-- =====================================================
INSERT INTO producto_categoria (id_producto, id_categoria, es_principal)
SELECT p, 1 + (p + k) % 300, (k = 0)
FROM generate_series(1, :productos) AS p
CROSS JOIN generate_series(0, 1) AS k;


-- =====================================================
-- 6. DIRECCIONES DE ENVÍO (36.000)
-- =====================================================
-- Principal: id_direccion = id_usuario. Secundaria (1 de cada 5 usuarios):
-- id_direccion = usuarios + id_usuario / 5.
INSERT INTO direcciones_envio (id_direccion, id_usuario, alias, calle, numero_exterior, colonia, ciudad, estado_provincia, codigo_postal, pais, es_principal, fecha_creacion)
SELECT
    u,
    u,
    (ARRAY['Casa','Trabajo','Otro'])[1 + u % 3],
    'Calle ' || (u % 5000),
    ((u % 9000) + 1)::text,
    'Barrio ' || (u % 200),
    (ARRAY['Buenos Aires','Córdoba','Rosario','Mendoza','La Plata','Mar del Plata','Salta','Tucumán'])[1 + u % 8],
    (ARRAY['Buenos Aires','Córdoba','Santa Fe','Mendoza','Buenos Aires','Buenos Aires','Salta','Tucumán'])[1 + u % 8],
    lpad(((u % 9000) + 1000)::text, 4, '0'),
    'Argentina',
    TRUE,
    TIMESTAMP '2020-01-01' + (u % 2000) * INTERVAL '1 day' + (u % 86400) * INTERVAL '1 second'
FROM generate_series(1, :usuarios) AS u;

INSERT INTO direcciones_envio (id_direccion, id_usuario, alias, calle, numero_exterior, colonia, ciudad, estado_provincia, codigo_postal, pais, es_principal, fecha_creacion)
SELECT
    :usuarios + u / 5,
    u,
    'Secundaria',
    'Av. Alternativa ' || (u % 3000),
    ((u % 5000) + 1)::text,
    'Barrio Alt ' || (u % 150),
    (ARRAY['Buenos Aires','Córdoba','Rosario','Mendoza'])[1 + u % 4],
    (ARRAY['Buenos Aires','Córdoba','Santa Fe','Mendoza'])[1 + u % 4],
    lpad(((u % 8000) + 2000)::text, 4, '0'),
    'Argentina',
    FALSE,
    TIMESTAMP '2020-01-31' + (u % 2000) * INTERVAL '1 day' + (u % 86400) * INTERVAL '1 second'
FROM generate_series(1, :usuarios) AS u
WHERE u % 5 = 0;


-- =====================================================
-- 7. TABLA AUXILIAR DE ÍTEMS (se elimina en la sección 13)
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
CREATE UNLOGGED TABLE aux_items (
    v   bigint NOT NULL,
    b   bigint NOT NULL, o2 bigint NOT NULL, o3 bigint NOT NULL,
    c1  bigint NOT NULL, c2 bigint NOT NULL, c3 bigint NOT NULL,
    u1  bigint NOT NULL, u2 bigint NOT NULL, u3 bigint NOT NULL,
    t1  bigint NOT NULL, t2 bigint NOT NULL, t3 bigint NOT NULL,
    ds1 bigint GENERATED ALWAYS AS (c1 * u1 * t1 / 100) STORED,
    ds2 bigint GENERATED ALWAYS AS (c2 * u2 * t2 / 100) STORED,
    ds3 bigint GENERATED ALWAYS AS (c3 * u3 * t3 / 100) STORED
);

INSERT INTO aux_items (v, b, o2, o3, c1, c2, c3, u1, u2, u3, t1, t2, t3)
SELECT
    v,
    hk(v, 30) % :productos,
    1 + hk(v, 31) % (:productos / 2 - 1),
    :productos / 2 + hk(v, 32) % (:productos / 2 - 1),
    1 + hk(v, 33) % 5,
    1 + hk(:ventas + v, 33) % 5,
    1 + hk(2 * :ventas + v, 33) % 5,
    5000 + hk(v, 34) % 1500001,
    5000 + hk(:ventas + v, 34) % 1500001,
    5000 + hk(2 * :ventas + v, 34) % 1500001,
    GREATEST(hk(v, 35) % 31 - 10, 0),
    GREATEST(hk(:ventas + v, 35) % 31 - 10, 0),
    GREATEST(hk(2 * :ventas + v, 35) % 31 - 10, 0)
FROM generate_series(1, :ventas) AS v;


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
    1 + hk(v, 10) % :usuarios,
    NULL,
    TIMESTAMP '2021-01-01' + (v % 1500) * INTERVAL '1 day' + (v % 86400) * INTERVAL '1 second',
    bruto::numeric / 100,
    imp::numeric / 100,
    descu::numeric / 100,
    (bruto - descu + imp)::numeric / 100,
    (ARRAY['pendiente','pagada','pagada','pagada','enviada','entregada','cancelada','devuelta'])[(1 + hk(v, 11) % 8)::int],
    (ARRAY['web','web','web','app','app','tienda_fisica','telefono'])[(1 + hk(v, 12) % 7)::int]
FROM (
    SELECT v,
           c1 * u1 + c2 * u2 + c3 * u3 AS bruto,
           ds1 + ds2 + ds3 AS descu,
           ((c1 * u1 + c2 * u2 + c3 * u3 - ds1 - ds2 - ds3) * 21 + 50) / 100 AS imp
    FROM aux_items
) AS t;


-- =====================================================
-- 9. DETALLE_VENTA (15.000.000) - 3 ítems por venta
-- =====================================================
INSERT INTO detalle_venta (id_detalle, id_venta, id_producto, cantidad, precio_unitario, descuento_item, subtotal_item)
SELECT v, v, 1 + b, c1, u1::numeric / 100, ds1::numeric / 100, (c1 * u1 - ds1)::numeric / 100
FROM aux_items;

INSERT INTO detalle_venta (id_detalle, id_venta, id_producto, cantidad, precio_unitario, descuento_item, subtotal_item)
SELECT :ventas + v, v, 1 + (b + o2) % :productos, c2, u2::numeric / 100, ds2::numeric / 100, (c2 * u2 - ds2)::numeric / 100
FROM aux_items;

INSERT INTO detalle_venta (id_detalle, id_venta, id_producto, cantidad, precio_unitario, descuento_item, subtotal_item)
SELECT 2 * :ventas + v, v, 1 + (b + o3) % :productos, c3, u3::numeric / 100, ds3::numeric / 100, (c3 * u3 - ds3)::numeric / 100
FROM aux_items;


-- =====================================================
-- 10. PAGOS (4.500.000)
-- =====================================================
-- Se excluye exactamente el 10 % de las ventas, elegido con una permutación
-- de 1..ventas (multiplicador coprimo con ventas), sin relación con la fecha.
INSERT INTO pagos (id_venta, metodo_pago, monto, estado, referencia_bancaria, fecha_pago, fecha_aprobacion)
SELECT
    id_venta,
    (ARRAY['tarjeta_credito','tarjeta_credito','tarjeta_debito','paypal','transferencia','efectivo','cripto'])[im],
    total,
    (ARRAY['aprobado','aprobado','aprobado','aprobado','pendiente','rechazado','reembolsado'])[ie],
    'REF-' || id_venta,
    fecha_venta + sp * INTERVAL '1 second',
    CASE WHEN ie IN (1, 2, 3, 4, 7) THEN fecha_venta + (sp + sa) * INTERVAL '1 second' END
FROM (
    SELECT id_venta, total, fecha_venta,
           (1 + hk(id_venta, 41) % 7)::int AS im,
           (1 + hk(id_venta, 42) % 7)::int AS ie,
           hk(id_venta, 43) % 7200 AS sp,
           hk(id_venta, 44) % 3600 AS sa
    FROM venta
    WHERE ((id_venta - 1) * 2654435761) % :ventas >= :ventas / 10
) AS p
ORDER BY id_venta;


-- =====================================================
-- 11. MOVIMIENTOS DE INVENTARIO (2.000.000)
-- =====================================================
INSERT INTO movimientos_inventario (id_movimiento, id_producto, tipo_movimiento, cantidad, cantidad_anterior, cantidad_nueva, id_almacen, motivo, fecha_movimiento)
SELECT
    g,
    1 + g % :productos,
    (ARRAY['entrada','salida','salida','salida','devolucion','ajuste','merma'])[1 + g % 7],
    1 + g % 50,
    100 + g % 400,
    50 + g % 450,
    'CENTRAL',
    'Movimiento automático de prueba ' || g,
    TIMESTAMP '2021-01-01' + (g % 1800) * INTERVAL '1 day'
FROM generate_series(1, :movimientos) AS g;


-- =====================================================
-- 12. RESEÑAS (1.000.000)
-- =====================================================
-- (usuario, producto) = (1 + g % usuarios, 1 + g % productos) no se repite
-- mientras resenas <= mcm(usuarios, productos) = 1.500.000.
INSERT INTO resenas_productos (id_resena, id_usuario, id_producto, calificacion, titulo, comentario, fecha_resena, votos_utiles)
SELECT
    g,
    1 + g % :usuarios,
    1 + g % :productos,
    1 + hk(g, 50) % 5,
    'Reseña ' || g,
    'Comentario de evaluación del producto. Experiencia de compra número ' || g,
    TIMESTAMP '2021-06-01' + (g % 1200) * INTERVAL '1 day',
    g % 50
FROM generate_series(1, :resenas) AS g;


-- =====================================================
-- 13. DEVOLUCIONES (220.000)
-- =====================================================
-- Exactamente :devoluciones ítems, elegidos con una permutación de
-- 1..detalles (multiplicador coprimo con 3*ventas).
INSERT INTO devoluciones (id_detalle_venta, id_venta, motivo, descripcion, estado, monto_reembolso, fecha_solicitud)
SELECT
    d.id_detalle,
    d.id_venta,
    (ARRAY['producto_defectuoso','no_conforme','equivocado','talla_incorrecta','otro'])[(1 + hk(d.id_detalle, 60) % 5)::int],
    'Devolución generada para pruebas de rendimiento',
    (ARRAY['solicitada','aprobada','en_transito','recibida','rechazada','reembolsada'])[(1 + hk(d.id_detalle, 61) % 6)::int],
    ROUND(d.subtotal_item * 0.9, 2),
    v.fecha_venta + (1 + hk(d.id_detalle, 62) % 30) * INTERVAL '1 day'
FROM detalle_venta d
JOIN venta v ON v.id_venta = d.id_venta
WHERE ((d.id_detalle - 1) * 2654435761) % (3 * :ventas) < :devoluciones
ORDER BY d.id_detalle;


-- =====================================================
-- 14. CIERRE: SECUENCIAS, LIMPIEZA Y ESTADÍSTICAS
-- =====================================================
-- Las claves se insertaron de forma explícita: cada secuencia continúa
-- desde el máximo cargado (las inserciones de W3 y W4 usan la secuencia).
SELECT setval(pg_get_serial_sequence('usuarios', 'id_usuario'), (SELECT MAX(id_usuario) FROM usuarios));
SELECT setval(pg_get_serial_sequence('marcas', 'id_marca'), (SELECT MAX(id_marca) FROM marcas));
SELECT setval(pg_get_serial_sequence('categorias', 'id_categoria'), (SELECT MAX(id_categoria) FROM categorias));
SELECT setval(pg_get_serial_sequence('productos', 'id_producto'), (SELECT MAX(id_producto) FROM productos));
SELECT setval(pg_get_serial_sequence('direcciones_envio', 'id_direccion'), (SELECT MAX(id_direccion) FROM direcciones_envio));
SELECT setval(pg_get_serial_sequence('venta', 'id_venta'), (SELECT MAX(id_venta) FROM venta));
SELECT setval(pg_get_serial_sequence('detalle_venta', 'id_detalle'), (SELECT MAX(id_detalle) FROM detalle_venta));
SELECT setval(pg_get_serial_sequence('pagos', 'id_pago'), (SELECT MAX(id_pago) FROM pagos));
SELECT setval(pg_get_serial_sequence('movimientos_inventario', 'id_movimiento'), (SELECT MAX(id_movimiento) FROM movimientos_inventario));
SELECT setval(pg_get_serial_sequence('resenas_productos', 'id_resena'), (SELECT MAX(id_resena) FROM resenas_productos));
SELECT setval(pg_get_serial_sequence('devoluciones', 'id_devolucion'), (SELECT MAX(id_devolucion) FROM devoluciones));

DROP TABLE aux_items;
DROP FUNCTION hk(bigint, integer);

SET session_replication_role = origin;
SET synchronous_commit = on;

-- FREEZE deja fijados los bits de visibilidad de todas las filas, de modo que
-- las primeras lecturas tras restaurar la imagen no reescriban páginas.
VACUUM (FREEZE, ANALYZE);


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
JOIN (VALUES
    ('usuarios', :usuarios::bigint), ('marcas', :marcas), ('categorias', 300),
    ('productos', :productos), ('producto_categoria', 2 * :productos),
    ('direcciones_envio', :usuarios + :usuarios / 5), ('venta', :ventas),
    ('detalle_venta', 3 * :ventas), ('pagos', :ventas - :ventas / 10),
    ('movimientos_inventario', :movimientos), ('resenas_productos', :resenas),
    ('devoluciones', :devoluciones)
) AS e(tabla, esperado) ON e.tabla = t.tabla
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
--    con «esperado», y por lo tanto con la huella obtenida en MySQL.
--    Cada fila aporta (id % 9973 + 1) * (suma de sus columnas: importes en
--    centavos, fechas en segundos desde 2000-01-01 y textos como
--    longitud*1000 + código del primer carácter).
SELECT h.tabla, h.huella, e.esperado,
       CASE WHEN h.huella = e.esperado THEN 'OK' ELSE 'DISTINTA' END AS resultado
FROM (
    SELECT 'usuarios' AS tabla, SUM((id_usuario % 9973 + 1) * (
        COALESCE(EXTRACT(EPOCH FROM fecha_registro - TIMESTAMP '2000-01-01')::bigint, 0)
      + COALESCE(EXTRACT(EPOCH FROM fecha_ultima_actividad - TIMESTAMP '2000-01-01')::bigint, 0)
      + COALESCE(char_length(nombre) * 1000 + ascii(nombre), 0) + COALESCE(char_length(apellido) * 1000 + ascii(apellido), 0)
      + COALESCE(char_length(email) * 1000 + ascii(email), 0) + COALESCE(char_length(telefono) * 1000 + ascii(telefono), 0)
      + COALESCE(char_length(estado) * 1000 + ascii(estado), 0))) AS huella FROM usuarios
    UNION ALL SELECT 'marcas', SUM((id_marca % 9973 + 1) * (
        COALESCE(char_length(nombre) * 1000 + ascii(nombre), 0) + COALESCE(char_length(pais_origen) * 1000 + ascii(pais_origen), 0)
      + COALESCE(char_length(descripcion) * 1000 + ascii(descripcion), 0)
      + COALESCE(EXTRACT(EPOCH FROM fecha_creacion - TIMESTAMP '2000-01-01')::bigint, 0))) FROM marcas
    UNION ALL SELECT 'categorias', SUM((id_categoria % 9973 + 1) * (
        COALESCE(char_length(nombre) * 1000 + ascii(nombre), 0) + COALESCE(id_categoria_padre, 0)
      + COALESCE(char_length(descripcion) * 1000 + ascii(descripcion), 0) + COALESCE(nivel, 0))) FROM categorias
    UNION ALL SELECT 'productos', SUM((id_producto % 9973 + 1) * (
        COALESCE(char_length(sku) * 1000 + ascii(sku), 0) + COALESCE(char_length(nombre) * 1000 + ascii(nombre), 0)
      + COALESCE(char_length(descripcion) * 1000 + ascii(descripcion), 0) + COALESCE(id_marca, 0)
      + COALESCE((precio_base * 100)::bigint, 0) + stock_actual + COALESCE((peso_kg * 100)::bigint, 0)
      + COALESCE(EXTRACT(EPOCH FROM fecha_alta - TIMESTAMP '2000-01-01')::bigint, 0)
      + COALESCE(EXTRACT(EPOCH FROM fecha_baja - TIMESTAMP '2000-01-01')::bigint, 0)
      + COALESCE(char_length(estado) * 1000 + ascii(estado), 0))) FROM productos
    UNION ALL SELECT 'producto_categoria', SUM((id_producto % 9973 + 1) * (
        id_categoria * 2 + COALESCE(es_principal::int, 0))) FROM producto_categoria
    UNION ALL SELECT 'direcciones_envio', SUM((id_direccion % 9973 + 1) * (
        id_usuario + COALESCE(char_length(alias) * 1000 + ascii(alias), 0) + COALESCE(char_length(calle) * 1000 + ascii(calle), 0)
      + COALESCE(char_length(numero_exterior) * 1000 + ascii(numero_exterior), 0)
      + COALESCE(char_length(numero_interior) * 1000 + ascii(numero_interior), 0)
      + COALESCE(char_length(colonia) * 1000 + ascii(colonia), 0) + COALESCE(char_length(ciudad) * 1000 + ascii(ciudad), 0)
      + COALESCE(char_length(estado_provincia) * 1000 + ascii(estado_provincia), 0)
      + COALESCE(char_length(codigo_postal) * 1000 + ascii(codigo_postal), 0) + COALESCE(char_length(pais) * 1000 + ascii(pais), 0)
      + COALESCE(es_principal::int, 0) + COALESCE(EXTRACT(EPOCH FROM fecha_creacion - TIMESTAMP '2000-01-01')::bigint, 0))) FROM direcciones_envio
    UNION ALL SELECT 'venta', SUM((id_venta % 9973 + 1) * (
        id_usuario + COALESCE(id_direccion, 0) + EXTRACT(EPOCH FROM fecha_venta - TIMESTAMP '2000-01-01')::bigint
      + (subtotal * 100)::bigint + (impuestos * 100)::bigint + (descuento * 100)::bigint + (total * 100)::bigint
      + COALESCE(char_length(estado) * 1000 + ascii(estado), 0) + COALESCE(char_length(canal_venta) * 1000 + ascii(canal_venta), 0)
      + COALESCE(char_length(notas) * 1000 + ascii(notas), 0))) FROM venta
    UNION ALL SELECT 'detalle_venta', SUM((id_detalle % 9973 + 1) * (
        id_venta + id_producto + cantidad + (precio_unitario * 100)::bigint
      + COALESCE((descuento_item * 100)::bigint, 0) + (subtotal_item * 100)::bigint)) FROM detalle_venta
    UNION ALL SELECT 'pagos', SUM((id_pago % 9973 + 1) * (
        id_venta + COALESCE(char_length(metodo_pago) * 1000 + ascii(metodo_pago), 0) + (monto * 100)::bigint
      + COALESCE(char_length(estado) * 1000 + ascii(estado), 0)
      + COALESCE(char_length(referencia_bancaria) * 1000 + ascii(referencia_bancaria), 0)
      + COALESCE(EXTRACT(EPOCH FROM fecha_pago - TIMESTAMP '2000-01-01')::bigint, 0)
      + COALESCE(EXTRACT(EPOCH FROM fecha_aprobacion - TIMESTAMP '2000-01-01')::bigint, 0))) FROM pagos
    UNION ALL SELECT 'movimientos_inventario', SUM((id_movimiento % 9973 + 1) * (
        id_producto + COALESCE(char_length(tipo_movimiento) * 1000 + ascii(tipo_movimiento), 0) + cantidad
      + COALESCE(cantidad_anterior, 0) + COALESCE(cantidad_nueva, 0) + COALESCE(char_length(id_almacen) * 1000 + ascii(id_almacen), 0)
      + COALESCE(id_usuario_responsable, 0) + COALESCE(char_length(motivo) * 1000 + ascii(motivo), 0)
      + EXTRACT(EPOCH FROM fecha_movimiento - TIMESTAMP '2000-01-01')::bigint)) FROM movimientos_inventario
    UNION ALL SELECT 'resenas_productos', SUM((id_resena % 9973 + 1) * (
        id_usuario + id_producto + COALESCE(id_venta, 0) + calificacion
      + COALESCE(char_length(titulo) * 1000 + ascii(titulo), 0) + COALESCE(char_length(comentario) * 1000 + ascii(comentario), 0)
      + COALESCE(char_length(imagen_url) * 1000 + ascii(imagen_url), 0)
      + EXTRACT(EPOCH FROM fecha_resena - TIMESTAMP '2000-01-01')::bigint
      + COALESCE(EXTRACT(EPOCH FROM fecha_edicion - TIMESTAMP '2000-01-01')::bigint, 0) + COALESCE(votos_utiles, 0))) FROM resenas_productos
    UNION ALL SELECT 'devoluciones', SUM((id_devolucion % 9973 + 1) * (
        id_detalle_venta + id_venta + COALESCE(char_length(motivo) * 1000 + ascii(motivo), 0)
      + COALESCE(char_length(descripcion) * 1000 + ascii(descripcion), 0) + COALESCE(char_length(estado) * 1000 + ascii(estado), 0)
      + (monto_reembolso * 100)::bigint
      + COALESCE(EXTRACT(EPOCH FROM fecha_solicitud - TIMESTAMP '2000-01-01')::bigint, 0)
      + COALESCE(EXTRACT(EPOCH FROM fecha_resolucion - TIMESTAMP '2000-01-01')::bigint, 0))) FROM devoluciones
) AS h
LEFT JOIN (VALUES
    ('usuarios', 222693132671311018::numeric),
    ('marcas', 187546517283200),
    ('categorias', 1267499125),
    ('productos', 1765666347836257535),
    ('producto_categoria', 1500073410875),
    ('direcciones_envio', 121152879567515831),
    ('venta', 18539439471879191847),
    ('detalle_venta', 431542742352416553),
    ('pagos', 28216751434322407651),
    ('movimientos_inventario', 7379599233490238972),
    ('resenas_productos', 3623203920947812480),
    ('devoluciones', 810905063011644821)
) AS e(tabla, esperado) ON e.tabla = h.tabla
ORDER BY h.tabla;
