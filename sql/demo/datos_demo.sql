-- =====================================================================
-- sql/demo/datos_demo.sql · Datos de DEMOSTRACIÓN (100 % ficticios)
-- Requiere: sql/01 a sql/10 (esquema, configuración, fn_clasificar y
-- frases_sentido). Ejecutar en una base NUEVA (otro proyecto de Supabase
-- o un PostgreSQL local), nunca en la base real.
--
-- Para qué: que el repositorio, el panel de Retool, las capturas y el GIF
-- muestren el sistema funcionando sin exponer un solo movimiento real.
--
-- Por qué en sql/demo/ y no como sql/11_...:
--   Los scripts numerados son MIGRACIONES: se ejecutan todos, en orden, en
--   cualquier base (también la real). Los datos demo NO deben correr nunca
--   en la base real, así que viven aparte y se ejecutan a propósito.
--
-- Qué genera (3 meses: los 2 anteriores y el actual, hasta hoy):
--   · Gastos del bot (pasajes, almuerzos, antojos) en Efectivo y Yape.
--   · Correos del BCP (consumos, Yape recibido, pago de servicio, retiro,
--     transferencia) con su copia en correos_raw, como la captura real.
--   · Un caso de conciliación (recibo vinculado al consumo del banco).
--   · Un "deshacer" (movimiento anulado), un pago "Sin categoría" y
--     correos "Por revisar" (uno sugerido por IA) para el panel.
--   · Presupuestos (uno en alerta y otro excedido) y ejecuciones (salud).
--
-- Buenas prácticas aplicadas:
--   · GUARDIA: si la base tiene un solo dato que no sea demo, se detiene
--     sin tocar nada (RAISE EXCEPTION → ROLLBACK).
--   · IDEMPOTENTE: borra la demo anterior (solo filas marcadas DEMO) y la
--     vuelve a crear. Correrlo N veces deja el mismo resultado, con las
--     fechas movidas al mes actual (así el panel nunca se ve "viejo").
--   · DETERMINISTA: los montos "aleatorios" salen de md5(fecha), no de
--     random(): hoy y mañana se generan los mismos importes por día.
--   · Categorías con fn_clasificar (sql/09), la MISMA regla del sistema
--     real; si el diccionario cambia, la demo lo refleja.
--   · PRUEBAS dentro de la transacción: si alguna falla, no queda nada.
--
-- PostgreSQL vs SQL Server en este script:
--   · CREATE TEMP TABLE ... ON COMMIT DROP ≈ #tabla_temporal (se borra sola).
--   · generate_series(desde, hasta, '1 day') genera una fila por día; en
--     SQL Server harías una tabla de números o un CTE recursivo.
--   · CROSS JOIN LATERAL (VALUES ...) ≈ CROSS APPLY (VALUES ...).
--   · timestamp AT TIME ZONE 'America/Lima' → "esta hora es de Lima";
--     devuelve TIMESTAMPTZ (≈ ... AT TIME ZONE 'SA Pacific Standard Time').
--   · ON CONFLICT ... DO UPDATE ≈ MERGE ... WHEN MATCHED THEN UPDATE.
--   · RAISE EXCEPTION ≈ THROW 50000, 'mensaje', 1.
--   · trim_scale(3.00) = 3 (quita ceros decimales); no existe en SQL Server.
-- =====================================================================
BEGIN;

-- ---------------------------------------------------------------------
-- 0. Guardias: ¿es una base demo? ¿existe la configuración?
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.movimientos
               WHERE numero_operacion IS NULL OR numero_operacion NOT LIKE 'DEMO-%')
    OR EXISTS (SELECT 1 FROM public.correos_raw WHERE gmail_message_id NOT LIKE 'demo-%') THEN
        RAISE EXCEPTION 'Esta base tiene datos que no son demo. Ejecuta este script solo en una base de demostración.';
    END IF;
    IF (SELECT count(*) FROM public.cuentas WHERE alias IN ('BCP Débito', 'BCP Yape', 'Efectivo')) <> 3
    OR NOT EXISTS (SELECT 1 FROM public.frases_sentido) THEN
        RAISE EXCEPTION 'Falta configuración: ejecuta antes sql/01 a sql/10.';
    END IF;
END
$$;

-- ---------------------------------------------------------------------
-- 1. Borrar la demo anterior (solo filas marcadas como demo)
-- ---------------------------------------------------------------------
-- Un solo DELETE para movimientos: la FK id_movimiento_vinculado se
-- revisa al final de la sentencia, así recibo y consumo salen juntos.
DELETE FROM public.movimientos WHERE numero_operacion LIKE 'DEMO-%';
DELETE FROM public.correos_raw WHERE gmail_message_id LIKE 'demo-%';
DELETE FROM public.ejecuciones WHERE detalle LIKE '[DEMO]%';

-- ---------------------------------------------------------------------
-- 2. Movimientos a generar (tabla temporal de trabajo)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE demo_mov (
    clave          TEXT,          -- numero_operacion: DEMO-TG-000001 / DEMO-000001
    tipo           TEXT,          -- etiqueta interna para ordenar
    fecha          TIMESTAMPTZ,
    monto          NUMERIC(12,2),
    sentido        TEXT,
    cuenta         TEXT,          -- alias de la cuenta (no ids fijos)
    fuente         TEXT,          -- nombre de la fuente (solo correos)
    asunto         TEXT,          -- asunto del correo ficticio
    texto          TEXT,          -- descripción: mensaje del bot o tipo de correo
    contraparte    TEXT,
    origen         TEXT,
    categoria_fija TEXT,          -- "corregida en Retool"; NULL = la decide fn_clasificar
    estado         TEXT DEFAULT 'activo'
) ON COMMIT DROP;

WITH limites AS (
    SELECT date_trunc('month', now() AT TIME ZONE 'America/Lima')::date - INTERVAL '2 months' AS desde,
           (now() AT TIME ZONE 'America/Lima')::date                                         AS hasta
),
dias AS (
    SELECT g::date                                          AS dia,
           EXTRACT(ISODOW FROM g)::int                      AS dow,   -- 1 = lunes … 7 = domingo
           EXTRACT(DAY    FROM g)::int                      AS dm,
           -- Tres "dados" deterministas por día (0–255), sacados del md5 de la fecha.
           get_byte(decode(md5(g::date::text), 'hex'), 0)   AS h1,
           get_byte(decode(md5(g::date::text), 'hex'), 1)   AS h2,
           get_byte(decode(md5(g::date::text), 'hex'), 2)   AS h3
    FROM limites, generate_series(limites.desde, limites.hasta, INTERVAL '1 day') AS g
),
base AS (
    SELECT d.dia, r.*
    FROM dias d
    CROSS JOIN LATERAL (VALUES
      -- (incluir, tipo, hora, monto, sentido, cuenta, fuente, texto, contraparte, origen, categoria_fija)
      -- Bot · días de semana -------------------------------------------------
      (d.dow <= 5, 'pasaje', TIME '07:10',
         CASE WHEN d.h1 % 4 = 0 THEN 2.50 ELSE 3.00 END::numeric, 'egreso', 'Efectivo', NULL::text,
         'pasaje %s', NULL::text, 'telegram', NULL::text),
      (d.dow <= 5 AND d.h2 % 3 <> 0, 'combi', TIME '18:40',
         2.50, 'egreso', 'Efectivo', NULL, 'combi %s', NULL, 'telegram', NULL),
      (d.dow <= 5 AND d.h2 >= 80, 'menu', TIME '13:20',
         (10 + (d.h1 % 3) * 2)::numeric, 'egreso', 'Efectivo', NULL, 'menu %s', NULL, 'telegram', NULL),
      (d.dow <= 5 AND d.h2 < 80, 'almuerzo yape', TIME '13:25',
         (10 + (d.h1 % 3) * 2)::numeric, 'egreso', 'BCP Yape', NULL, 'yape %s almuerzo', NULL, 'telegram', NULL),
      (d.dow <= 5 AND d.h3 < 90, 'antojo', TIME '16:05',
         (ARRAY[1.50, 3.50, 0.20])[d.h3 % 3 + 1], 'egreso', 'Efectivo', NULL,
         (ARRAY['golosina %s', 'cafe %s', 'queque %s'])[d.h3 % 3 + 1], NULL, 'telegram', NULL),
      -- Bot · fines de semana ------------------------------------------------
      (d.dow = 7 AND d.h2 < 140, 'pollo', TIME '13:30',
         (18 + (d.h3 % 3) * 4)::numeric, 'egreso', 'Efectivo', NULL, 'pollo %s', NULL, 'telegram', NULL),
      (d.dow IN (5, 6) AND d.h3 < 70, 'indrive', TIME '22:15',
         (9 + d.h1 % 5)::numeric, 'egreso', 'Efectivo', NULL, 'indrive %s', NULL, 'telegram', NULL),
      -- Bot · casos de frases_sentido (sql/10) -------------------------------
      (d.dm = 12, 'clases', TIME '19:00',
         50.00, 'ingreso', 'Efectivo', NULL, 'me pagaron %s por clases', NULL, 'telegram', 'Otros ingresos'),
      (d.dm = 27, 'se me cayo', TIME '17:45',
         5.00, 'egreso', 'Efectivo', NULL, 'se me cayo %s', NULL, 'telegram', 'Otros gastos'),
      (d.dm = 20, 'cuota', TIME '20:10',
         15.00, 'egreso', 'BCP Yape', NULL, 'yape %s a Luis por la cuota', 'Luis', 'telegram', 'Otros gastos'),
      (d.dm = 6, 'copias', TIME '11:00',
         2.40, 'egreso', 'Efectivo', NULL, 'copias %s', NULL, 'telegram', NULL),
      -- Correos del BCP ------------------------------------------------------
      (d.dow = 6 AND d.h1 < 170, 'rappi', TIME '20:30',
         (20 + d.h2 % 25 + 0.90)::numeric, 'egreso', 'BCP Débito', 'BCP · Consumo tarjeta de débito',
         'Consumo', 'RAPPI PERU', 'correo', NULL),
      (d.dm = 1, 'mesada', TIME '09:00',
         800.00, 'ingreso', 'BCP Yape', 'BCP · Yape recibido', 'Yape recibido', 'Familia D.', 'correo', NULL),
      (d.dm = 22, 'yape recibido', TIME '18:20',
         20.00, 'ingreso', 'BCP Yape', 'BCP · Yape recibido', 'Yape recibido', 'Carlos R.', 'correo', NULL),
      (d.dm = 3, 'retiro', TIME '10:30',
         100.00, 'egreso', 'BCP Débito', 'BCP · Retiro en Agente', 'Retiro en agente', 'Agente BCP', 'correo', NULL),
      (d.dm = 10, 'internet', TIME '08:45',
         29.90, 'egreso', 'BCP Débito', 'BCP · Pago de servicio', 'Pago de servicio', 'ENTEL PERU', 'correo', NULL),
      (d.dm = 8, 'temu', TIME '21:10',
         45.90, 'egreso', 'BCP Débito', 'BCP · Consumo tarjeta de débito', 'Consumo', 'TEMU', 'correo', NULL),
      (d.dm = 15, 'steam', TIME '23:05',
         18.50, 'egreso', 'BCP Débito', 'BCP · Consumo tarjeta de débito', 'Consumo', 'STEAMGAMES', 'correo', NULL),
      (d.dm = 18, 'pagseguro', TIME '15:40',
         35.00, 'egreso', 'BCP Débito', 'BCP · Consumo tarjeta de débito', 'Consumo', 'PAGSEGURO*TIENDA', 'correo', NULL),
      (d.dm = 25, 'transferencia', TIME '12:00',
         50.00, 'egreso', 'BCP Débito', 'BCP · Transferencia a terceros', 'Transferencia a terceros', 'Ana T.', 'correo', 'Otros gastos'),
      (d.dm = 13 AND d.dia < (SELECT date_trunc('month', hasta) FROM limites), 'udemy', TIME '22:30',
         39.90, 'egreso', 'BCP Débito', 'BCP · Consumo tarjeta de débito', 'Consumo', 'UDEMY', 'correo', NULL)
    ) AS r(incluir, tipo, hora, monto, sentido, cuenta, fuente, texto, contraparte, origen, categoria_fija)
    WHERE r.incluir
)
INSERT INTO demo_mov (tipo, fecha, monto, sentido, cuenta, fuente, texto, contraparte, origen, categoria_fija)
SELECT tipo,
       (dia + hora) AT TIME ZONE 'America/Lima',          -- hora local de Lima → TIMESTAMPTZ
       monto, sentido, cuenta, fuente,
       CASE WHEN origen = 'telegram' THEN format(texto, trim_scale(monto)) ELSE texto END,
       contraparte, origen, categoria_fija
FROM base
WHERE (dia + hora) AT TIME ZONE 'America/Lima' <= now();   -- nada en el futuro

-- Casos especiales -------------------------------------------------------
-- Conciliación: el consumo del banco y el recibo de la app son el MISMO
-- gasto. El recibo se vincula al consumo y no suma en los totales.
INSERT INTO demo_mov (tipo, fecha, monto, sentido, cuenta, fuente, texto, contraparte, origen)
SELECT v.tipo, (date_trunc('month', now() AT TIME ZONE 'America/Lima') - INTERVAL '1 month' + v.desfase) AT TIME ZONE 'America/Lima',
       32.90, 'egreso', 'BCP Débito', v.fuente, v.texto, v.contraparte, 'correo'
FROM (VALUES
    ('conciliado banco', INTERVAL '13 days 20 hours',            'BCP · Consumo tarjeta de débito', 'Consumo',             'RAPPI PERU'),
    ('conciliado recibo', INTERVAL '13 days 20 hours 2 minutes', NULL,                              'Recibo de tu pedido', 'Rappi')
) AS v(tipo, desfase, fuente, texto, contraparte);

-- "deshacer" en el bot: se escribió 30 en vez de 3. Queda anulado (no se borra).
INSERT INTO demo_mov (tipo, fecha, monto, sentido, cuenta, texto, origen, estado)
VALUES ('anulado', ((now() AT TIME ZONE 'America/Lima')::date - 1 + TIME '07:15') AT TIME ZONE 'America/Lima', 30.00, 'egreso', 'Efectivo', 'pasaje 30', 'telegram', 'anulado');

-- Asunto del correo según la fuente (debe calzar con su regex: se prueba al final).
UPDATE demo_mov SET asunto = CASE fuente
    WHEN 'BCP · Consumo tarjeta de débito' THEN 'Realizaste un consumo con tu Tarjeta de Débito BCP'
    WHEN 'BCP · Yape recibido'             THEN 'Constancia de recepción de Yapeo a celular'
    WHEN 'BCP · Retiro en Agente'          THEN 'Realizaste un retiro en un Agente BCP'
    WHEN 'BCP · Pago de servicio'          THEN 'CONSTANCIA DE PAGO DE SERVICIO'
    WHEN 'BCP · Transferencia a terceros'  THEN 'Constancia de Transferencia a Terceros'
    ELSE 'Recibo de tu pedido' END
WHERE origen = 'correo';

-- Clave única y legible: DEMO-TG-000001 (bot) o DEMO-000001 (correo).
UPDATE demo_mov d
SET clave = 'DEMO-' || CASE WHEN d.origen = 'telegram' THEN 'TG-' ELSE '' END || lpad(n.rn::text, 6, '0')
FROM (SELECT ctid, row_number() OVER (ORDER BY fecha, tipo) AS rn FROM demo_mov) n   -- ctid ≈ %%physloc%%
WHERE d.ctid = n.ctid;

-- ---------------------------------------------------------------------
-- 3. correos_raw: copia "original" de cada correo (como la captura real)
-- ---------------------------------------------------------------------
INSERT INTO public.correos_raw
    (gmail_message_id, remitente, asunto, fecha_correo, cuerpo, id_fuente, estado, procesado_en)
SELECT 'demo-' || lower(d.clave),
       CASE WHEN d.fuente IS NULL THEN 'recibos@app-delivery.example'
            ELSE 'BCP <notificaciones@notificacionesbcp.com.pe>' END,
       d.asunto,
       d.fecha,
       format('[DATOS DEMO] %s · Monto: S/ %s · %s · Operación: %s', d.texto, d.monto, d.contraparte, d.clave),
       f.id_fuente,
       'procesado',
       d.fecha + INTERVAL '2 minutes'
FROM demo_mov d
LEFT JOIN public.fuentes f ON f.nombre = d.fuente
WHERE d.origen = 'correo';

-- Correos SIN movimiento: lo que ve la pestaña "Por revisar" y "Salud".
INSERT INTO public.correos_raw
    (gmail_message_id, remitente, asunto, fecha_correo, cuerpo, id_fuente, estado,
     detalle_error, datos_extraidos, sugerido_por_ia, procesado_en)
SELECT v.id, v.remitente, v.asunto, now() - v.hace, '[DATOS DEMO] ' || v.asunto,
       f.id_fuente, v.estado, v.detalle, v.datos::jsonb, v.ia, now() - v.hace + INTERVAL '2 minutes'
FROM (VALUES
    ('demo-revisar-ia', 'ventas@tienda-ficticia.example', 'Gracias por tu compra #A-1029', INTERVAL '20 hours',
     NULL, 'por_revisar', 'Fuente desconocida: el extractor genérico no tuvo confianza',
     '{"monto": 59.90, "moneda": "PEN", "sentido": "egreso", "contraparte": "Tienda Ficticia SAC", "categoria": "Compras online"}', true),
    ('demo-revisar-1', 'avisos@billetera-ficticia.example', 'Tu movimiento fue registrado', INTERVAL '2 days',
     NULL, 'por_revisar', 'No se encontró el monto en el correo', '{"monto": null, "moneda": "PEN"}', false),
    ('demo-ignorado-1', 'BCP <notificaciones@notificacionesbcp.com.pe>', 'Tu operación fue rechazada', INTERVAL '5 days',
     'BCP · Operación rechazada', 'ignorado', NULL, NULL, false)
) AS v(id, remitente, asunto, hace, fuente, estado, detalle, datos, ia)
LEFT JOIN public.fuentes f ON f.nombre = v.fuente;

-- ---------------------------------------------------------------------
-- 4. movimientos
-- ---------------------------------------------------------------------
-- Categoría: la "corregida" si la hay; si no, fn_clasificar con los mismos
-- argumentos que usa el sistema real:
--   · correos → texto = contraparte + descripción, con la fuente.
--   · bot     → texto = mensaje, con p_sentido (un ingreso no cae en Comida).
INSERT INTO public.movimientos
    (fecha, monto, moneda, sentido, id_cuenta, id_categoria, descripcion, contraparte,
     numero_operacion, origen, id_correo, estado)
SELECT d.fecha, d.monto, 'PEN', d.sentido, cu.id_cuenta,
       COALESCE(cf.id_categoria,
                public.fn_clasificar(concat_ws(' ', d.contraparte, d.texto),
                                     f.id_fuente,
                                     CASE WHEN d.origen = 'telegram' THEN d.sentido END)),
       d.texto, d.contraparte, d.clave, d.origen, cr.id_correo, d.estado
FROM demo_mov d
JOIN public.cuentas cu          ON cu.alias  = d.cuenta
LEFT JOIN public.fuentes f      ON f.nombre  = d.fuente
LEFT JOIN public.categorias cf  ON cf.nombre = d.categoria_fija
LEFT JOIN public.correos_raw cr ON cr.gmail_message_id = 'demo-' || lower(d.clave);

-- Conciliación: el recibo apunta al consumo del banco.
UPDATE public.movimientos r
SET id_movimiento_vinculado = b.id_movimiento
FROM demo_mov dr, demo_mov db, public.movimientos b
WHERE dr.tipo = 'conciliado recibo' AND db.tipo = 'conciliado banco'
  AND r.numero_operacion = dr.clave AND b.numero_operacion = db.clave;

-- ---------------------------------------------------------------------
-- 5. Presupuestos (desde hace 2 meses). DO UPDATE: aquí sí se pisa,
--    porque son valores de demo, no algo que el usuario editó.
-- ---------------------------------------------------------------------
INSERT INTO public.presupuestos (id_categoria, monto_mensual, vigente_desde)
SELECT c.id_categoria, v.monto,
       (date_trunc('month', now() AT TIME ZONE 'America/Lima') - INTERVAL '2 months')::date
FROM (VALUES
    ('Comida',          320.00),   -- a fin de mes suele pasar el 80 % (alerta)
    ('Transporte',      150.00),
    ('Compras online',   40.00),   -- excedido desde el día 8 (Temu 45.90)
    ('Entretenimiento',  60.00),
    ('Servicios',        40.00)
) AS v(categoria, monto)
JOIN public.categorias c ON c.nombre = v.categoria
ON CONFLICT (id_categoria, vigente_desde) DO UPDATE SET monto_mensual = EXCLUDED.monto_mensual;

-- ---------------------------------------------------------------------
-- 6. ejecuciones (monitoreo): captura cada 15 min (últimas 48 h, con un
--    error de hace 30 h ya superado) y una fila por mensaje del bot (7 días).
-- ---------------------------------------------------------------------
INSERT INTO public.ejecuciones (proceso, inicio, fin, leidos, insertados, por_revisar, errores, llamadas_ia, detalle)
SELECT 'captura', t, t + INTERVAL '8 seconds',
       CASE WHEN get_byte(decode(md5(t::text), 'hex'), 0) < 40 THEN 1 ELSE 0 END,
       CASE WHEN get_byte(decode(md5(t::text), 'hex'), 0) < 40 THEN 1 ELSE 0 END,
       0,
       CASE WHEN t BETWEEN now() - INTERVAL '31 hours' AND now() - INTERVAL '30 hours 45 minutes' THEN 1 ELSE 0 END,
       0,
       CASE WHEN t BETWEEN now() - INTERVAL '31 hours' AND now() - INTERVAL '30 hours 45 minutes'
            THEN '[DEMO] Supabase 503: el correo conserva su etiqueta y se reintenta'
            ELSE '[DEMO] captura' END
FROM generate_series(date_trunc('hour', now()) - INTERVAL '48 hours', now() - INTERVAL '1 minute', INTERVAL '15 minutes') AS t
UNION ALL
SELECT 'bot', d.fecha, d.fecha + INTERVAL '800 milliseconds', 1, 1, 0, 0,
       CASE WHEN d.categoria_fija IS NOT NULL THEN 1 ELSE 0 END,
       '[DEMO] atendido en 800 ms'
FROM demo_mov d
WHERE d.origen = 'telegram' AND d.fecha >= now() - INTERVAL '7 days';

-- ---------------------------------------------------------------------
-- 7. Pruebas: si alguna falla, RAISE EXCEPTION deshace TODO el script.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    fallas TEXT;
BEGIN
    SELECT string_agg(prueba, '; ') INTO fallas
    FROM (VALUES
        ('todos los movimientos generados se insertaron',
            (SELECT count(*) FROM demo_mov) = (SELECT count(*) FROM public.movimientos WHERE numero_operacion LIKE 'DEMO-%')),
        ('cada correo calza con el regex de su fuente (remitente y asunto)',
            NOT EXISTS (SELECT 1 FROM public.correos_raw c JOIN public.fuentes f USING (id_fuente)
                        WHERE c.gmail_message_id LIKE 'demo-%'
                          AND NOT (c.remitente ~* f.remitente_patron AND c.asunto ~* coalesce(f.asunto_patron, '')))),
        ('el sentido de cada mensaje del bot respeta frases_sentido (gana la más larga; sin frase = egreso)',
            NOT EXISTS (SELECT 1 FROM demo_mov d
                        WHERE d.origen = 'telegram'
                          AND d.sentido <> coalesce((SELECT fs.sentido FROM public.frases_sentido fs
                                                     WHERE fs.activo
                                                       AND ' ' || public.fn_normalizar(d.texto) || ' ' LIKE '% ' || fs.frase || ' %'
                                                     ORDER BY length(fs.frase) DESC LIMIT 1), 'egreso'))),
        ('fn_clasificar: pasaje → Transporte, menu → Comida, STEAMGAMES → Entretenimiento',
            (SELECT bool_and(c.nombre = v.esperada)
             FROM (VALUES ('pasaje%', 'Transporte'), ('menu%', 'Comida'), ('Consumo', 'Entretenimiento')) AS v(desc_like, esperada)
             JOIN LATERAL (SELECT m.id_categoria FROM public.movimientos m
                           WHERE m.numero_operacion LIKE 'DEMO-%' AND m.descripcion LIKE v.desc_like
                             AND (v.desc_like <> 'Consumo' OR m.contraparte = 'STEAMGAMES') LIMIT 1) m ON true
             JOIN public.categorias c ON c.id_categoria = m.id_categoria)),
        ('el recibo conciliado no suma en los totales',
            NOT EXISTS (SELECT 1 FROM public.v_movimientos_contables v
                        JOIN public.movimientos m USING (id_movimiento)
                        WHERE m.id_movimiento_vinculado IS NOT NULL)),
        ('el movimiento anulado no suma en los totales',
            NOT EXISTS (SELECT 1 FROM public.v_movimientos_contables v
                        JOIN public.movimientos m USING (id_movimiento) WHERE m.estado = 'anulado')),
        ('hay al menos un pago Sin categoría y dos correos Por revisar',
            EXISTS (SELECT 1 FROM public.movimientos WHERE numero_operacion LIKE 'DEMO-%' AND id_categoria IS NULL)
            AND (SELECT count(*) FROM public.correos_raw WHERE estado = 'por_revisar') = 2),
        ('ninguna fecha está en el futuro',
            NOT EXISTS (SELECT 1 FROM public.movimientos WHERE fecha > now()))
    ) AS t(prueba, ok)
    WHERE ok IS NOT TRUE;      -- NULL también cuenta como falla

    IF fallas IS NOT NULL THEN
        RAISE EXCEPTION 'Pruebas de la demo fallidas: %', fallas;
    END IF;
    RAISE NOTICE 'Datos demo cargados: 8/8 pruebas OK';
END
$$;

COMMIT;

-- =====================================================================
-- Vistazo rápido (solo lee)
-- =====================================================================
SELECT mes, ingresos, egresos, balance, cantidad FROM public.v_gasto_mensual ORDER BY mes;
SELECT categoria, limite, gastado, porcentaje, estado FROM public.v_avance_presupuesto ORDER BY porcentaje DESC;
SELECT estado, horas_sin_ejecucion, errores_24h, por_revisar, sin_categoria FROM public.v_salud_sistema;

-- Para borrar la demo (deja la configuración intacta):
--   DELETE FROM public.movimientos WHERE numero_operacion LIKE 'DEMO-%';
--   DELETE FROM public.correos_raw WHERE gmail_message_id LIKE 'demo-%';
--   DELETE FROM public.ejecuciones WHERE detalle LIKE '[DEMO]%';
