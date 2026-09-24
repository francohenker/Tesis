-- =====================================================
-- POBLACIÓN DE DATOS - PostgreSQL 18
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
-- =====================================================

SET work_mem = '256MB';
SET maintenance_work_mem = '1GB';
SET synchronous_commit = off;


-- =====================================================
-- 1. MARCAS (800)
-- =====================================================
INSERT INTO marcas (nombre, pais_origen, descripcion)
SELECT
    'Marca_' || g,
    (ARRAY['Argentina','Brasil','Chile','Estados Unidos','China','Alemania','Japón','Corea del Sur','Italia','España'])[1 + (g % 10)],
    'Descripción de la marca número ' || g
FROM generate_series(1, 800) AS g;


-- =====================================================
-- 2. CATEGORÍAS (300) - jerarquía de 2 niveles
-- =====================================================
INSERT INTO categorias (nombre, id_categoria_padre, descripcion, nivel)
SELECT
    'Cat_Padre_' || g,
    NULL,
    'Categoría principal ' || g,
    1
FROM generate_series(1, 50) AS g;

INSERT INTO categorias (nombre, id_categoria_padre, descripcion, nivel)
SELECT
    'Cat_Hijo_' || g,
    1 + ((g - 1) % 50),
    'Subcategoría ' || g,
    2
FROM generate_series(1, 250) AS g;


-- =====================================================
-- 3. USUARIOS (30.000)
-- =====================================================
INSERT INTO usuarios (nombre, apellido, email, telefono, fecha_registro, fecha_ultima_actividad, estado)
SELECT
    'Nombre_' || g,
    'Apellido_' || g,
    'usuario' || g || '@email.com',
    '11' || lpad((g % 100000000)::text, 8, '0'),
    TIMESTAMP '2020-01-01' + (g % 2000) * INTERVAL '1 day' + (g % 86400) * INTERVAL '1 second',
    TIMESTAMP '2023-01-01' + (g % 1000) * INTERVAL '1 day',
    (ARRAY['activo','activo','activo','activo','inactivo','suspendido'])[1 + (g % 6)]
FROM generate_series(1, 30000) AS g;


-- =====================================================
-- 4. PRODUCTOS (500.000)
-- =====================================================
INSERT INTO productos (sku, nombre, descripcion, id_marca, precio_base, stock_actual, peso_kg, fecha_alta, estado)
SELECT
    'SKU-' || lpad(g::text, 8, '0'),
    'Producto ' || g,
    'Descripción detallada del producto número ' || g || '. Ideal para pruebas de rendimiento.',
    1 + (g % 800),
    round((random() * 50000 + 100)::numeric, 2),
    (random() * 500)::int,
    round((random() * 20 + 0.1)::numeric, 2),
    TIMESTAMP '2019-01-01' + (g % 2500) * INTERVAL '1 day',
    (ARRAY['disponible','disponible','disponible','disponible','agotado','descontinuado'])[1 + (g % 6)]
FROM generate_series(1, 500000) AS g;


-- =====================================================
-- 5. PRODUCTO_CATEGORIA (~750.000)
-- =====================================================
INSERT INTO producto_categoria (id_producto, id_categoria, es_principal)
SELECT
    p.id_producto,
    1 + ((p.id_producto + c.ord) % 300),
    (c.ord = 0)
FROM productos p
CROSS JOIN generate_series(0, 1) AS c(ord)
ON CONFLICT DO NOTHING;


-- =====================================================
-- 6. DIRECCIONES DE ENVÍO (~36.000)
-- =====================================================
INSERT INTO direcciones_envio (id_usuario, alias, calle, numero_exterior, colonia, ciudad, estado_provincia, codigo_postal, pais, es_principal)
SELECT
    u.id_usuario,
    (ARRAY['Casa','Trabajo','Otro'])[1 + (u.id_usuario % 3)],
    'Calle ' || (u.id_usuario % 5000),
    ((u.id_usuario % 9000) + 1)::text,
    'Barrio ' || (u.id_usuario % 200),
    (ARRAY['Buenos Aires','Córdoba','Rosario','Mendoza','La Plata','Mar del Plata','Salta','Tucumán'])[1 + (u.id_usuario % 8)],
    (ARRAY['Buenos Aires','Córdoba','Santa Fe','Mendoza','Buenos Aires','Buenos Aires','Salta','Tucumán'])[1 + (u.id_usuario % 8)],
    lpad(((u.id_usuario % 9000) + 1000)::text, 4, '0'),
    'Argentina',
    TRUE
FROM usuarios u;

INSERT INTO direcciones_envio (id_usuario, alias, calle, numero_exterior, colonia, ciudad, estado_provincia, codigo_postal, pais, es_principal)
SELECT
    u.id_usuario,
    'Secundaria',
    'Av. Alternativa ' || (u.id_usuario % 3000),
    ((u.id_usuario % 5000) + 1)::text,
    'Barrio Alt ' || (u.id_usuario % 150),
    (ARRAY['Buenos Aires','Córdoba','Rosario','Mendoza'])[1 + (u.id_usuario % 4)],
    (ARRAY['Buenos Aires','Córdoba','Santa Fe','Mendoza'])[1 + (u.id_usuario % 4)],
    lpad(((u.id_usuario % 8000) + 2000)::text, 4, '0'),
    'Argentina',
    FALSE
FROM usuarios u
WHERE u.id_usuario % 5 = 0;


-- =====================================================
-- 7. VENTAS (5.000.000)
-- =====================================================
DO $$
DECLARE
    batch_size   CONSTANT INT := 500000;
    total_rows   CONSTANT INT := 5000000;
    current_start INT := 1;
    current_end   INT;
BEGIN
    WHILE current_start <= total_rows LOOP
        current_end := LEAST(current_start + batch_size - 1, total_rows);

        INSERT INTO venta (id_usuario, id_direccion, fecha_venta, subtotal, impuestos, descuento, total, estado, canal_venta)
        SELECT
            1 + ((g - 1) % 30000),
            NULL,
            TIMESTAMP '2021-01-01' + ((g % 1500) * INTERVAL '1 day')
                                   + ((g % 86400) * INTERVAL '1 second'),
            round((random() * 80000 + 500)::numeric, 2),
            round((random() * 15000)::numeric, 2),
            round((random() * 5000)::numeric, 2),
            round((random() * 90000 + 500)::numeric, 2),
            (ARRAY['pendiente','pagada','pagada','pagada','enviada','entregada','cancelada','devuelta'])[1 + (g % 8)],
            (ARRAY['web','web','web','app','app','tienda_fisica','telefono'])[1 + (g % 7)]
        FROM generate_series(current_start, current_end) AS g;

        RAISE NOTICE 'Ventas insertadas: % - %', current_start, current_end;
        current_start := current_end + 1;
    END LOOP;
END $$;


-- =====================================================
-- 8. DETALLE_VENTA (15.000.000)  → promedio 3 ítems por venta
-- =====================================================
DO $$
DECLARE
    batch_size   CONSTANT INT := 500000;
    total_ventas CONSTANT INT := 5000000;
    current_start INT := 1;
    current_end   INT;
BEGIN
    WHILE current_start <= total_ventas LOOP
        current_end := LEAST(current_start + batch_size - 1, total_ventas);

        -- Ítem 1 (todas las ventas)
        INSERT INTO detalle_venta (id_venta, id_producto, cantidad, precio_unitario, descuento_item, subtotal_item)
        SELECT
            v.id_venta,
            1 + ((v.id_venta + 17) % 500000),
            1 + (v.id_venta % 5),
            round((random() * 15000 + 100)::numeric, 2),
            round((random() * 500)::numeric, 2),
            round((random() * 20000 + 100)::numeric, 2)
        FROM venta v
        WHERE v.id_venta BETWEEN current_start AND current_end;

        -- Ítem 2 (~80% de las ventas)
        INSERT INTO detalle_venta (id_venta, id_producto, cantidad, precio_unitario, descuento_item, subtotal_item)
        SELECT
            v.id_venta,
            1 + ((v.id_venta + 91) % 500000),
            1 + (v.id_venta % 3),
            round((random() * 12000 + 80)::numeric, 2),
            round((random() * 300)::numeric, 2),
            round((random() * 15000 + 80)::numeric, 2)
        FROM venta v
        WHERE v.id_venta BETWEEN current_start AND current_end
          AND v.id_venta % 10 < 8;

        -- Ítem 3 (~40% de las ventas) → total aproximado 15M
        INSERT INTO detalle_venta (id_venta, id_producto, cantidad, precio_unitario, descuento_item, subtotal_item)
        SELECT
            v.id_venta,
            1 + ((v.id_venta + 53) % 500000),
            1 + (v.id_venta % 2),
            round((random() * 8000 + 50)::numeric, 2),
            0,
            round((random() * 10000 + 50)::numeric, 2)
        FROM venta v
        WHERE v.id_venta BETWEEN current_start AND current_end
          AND v.id_venta % 10 < 4;

        RAISE NOTICE 'Detalles generados para ventas: % - %', current_start, current_end;
        current_start := current_end + 1;
    END LOOP;
END $$;


-- =====================================================
-- 9. PAGOS (~4.500.000)
-- =====================================================
INSERT INTO pagos (id_venta, metodo_pago, monto, estado, referencia_bancaria, fecha_pago, fecha_aprobacion)
SELECT
    v.id_venta,
    (ARRAY['tarjeta_credito','tarjeta_credito','tarjeta_debito','paypal','transferencia','efectivo','cripto'])[1 + (v.id_venta % 7)],
    v.total,
    (ARRAY['aprobado','aprobado','aprobado','aprobado','pendiente','rechazado','reembolsado'])[1 + (v.id_venta % 7)],
    'REF-' || v.id_venta,
    v.fecha_venta + (random() * INTERVAL '2 hours'),
    CASE WHEN v.id_venta % 7 < 5 THEN v.fecha_venta + (random() * INTERVAL '3 hours') ELSE NULL END
FROM venta v
WHERE v.id_venta % 10 < 9;


-- =====================================================
-- 10. MOVIMIENTOS DE INVENTARIO (2.000.000)
-- =====================================================
INSERT INTO movimientos_inventario (id_producto, tipo_movimiento, cantidad, cantidad_anterior, cantidad_nueva, id_almacen, motivo, fecha_movimiento)
SELECT
    1 + (g % 500000),
    (ARRAY['entrada','salida','salida','salida','devolucion','ajuste','merma'])[1 + (g % 7)],
    1 + (g % 50),
    100 + (g % 400),
    50 + (g % 450),
    'CENTRAL',
    'Movimiento automático de prueba ' || g,
    TIMESTAMP '2021-01-01' + (g % 1800) * INTERVAL '1 day'
FROM generate_series(1, 2000000) AS g;


-- =====================================================
-- 11. RESEÑAS (~1.000.000)
-- =====================================================
INSERT INTO reseñas_productos (id_usuario, id_producto, calificacion, titulo, comentario, fecha_reseña, votos_utiles)
SELECT
    1 + (g % 30000),
    1 + (g % 500000),
    1 + (g % 5),
    'Reseña ' || g,
    'Comentario de evaluación del producto. Experiencia de compra número ' || g,
    TIMESTAMP '2021-06-01' + (g % 1200) * INTERVAL '1 day',
    g % 50
FROM generate_series(1, 1000000) AS g
ON CONFLICT (id_usuario, id_producto) DO NOTHING;


-- =====================================================
-- 12. DEVOLUCIONES (~300.000)
-- =====================================================
INSERT INTO devoluciones (id_detalle_venta, id_venta, motivo, descripcion, estado, monto_reembolso, fecha_solicitud)
SELECT
    d.id_detalle,
    d.id_venta,
    (ARRAY['producto_defectuoso','no_conforme','equivocado','talla_incorrecta','otro'])[1 + (d.id_detalle % 5)],
    'Devolución generada para pruebas de rendimiento',
    (ARRAY['solicitada','aprobada','en_transito','recibida','rechazada','reembolsada'])[1 + (d.id_detalle % 6)],
    d.subtotal_item * 0.9,
    TIMESTAMP '2022-01-01' + (d.id_detalle % 900) * INTERVAL '1 day'
FROM detalle_venta d
WHERE d.id_detalle % 50 = 0
LIMIT 300000;


-- =====================================================
-- REVERTIR CONFIGURACIONES Y ACTUALIZAR ESTADÍSTICAS
-- =====================================================
SET synchronous_commit = on;
ANALYZE;


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
