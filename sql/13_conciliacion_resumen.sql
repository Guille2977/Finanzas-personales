-- =====================================================================
-- 13_conciliacion_resumen.sql · Conciliación automática y resumen mensual
-- Requiere: 01 a 12. Idempotente (se puede correr varias veces).
-- Ojo: 12 quita y vuelve a dar TODOS los permisos de retool_panel; si
-- algún día vuelves a correr 12, corre 13 después.
--
-- A) CONCILIACIÓN: el mismo gasto llega dos veces (recibo de la app, p. ej.
--    Uber, y consumo del BCP). El recibo se vincula al cargo bancario con
--    movimientos.id_movimiento_vinculado (columna de sql/01) y las vistas
--    ya no lo suman. Cuenta el BANCO (es el dinero que realmente salió);
--    el recibo aporta la categoría si el cargo no la tiene.
--    Regla: mismo monto (± tolerancia), misma cuenta, misma moneda y
--    sentido, fechas a ± N horas. Solo se vincula si la pareja es ÚNICA
--    en los dos sentidos (1 recibo ↔ 1 cargo). Si hay más de un candidato,
--    NO se adivina: queda "por revisar" (tabla conciliacion_revision) y se
--    resuelve en Retool con fn_resolver_conciliacion. Prefiero no vincular
--    a vincular mal: un vínculo malo hace desaparecer un gasto real.
--    ¿Qué es un recibo? Un movimiento cuyo correo viene de una fuente con
--    fuentes.es_recibo = true (configuración, no código).
--
-- B) RESUMEN MENSUAL: el día 1 (desde la hora resumen_hora_envio) se
--    encola en la tabla alertas (sql/11) un aviso tipo 'resumen' del mes
--    anterior: ingresos, gastos, balance, gasto por categoría frente al
--    presupuesto. Lo envía el mismo Alertas.gs (patrón outbox), sin código
--    de envío nuevo. Clave 'resumen:2026-10' → uno por mes, aunque la
--    función corra cada 15 min.
--
-- Por qué en SQL y no en Apps Script: como fn_generar_alertas, la regla
-- vive en un solo lugar, se prueba aquí y Retool puede mostrar lo mismo.
-- Apps Script solo llama a las funciones (Alertas.gs, cada 15 min).
--
-- PostgreSQL vs SQL Server en este script:
--   · ALTER TABLE ... ADD COLUMN IF NOT EXISTS → en SQL Server:
--     IF COL_LENGTH('fuentes','es_recibo') IS NULL ALTER TABLE ... ADD.
--   · count(*) OVER (PARTITION BY ...) es igual en los dos.
--   · BIGINT[] (arreglo) no existe en SQL Server (se usaría una tabla
--     hija o un JSON). unnest(a, b) ≈ OPENJSON / STRING_SPLIT con orden.
--   · pg_advisory_xact_lock(n) ≈ sp_getapplock @LockOwner = 'Transaction':
--     un candado "con nombre" que se libera solo al terminar la transacción.
--   · ON CONFLICT ... DO UPDATE ... WHERE ≈ MERGE con condición extra.
--   · string_agg(x, E'\n' ORDER BY ...) ≈ STRING_AGG(x, CHAR(10))
--     WITHIN GROUP (ORDER BY ...).
--   · make_interval(hours => n) ≈ DATEADD(hour, n, ...).
--   · Parámetros con valor por defecto (p_mes DATE DEFAULT NULL): en una
--     función de SQL Server hay que escribir DEFAULT al llamarla; aquí se
--     omiten.
-- =====================================================================
BEGIN;

-- ---------------------------------------------------------------------
-- 1. Configuración
-- ---------------------------------------------------------------------
ALTER TABLE public.fuentes ADD COLUMN IF NOT EXISTS es_recibo BOOLEAN NOT NULL DEFAULT false;
COMMENT ON COLUMN public.fuentes.es_recibo IS
    'true = comprobante de una app (Uber, Rappi...) que duplica un cargo del banco: la conciliación lo vincula al cargo.';

INSERT INTO public.parametros (clave, valor, descripcion) VALUES
    ('conciliacion_activa',           'true',
     'false = la conciliación automática no vincula nada (fn_conciliar_movimientos no hace cambios).'),
    ('conciliacion_ventana_horas',    '24',
     'Recibo y cargo bancario se consideran el mismo gasto si sus fechas están a esta distancia como máximo (± horas).'),
    ('conciliacion_tolerancia_monto', '0.00',
     'Diferencia de monto aceptada (S/). 0 = monto exacto. Súbela si una app redondea o suma propina aparte.'),
    ('conciliacion_dias_atras',       '35',
     'Solo se buscan parejas para recibos de los últimos N días (la consulta no crece con los años).'),
    ('resumen_activo',                'true',
     'false = no se envía el resumen mensual automático (se puede generar a mano con fn_generar_resumen_mensual(''2026-10-01'')).'),
    ('resumen_hora_envio',            '8',
     'Hora de Lima desde la que se genera el resumen del mes anterior el día 1 (da tiempo a que lleguen los correos del día 31).'),
    ('resumen_dias_gracia',           '3',
     'Si el sistema estuvo caído el día 1, el resumen pendiente se genera hasta este día del mes; después se omite.')
ON CONFLICT (clave) DO NOTHING;   -- no pisa lo que el usuario ya cambió

-- Nuevo tipo de aviso. El CHECK de sql/11 se reemplaza (DROP + ADD en la
-- misma transacción: nunca queda la tabla sin validación).
ALTER TABLE public.alertas DROP CONSTRAINT IF EXISTS alertas_tipo_check;
ALTER TABLE public.alertas ADD CONSTRAINT alertas_tipo_check
    CHECK (tipo IN ('presupuesto', 'error_captura', 'sin_captura', 'resumen'));
ALTER TABLE public.alertas DROP CONSTRAINT IF EXISTS ck_alerta_resumen;
ALTER TABLE public.alertas ADD CONSTRAINT ck_alerta_resumen CHECK (tipo <> 'resumen' OR mes IS NOT NULL);

-- ---------------------------------------------------------------------
-- 2. Recibos "por revisar" (y decisiones tomadas a mano)
-- ---------------------------------------------------------------------
-- Una fila por recibo ambiguo. Pendiente = resuelta_en NULL.
-- Resultado 'no_es_el_mismo' = el usuario dijo que no es un duplicado:
-- ese recibo ya no se vuelve a proponer (la decisión humana manda).
CREATE TABLE IF NOT EXISTS public.conciliacion_revision (
    id_recibo        BIGINT      PRIMARY KEY REFERENCES public.movimientos (id_movimiento),
    candidatos       BIGINT[]    NOT NULL,          -- cargos posibles, el más cercano en el tiempo primero
    motivo           TEXT        NOT NULL,
    creada_en        TIMESTAMPTZ NOT NULL DEFAULT now(),
    resuelta_en      TIMESTAMPTZ,
    resultado        TEXT        CHECK (resultado IN ('vinculado', 'no_es_el_mismo')),
    id_banco_elegido BIGINT      REFERENCES public.movimientos (id_movimiento),
    CONSTRAINT ck_revision_resuelta CHECK ((resuelta_en IS NULL) = (resultado IS NULL)),
    CONSTRAINT ck_revision_elegido  CHECK (resultado IS DISTINCT FROM 'vinculado' OR id_banco_elegido IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS ix_revision_pendientes ON public.conciliacion_revision (creada_en) WHERE resuelta_en IS NULL;
COMMENT ON TABLE public.conciliacion_revision IS
    'Recibos con más de un cargo bancario posible (no se vinculan solos) y decisiones tomadas en Retool.';

-- ---------------------------------------------------------------------
-- 3. Parejas candidatas (recibo ↔ cargo bancario). La usan la función y
--    Retool, así los dos ven exactamente la misma regla.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_conciliacion_candidatos
WITH (security_invoker = true) AS
WITH p AS (   -- parámetros (una fila; si falta alguno, valor por defecto)
    SELECT make_interval(hours => COALESCE(max(valor) FILTER (WHERE clave = 'conciliacion_ventana_horas'), '24')::int) AS ventana,
           COALESCE(max(valor) FILTER (WHERE clave = 'conciliacion_tolerancia_monto'), '0')::numeric               AS tolerancia,
           now() - make_interval(days => COALESCE(max(valor) FILTER (WHERE clave = 'conciliacion_dias_atras'), '35')::int) AS desde
    FROM public.parametros
),
origen AS (   -- cada movimiento de correo con el tipo de su fuente
    SELECT m.*, f.es_recibo
    FROM public.movimientos m
    JOIN public.correos_raw c ON c.id_correo = m.id_correo
    JOIN public.fuentes f     ON f.id_fuente = c.id_fuente     -- sin fuente conocida: no participa
    WHERE m.estado = 'activo'
      AND m.id_movimiento_vinculado IS NULL                    -- todavía no vinculado
),
recibos AS (
    SELECT o.* FROM origen o, p
    WHERE o.es_recibo
      AND o.fecha >= p.desde
      AND NOT EXISTS (SELECT 1 FROM public.conciliacion_revision r      -- el usuario dijo "no es el mismo"
                      WHERE r.id_recibo = o.id_movimiento AND r.resultado = 'no_es_el_mismo')
),
cargos AS (
    SELECT o.* FROM origen o, p
    WHERE NOT o.es_recibo
      AND o.fecha >= p.desde - p.ventana
      AND NOT EXISTS (SELECT 1 FROM public.movimientos x                 -- un cargo, un solo recibo
                      WHERE x.id_movimiento_vinculado = o.id_movimiento AND x.estado = 'activo')
)
SELECT r.id_movimiento                                AS id_recibo,
       b.id_movimiento                                AS id_banco,
       r.id_cuenta, r.moneda, r.sentido,
       r.monto                                        AS monto_recibo,
       b.monto                                        AS monto_banco,
       r.fecha                                        AS fecha_recibo,
       b.fecha                                        AS fecha_banco,
       abs(EXTRACT(EPOCH FROM b.fecha - r.fecha)) / 60 AS minutos_de_diferencia,
       r.contraparte                                  AS contraparte_recibo,
       b.contraparte                                  AS contraparte_banco,
       count(*) OVER (PARTITION BY r.id_movimiento)   AS cargos_posibles,    -- del recibo
       count(*) OVER (PARTITION BY b.id_movimiento)   AS recibos_posibles    -- del cargo
FROM recibos r
CROSS JOIN p
JOIN cargos b ON b.id_cuenta = r.id_cuenta
             AND b.moneda    = r.moneda
             AND b.sentido   = r.sentido
             AND abs(b.monto - r.monto) <= p.tolerancia
             AND b.fecha BETWEEN r.fecha - p.ventana AND r.fecha + p.ventana;
COMMENT ON VIEW public.v_conciliacion_candidatos IS
    'Parejas recibo ↔ cargo bancario según la regla de conciliación. Única en ambos sentidos = se vincula sola.';

-- ---------------------------------------------------------------------
-- 4. fn_conciliar_movimientos(): vincula lo seguro, deja por revisar lo
--    ambiguo. Devuelve un resumen en JSON. Idempotente.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_conciliar_movimientos()
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SET search_path = ''
AS $$
DECLARE
    v_recibos       BIGINT[];
    v_cargos        BIGINT[];
    v_vinculados    INT := 0;
    v_desvinculados INT := 0;
    v_pendientes    INT;
BEGIN
    IF COALESCE((SELECT lower(btrim(valor)) FROM public.parametros WHERE clave = 'conciliacion_activa'), 'true') <> 'true' THEN
        RETURN jsonb_build_object('activa', false);
    END IF;

    -- Dos corridas a la vez (activador + prueba manual) no deben vincular
    -- el mismo cargo a dos recibos: la segunda espera a que termine la primera.
    PERFORM pg_advisory_xact_lock(hashtext('fn_conciliar_movimientos'));

    -- 4.1 Si el cargo bancario se anuló, el recibo vuelve a contar (si no,
    --     el gasto desaparecería de los totales: ni cargo ni recibo).
    WITH sueltos AS (
        UPDATE public.movimientos r
        SET id_movimiento_vinculado = NULL
        FROM public.movimientos b
        WHERE r.id_movimiento_vinculado = b.id_movimiento
          AND b.estado = 'anulado'
          AND r.estado = 'activo'
        RETURNING r.id_movimiento
    ),
    decision_vieja AS (                               -- su decisión "vinculado" ya no aplica
        DELETE FROM public.conciliacion_revision cr
        USING sueltos s
        WHERE cr.id_recibo = s.id_movimiento AND cr.resultado = 'vinculado'
    )
    SELECT count(*) INTO v_desvinculados FROM sueltos;   -- (≈ OUTPUT ... INTO @tabla y luego COUNT)

    -- 4.2 Parejas únicas en los dos sentidos → se vinculan.
    SELECT COALESCE(array_agg(id_recibo ORDER BY id_recibo), '{}'),
           COALESCE(array_agg(id_banco  ORDER BY id_recibo), '{}')
      INTO v_recibos, v_cargos
    FROM public.v_conciliacion_candidatos
    WHERE cargos_posibles = 1 AND recibos_posibles = 1;

    UPDATE public.movimientos r
    SET id_movimiento_vinculado = x.id_banco
    FROM unnest(v_recibos, v_cargos) AS x(id_recibo, id_banco)
    WHERE r.id_movimiento = x.id_recibo
      AND r.id_movimiento_vinculado IS NULL;
    GET DIAGNOSTICS v_vinculados = ROW_COUNT;

    -- El recibo sabe en qué se gastó (Uber → Transporte); el banco a veces
    -- no (PAGSEGURO, IZI*...). Solo se completa si el cargo no tiene
    -- categoría: nunca se pisa una corrección hecha a mano.
    UPDATE public.movimientos b
    SET id_categoria = r.id_categoria
    FROM unnest(v_recibos, v_cargos) AS x(id_recibo, id_banco)
    JOIN public.movimientos r ON r.id_movimiento = x.id_recibo
    WHERE b.id_movimiento = x.id_banco
      AND b.id_categoria IS NULL
      AND r.id_categoria IS NOT NULL;

    -- 4.3 Ambiguos → por revisar (o se actualizan sus candidatos).
    INSERT INTO public.conciliacion_revision (id_recibo, candidatos, motivo)
    SELECT id_recibo,
           array_agg(id_banco ORDER BY minutos_de_diferencia, id_banco),
           CASE WHEN max(cargos_posibles) > 1
                THEN format('%s cargos bancarios posibles con el mismo monto', max(cargos_posibles))
                ELSE 'El cargo bancario también calza con otro recibo' END
    FROM public.v_conciliacion_candidatos
    WHERE NOT (cargos_posibles = 1 AND recibos_posibles = 1)
    GROUP BY id_recibo
    ON CONFLICT (id_recibo) DO UPDATE
        SET candidatos = EXCLUDED.candidatos, motivo = EXCLUDED.motivo
        WHERE conciliacion_revision.resuelta_en IS NULL
          AND conciliacion_revision.candidatos IS DISTINCT FROM EXCLUDED.candidatos;

    -- 4.4 Pendientes que ya no son ambiguos (se vincularon, o su cargo se
    --     anuló) salen de la lista. Las decisiones resueltas se conservan.
    DELETE FROM public.conciliacion_revision cr
    WHERE cr.resuelta_en IS NULL
      AND NOT EXISTS (SELECT 1 FROM public.v_conciliacion_candidatos v
                      WHERE v.id_recibo = cr.id_recibo
                        AND NOT (v.cargos_posibles = 1 AND v.recibos_posibles = 1));

    SELECT count(*) INTO v_pendientes FROM public.conciliacion_revision WHERE resuelta_en IS NULL;
    RETURN jsonb_build_object('activa', true, 'vinculados', v_vinculados,
                              'desvinculados', v_desvinculados, 'por_revisar', v_pendientes);
END;
$$;
COMMENT ON FUNCTION public.fn_conciliar_movimientos() IS
    'Vincula recibo ↔ cargo bancario cuando la pareja es única; lo ambiguo va a conciliacion_revision. Idempotente.';

-- ---------------------------------------------------------------------
-- 5. fn_resolver_conciliacion(recibo, cargo): decisión manual desde Retool.
--    p_id_banco = un cargo → se vinculan.
--    p_id_banco = NULL     → "no es el mismo gasto": se desvincula (si lo
--                            estaba) y no se vuelve a proponer.
--    SECURITY DEFINER (como fn_resolver_por_revisar en 12): Retool no
--    necesita UPDATE sobre id_movimiento_vinculado; solo puede hacer esto.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_resolver_conciliacion(p_id_recibo BIGINT, p_id_banco BIGINT DEFAULT NULL)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_r public.movimientos%ROWTYPE;
    v_b public.movimientos%ROWTYPE;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('fn_conciliar_movimientos'));   -- mismo candado que la automática

    SELECT * INTO v_r FROM public.movimientos WHERE id_movimiento = p_id_recibo FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el movimiento %', p_id_recibo;
    END IF;

    IF p_id_banco IS NULL THEN
        UPDATE public.movimientos SET id_movimiento_vinculado = NULL WHERE id_movimiento = p_id_recibo;
        INSERT INTO public.conciliacion_revision (id_recibo, candidatos, motivo, resuelta_en, resultado)
        VALUES (p_id_recibo, '{}', 'Marcado a mano: no es el mismo gasto', now(), 'no_es_el_mismo')
        ON CONFLICT (id_recibo) DO UPDATE
            SET resuelta_en = now(), resultado = 'no_es_el_mismo', id_banco_elegido = NULL;
        RETURN 'no_es_el_mismo';
    END IF;

    -- Idempotente: doble clic → mismo resultado, sin error.
    IF v_r.id_movimiento_vinculado = p_id_banco THEN
        RETURN 'vinculado';
    END IF;

    SELECT * INTO v_b FROM public.movimientos WHERE id_movimiento = p_id_banco FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el movimiento %', p_id_banco;
    ELSIF p_id_banco = p_id_recibo THEN
        RAISE EXCEPTION 'Un movimiento no se vincula consigo mismo';
    ELSIF v_r.estado <> 'activo' OR v_b.estado <> 'activo' THEN
        RAISE EXCEPTION 'Los dos movimientos deben estar activos';
    ELSIF v_r.id_movimiento_vinculado IS NOT NULL THEN
        RAISE EXCEPTION 'El recibo % ya está vinculado a %; primero desvincúlalo (p_id_banco = NULL)',
            p_id_recibo, v_r.id_movimiento_vinculado;
    ELSIF v_b.id_movimiento_vinculado IS NOT NULL THEN
        RAISE EXCEPTION 'El movimiento % es a su vez un recibo vinculado; elige el cargo bancario', p_id_banco;
    ELSIF EXISTS (SELECT 1 FROM public.movimientos WHERE id_movimiento_vinculado = p_id_banco AND estado = 'activo') THEN
        RAISE EXCEPTION 'El cargo % ya tiene un recibo vinculado', p_id_banco;
    ELSIF v_r.moneda <> v_b.moneda OR v_r.sentido <> v_b.sentido THEN
        RAISE EXCEPTION 'Moneda o sentido distintos: no pueden ser el mismo gasto';
    END IF;

    UPDATE public.movimientos SET id_movimiento_vinculado = p_id_banco WHERE id_movimiento = p_id_recibo;
    UPDATE public.movimientos SET id_categoria = v_r.id_categoria
    WHERE id_movimiento = p_id_banco AND id_categoria IS NULL AND v_r.id_categoria IS NOT NULL;

    INSERT INTO public.conciliacion_revision (id_recibo, candidatos, motivo, resuelta_en, resultado, id_banco_elegido)
    VALUES (p_id_recibo, ARRAY[p_id_banco], 'Vinculado a mano', now(), 'vinculado', p_id_banco)
    ON CONFLICT (id_recibo) DO UPDATE
        SET resuelta_en = now(), resultado = 'vinculado', id_banco_elegido = p_id_banco;
    RETURN 'vinculado';
END;
$$;
COMMENT ON FUNCTION public.fn_resolver_conciliacion(BIGINT, BIGINT) IS
    'Retool: vincula un recibo a un cargo (o con NULL lo marca "no es el mismo gasto"). Idempotente.';

-- Para la pantalla de Retool: cada recibo pendiente con sus cargos posibles.
CREATE OR REPLACE VIEW public.v_conciliacion_por_revisar
WITH (security_invoker = true) AS
SELECT cr.id_recibo,
       (r.fecha AT TIME ZONE 'America/Lima')  AS fecha_recibo,
       r.monto, r.moneda, r.contraparte, r.descripcion,
       cu.alias                               AS cuenta,
       cr.motivo,
       cr.creada_en,
       jsonb_agg(jsonb_build_object(
           'id_banco',    b.id_movimiento,
           'fecha',       to_char(b.fecha AT TIME ZONE 'America/Lima', 'DD/MM HH24:MI'),
           'monto',       b.monto,
           'contraparte', b.contraparte,
           'descripcion', b.descripcion) ORDER BY k.orden) AS candidatos
FROM public.conciliacion_revision cr
JOIN public.movimientos r ON r.id_movimiento = cr.id_recibo
JOIN public.cuentas cu    ON cu.id_cuenta    = r.id_cuenta
CROSS JOIN LATERAL unnest(cr.candidatos) WITH ORDINALITY AS k(id_banco, orden)   -- ≈ OPENJSON con [key]
JOIN public.movimientos b ON b.id_movimiento = k.id_banco
WHERE cr.resuelta_en IS NULL
GROUP BY cr.id_recibo, r.fecha, r.monto, r.moneda, r.contraparte, r.descripcion, cu.alias, cr.motivo, cr.creada_en;

-- ---------------------------------------------------------------------
-- 6. fn_generar_resumen_mensual(): encola el resumen del mes en alertas.
--    p_mes NULL  → automático: mes anterior, solo el día 1 desde la hora
--                  configurada (o hasta resumen_dias_gracia si se perdió).
--    p_mes fecha → ese mes, a mano (sin mirar día ni hora). Ej.:
--                  SELECT fn_generar_resumen_mensual('2026-10-01');
--    p_ahora     → "reloj" inyectable: las pruebas simulan el día 1 a las
--                  9:00 sin esperar al día 1. En uso normal, se omite.
--    Devuelve 1 si encoló un resumen nuevo, 0 si no (ya existía o no toca).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_generar_resumen_mensual(p_mes DATE DEFAULT NULL, p_ahora TIMESTAMPTZ DEFAULT now())
RETURNS INT
LANGUAGE plpgsql
VOLATILE
SET search_path = ''
AS $$
DECLARE
    v_lima      TIMESTAMP := p_ahora AT TIME ZONE 'America/Lima';
    v_meses     TEXT[] := ARRAY['enero','febrero','marzo','abril','mayo','junio','julio',
                                'agosto','septiembre','octubre','noviembre','diciembre'];
    v_mes       DATE;
    v_clave     TEXT;
    v_ing       NUMERIC := 0;
    v_egr       NUMERIC := 0;
    v_cant      INT     := 0;
    v_egr_ant   NUMERIC;
    v_naranja   INT;
    v_lineas    TEXT;
    v_cumplidos INT;
    v_con_ppto  INT;
    v_mayor     TEXT;
    v_usd       NUMERIC;
    v_pend_conc INT;
    v_msg       TEXT;
    v_n         INT;
BEGIN
    IF p_mes IS NULL THEN
        IF COALESCE((SELECT lower(btrim(valor)) FROM public.parametros WHERE clave = 'resumen_activo'), 'true') <> 'true' THEN
            RETURN 0;
        END IF;
        -- Día 1 antes de la hora → aún no. Después del día de gracia → ya no.
        IF EXTRACT(DAY FROM v_lima) > COALESCE((SELECT valor::int FROM public.parametros WHERE clave = 'resumen_dias_gracia'), 3)
           OR (EXTRACT(DAY FROM v_lima) = 1
               AND EXTRACT(HOUR FROM v_lima) < COALESCE((SELECT valor::int FROM public.parametros WHERE clave = 'resumen_hora_envio'), 8)) THEN
            RETURN 0;
        END IF;
        v_mes := (date_trunc('month', v_lima) - INTERVAL '1 month')::date;
    ELSE
        v_mes := date_trunc('month', p_mes)::date;
    END IF;

    v_clave := 'resumen:' || to_char(v_mes, 'YYYY-MM');
    IF EXISTS (SELECT 1 FROM public.alertas WHERE clave = v_clave) THEN
        RETURN 0;   -- ya se generó: no se arma el mensaje de nuevo
    END IF;

    -- Totales del mes (PEN). v_gasto_mensual ya excluye anulados, recibos
    -- conciliados y transferencias entre cuentas propias (sql/01).
    SELECT ingresos, egresos, cantidad INTO v_ing, v_egr, v_cant
    FROM public.v_gasto_mensual WHERE mes = v_mes AND moneda = 'PEN';
    v_ing := COALESCE(v_ing, 0); v_egr := COALESCE(v_egr, 0); v_cant := COALESCE(v_cant, 0);

    -- Automático y sin movimientos (base recién instalada) → no avisa.
    IF p_mes IS NULL AND v_cant = 0 THEN
        RETURN 0;
    END IF;

    SELECT egresos INTO v_egr_ant
    FROM public.v_gasto_mensual WHERE mes = (v_mes - INTERVAL '1 month')::date AND moneda = 'PEN';

    -- Umbral "naranja" = el menor umbral activo bajo 100 (sql/11), por defecto 80.
    SELECT COALESCE(min(porcentaje) FILTER (WHERE porcentaje < 100), 80) INTO v_naranja
    FROM public.umbrales_presupuesto WHERE activo;

    -- Gasto por categoría frente al presupuesto VIGENTE en ese mes (no el
    -- de hoy: si subiste el límite en diciembre, octubre se compara con el
    -- de octubre). Incluye categorías con presupuesto y gasto 0.
    WITH vigente AS (
        SELECT DISTINCT ON (p.id_categoria) p.id_categoria, p.monto_mensual
        FROM public.presupuestos p
        WHERE p.vigente_desde <= v_mes
        ORDER BY p.id_categoria, p.vigente_desde DESC
    ),
    gasto AS (
        SELECT g.categoria, g.total, g.cantidad
        FROM public.v_gasto_categoria_mes g
        WHERE g.mes = v_mes AND g.moneda = 'PEN' AND g.sentido = 'egreso'
    ),
    filas AS (
        SELECT COALESCE(c.nombre, g.categoria)                       AS categoria,
               COALESCE(ci.icono, CASE WHEN g.categoria = 'Sin categoría' THEN '❓' ELSE '•' END) AS icono,
               COALESCE(g.total, 0)                                  AS total,
               g.cantidad,
               v.monto_mensual                                       AS limite
        FROM gasto g
        -- FULL JOIN: categorías con gasto y sin presupuesto, y con presupuesto y sin gasto.
        FULL JOIN (vigente v JOIN public.categorias c ON c.id_categoria = v.id_categoria AND c.activo)
               ON c.nombre = g.categoria
        LEFT JOIN public.categorias ci ON ci.nombre = COALESCE(c.nombre, g.categoria)   -- solo el ícono
    )
    SELECT string_agg(
               format('%s %s: S/ %s', icono, categoria, to_char(total, 'FM999,999,990.00'))
               || CASE WHEN limite IS NULL THEN ''
                       ELSE format(' de %s (%s %%)%s', to_char(limite, 'FM999,999,990.00'), round(100 * total / limite),
                                   CASE WHEN total >= limite                   THEN ' 🔴'
                                        WHEN total >= limite * v_naranja / 100.0 THEN ' 🟠'
                                        ELSE '' END) END
               || CASE WHEN categoria = 'Sin categoría' THEN format(' en %s mov. → clasifícalos en Retool', cantidad) ELSE '' END,
               E'\n' ORDER BY (categoria = 'Sin categoría'), total DESC, categoria),
           count(*) FILTER (WHERE limite IS NOT NULL AND total <= limite),
           count(*) FILTER (WHERE limite IS NOT NULL)
      INTO v_lineas, v_cumplidos, v_con_ppto
    FROM filas;

    -- El gasto individual más grande (sin transferencias).
    SELECT format('S/ %s · %s (%s)', to_char(monto, 'FM999,999,990.00'),
                  COALESCE(contraparte, descripcion, categoria), to_char(dia, 'DD/MM'))
      INTO v_mayor
    FROM public.v_movimientos_contables
    WHERE mes = v_mes AND moneda = 'PEN' AND sentido = 'egreso' AND NOT es_transferencia
    ORDER BY monto DESC, id_movimiento
    LIMIT 1;

    SELECT sum(monto) INTO v_usd
    FROM public.v_movimientos_contables
    WHERE mes = v_mes AND moneda = 'USD' AND sentido = 'egreso' AND NOT es_transferencia;

    SELECT count(*) INTO v_pend_conc FROM public.conciliacion_revision WHERE resuelta_en IS NULL;

    -- concat_ws ignora los NULL: una línea que no aplica simplemente no sale.
    v_msg := concat_ws(E'\n',
        format('📊 Resumen de %s %s', v_meses[EXTRACT(MONTH FROM v_mes)], EXTRACT(YEAR FROM v_mes)),
        format('Ingresos: S/ %s · Gastos: S/ %s', to_char(v_ing, 'FM999,999,990.00'), to_char(v_egr, 'FM999,999,990.00')),
        format('Balance: %sS/ %s', CASE WHEN v_ing - v_egr < 0 THEN '-' ELSE '+' END, to_char(abs(v_ing - v_egr), 'FM999,999,990.00')),
        CASE WHEN v_egr_ant > 0 THEN
            format('Gastos vs %s: %s%s %%', v_meses[EXTRACT(MONTH FROM v_mes - INTERVAL '1 month')],
                   CASE WHEN v_egr >= v_egr_ant THEN '▲ +' ELSE '▼ ' END, round(100 * (v_egr - v_egr_ant) / v_egr_ant))
        END,
        CASE WHEN v_usd > 0 THEN format('Además, gastos en dólares: US$ %s', to_char(v_usd, 'FM999,999,990.00')) END,
        '',
        CASE WHEN v_lineas IS NOT NULL THEN E'Gastos por categoría:\n' || v_lineas ELSE 'Sin gastos registrados.' END,
        CASE WHEN v_con_ppto > 0 THEN format('✅ Presupuestos cumplidos: %s de %s', v_cumplidos, v_con_ppto) END,
        CASE WHEN v_mayor IS NOT NULL THEN 'Mayor gasto: ' || v_mayor END,
        CASE WHEN v_pend_conc > 0 THEN format('🔗 %s recibo(s) por conciliar en Retool', v_pend_conc) END
    );

    INSERT INTO public.alertas (tipo, clave, mensaje, mes)
    VALUES ('resumen', v_clave, left(v_msg, 4000), v_mes)    -- Telegram acepta hasta 4096 caracteres
    ON CONFLICT (clave) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$$;
COMMENT ON FUNCTION public.fn_generar_resumen_mensual(DATE, TIMESTAMPTZ) IS
    'Encola en alertas el resumen del mes (por defecto, el anterior el día 1). Uno por mes (clave resumen:YYYY-MM).';

-- ---------------------------------------------------------------------
-- 7. Seguridad (mismo esquema que 11 y 12)
-- ---------------------------------------------------------------------
ALTER TABLE public.conciliacion_revision ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON FUNCTION public.fn_conciliar_movimientos()                        FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_resolver_conciliacion(BIGINT, BIGINT)          FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_generar_resumen_mensual(DATE, TIMESTAMPTZ)     FROM PUBLIC;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN   -- Apps Script
        GRANT SELECT, INSERT, UPDATE, DELETE ON public.conciliacion_revision TO service_role;
        GRANT SELECT ON public.v_conciliacion_candidatos, public.v_conciliacion_por_revisar TO service_role;
        GRANT EXECUTE ON FUNCTION public.fn_conciliar_movimientos(),
                                  public.fn_generar_resumen_mensual(DATE, TIMESTAMPTZ) TO service_role;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON public.conciliacion_revision, public.v_conciliacion_candidatos, public.v_conciliacion_por_revisar
            FROM anon, authenticated;
        REVOKE ALL ON FUNCTION public.fn_conciliar_movimientos(), public.fn_resolver_conciliacion(BIGINT, BIGINT),
                               public.fn_generar_resumen_mensual(DATE, TIMESTAMPTZ) FROM anon, authenticated;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'retool_panel') THEN   -- panel (sql/12)
        GRANT SELECT ON public.conciliacion_revision, public.v_conciliacion_candidatos,
                        public.v_conciliacion_por_revisar TO retool_panel;
        GRANT INSERT (es_recibo), UPDATE (es_recibo) ON public.fuentes TO retool_panel;
        GRANT EXECUTE ON FUNCTION public.fn_resolver_conciliacion(BIGINT, BIGINT) TO retool_panel;
        DROP POLICY IF EXISTS retool_panel_acceso ON public.conciliacion_revision;
        CREATE POLICY retool_panel_acceso ON public.conciliacion_revision FOR SELECT TO retool_panel USING (true);
    END IF;
END
$$;

COMMIT;

-- =====================================================================
-- Pruebas. Igual que 11: crean datos de prueba (cuentas, fuente y
-- categorías "zz prueba"), revisan y DESHACEN todo con un savepoint
-- (error propio PZ001). Corren también en la base real sin dejar rastro.
-- Las fechas del resumen son de 2031 para no mezclarse con datos reales.
-- =====================================================================
-- Ayudante: crea un correo + su movimiento (egreso). pg_temp = solo vive
-- en esta sesión (≈ un procedimiento #temporal de SQL Server).
CREATE OR REPLACE FUNCTION pg_temp.zz_mov(p_fuente TEXT, p_cuenta INT, p_monto NUMERIC,
                                          p_fecha TIMESTAMPTZ, p_categoria INT DEFAULT NULL)
RETURNS BIGINT LANGUAGE sql AS $$
    WITH c AS (
        INSERT INTO public.correos_raw (gmail_message_id, remitente, fecha_correo, id_fuente, estado)
        SELECT 'zz-prueba-13-' || gen_random_uuid(), 'prueba@zz', p_fecha, f.id_fuente, 'procesado'
        FROM public.fuentes f WHERE f.nombre = p_fuente
        RETURNING id_correo
    )
    INSERT INTO public.movimientos (fecha, monto, sentido, id_cuenta, id_categoria, origen, id_correo, contraparte)
    SELECT p_fecha, p_monto, 'egreso', p_cuenta, p_categoria, 'correo', c.id_correo, p_fuente
    FROM c
    RETURNING id_movimiento;
$$;

DO $$
DECLARE
    v_c1 INT; v_c2 INT; v_cat INT; v_a INT; v_b INT; v_ef INT;
    r1 BIGINT; b1 BIGINT; r2 BIGINT; b2 BIGINT; r3 BIGINT; b3 BIGINT; r4 BIGINT; b4 BIGINT;
    r5 BIGINT; b5a BIGINT; b5b BIGINT; r6a BIGINT; r6b BIGINT; b6 BIGINT; r7 BIGINT; b7 BIGINT;
    t        TIMESTAMPTZ := date_trunc('minute', now()) - INTERVAL '2 days';
    v_j      JSONB;
    v_msg    TEXT;
    v_fallas TEXT := '';
    v_total  INT  := 0;
    v_res    TEXT;
    BANCO    CONSTANT TEXT := 'BCP · Consumo tarjeta de débito';
    RECIBO   CONSTANT TEXT := 'zz prueba recibo';
BEGIN
    BEGIN
        -- Configuración conocida (por si en la base real la cambiaste).
        UPDATE public.parametros SET valor = CASE clave
            WHEN 'conciliacion_activa' THEN 'true'  WHEN 'conciliacion_ventana_horas' THEN '24'
            WHEN 'conciliacion_tolerancia_monto' THEN '0.00' WHEN 'conciliacion_dias_atras' THEN '35'
            WHEN 'resumen_activo' THEN 'true' WHEN 'resumen_hora_envio' THEN '8' WHEN 'resumen_dias_gracia' THEN '3' END
        WHERE clave LIKE 'conciliacion\_%' OR clave LIKE 'resumen\_%';
        INSERT INTO public.cuentas (id_entidad, tipo, alias)
        SELECT id_entidad, 'debito', 'zz prueba débito' FROM public.entidades WHERE nombre = 'BCP' RETURNING id_cuenta INTO v_c1;
        INSERT INTO public.cuentas (id_entidad, tipo, alias)
        SELECT id_entidad, 'credito', 'zz prueba crédito' FROM public.entidades WHERE nombre = 'BCP' RETURNING id_cuenta INTO v_c2;
        INSERT INTO public.fuentes (nombre, remitente_patron, accion, extractor, es_recibo)
        VALUES (RECIBO, 'zz@prueba', 'procesar', 'generico', true);
        INSERT INTO public.categorias (nombre, tipo) VALUES ('zz prueba conc', 'egreso') RETURNING id_categoria INTO v_cat;

        -- ================= CONCILIACIÓN =================
        -- C1: pareja única (mismo monto y cuenta, 3 min) → se vincula y el
        --     cargo sin categoría toma la del recibo.
        b1 := pg_temp.zz_mov(BANCO,  v_c1, 25.40, t);
        r1 := pg_temp.zz_mov(RECIBO, v_c1, 25.40, t + INTERVAL '3 minutes', v_cat);
        v_j := public.fn_conciliar_movimientos();
        v_total := v_total + 1;
        IF (SELECT id_movimiento_vinculado FROM public.movimientos WHERE id_movimiento = r1) IS DISTINCT FROM b1
           OR (SELECT id_categoria FROM public.movimientos WHERE id_movimiento = b1) IS DISTINCT FROM v_cat THEN
            v_fallas := v_fallas || 'C1 pareja única se vincula; ';
        END IF;

        -- C2: idempotente: otra corrida no vincula nada nuevo.
        v_j := public.fn_conciliar_movimientos();
        v_total := v_total + 1;
        IF (v_j->>'vinculados')::int <> 0
           OR (SELECT id_movimiento_vinculado FROM public.movimientos WHERE id_movimiento = r1) IS DISTINCT FROM b1 THEN
            v_fallas := v_fallas || 'C2 idempotente; ';
        END IF;

        -- C3: el gasto cuenta UNA vez en los totales (el cargo, no el recibo).
        v_total := v_total + 1;
        IF (SELECT array_agg(id_movimiento) FROM public.v_movimientos_contables WHERE id_movimiento IN (r1, b1)) IS DISTINCT FROM ARRAY[b1] THEN
            v_fallas := v_fallas || 'C3 cuenta una vez; ';
        END IF;

        -- C4: monto distinto / fuera de la ventana (30 h) / otra cuenta → nada.
        r2 := pg_temp.zz_mov(RECIBO, v_c1, 30.00, t);  b2 := pg_temp.zz_mov(BANCO, v_c1, 30.10, t);
        r3 := pg_temp.zz_mov(RECIBO, v_c1, 41.00, t);  b3 := pg_temp.zz_mov(BANCO, v_c1, 41.00, t + INTERVAL '30 hours');
        r4 := pg_temp.zz_mov(RECIBO, v_c1, 52.00, t);  b4 := pg_temp.zz_mov(BANCO, v_c2, 52.00, t);
        PERFORM public.fn_conciliar_movimientos();
        v_total := v_total + 1;
        IF EXISTS (SELECT 1 FROM public.movimientos WHERE id_movimiento IN (r2, r3, r4) AND id_movimiento_vinculado IS NOT NULL)
           OR EXISTS (SELECT 1 FROM public.conciliacion_revision WHERE id_recibo IN (r2, r3, r4)) THEN
            v_fallas := v_fallas || 'C4 monto/ventana/cuenta distintos no se vinculan; ';
        END IF;

        -- C5: la tolerancia es configuración: con 0.10, 30.00 ↔ 30.10 sí.
        UPDATE public.parametros SET valor = '0.10' WHERE clave = 'conciliacion_tolerancia_monto';
        PERFORM public.fn_conciliar_movimientos();
        UPDATE public.parametros SET valor = '0.00' WHERE clave = 'conciliacion_tolerancia_monto';
        v_total := v_total + 1;
        IF (SELECT id_movimiento_vinculado FROM public.movimientos WHERE id_movimiento = r2) IS DISTINCT FROM b2 THEN
            v_fallas := v_fallas || 'C5 tolerancia configurable; ';
        END IF;

        -- C6: dos cargos posibles → NO se adivina: por revisar, el más cercano primero.
        r5  := pg_temp.zz_mov(RECIBO, v_c1, 63.00, t);
        b5a := pg_temp.zz_mov(BANCO,  v_c1, 63.00, t + INTERVAL '1 hour');
        b5b := pg_temp.zz_mov(BANCO,  v_c1, 63.00, t + INTERVAL '5 hours');
        -- C7: un cargo y dos recibos → los dos por revisar.
        r6a := pg_temp.zz_mov(RECIBO, v_c1, 74.00, t);
        r6b := pg_temp.zz_mov(RECIBO, v_c1, 74.00, t + INTERVAL '10 minutes');
        b6  := pg_temp.zz_mov(BANCO,  v_c1, 74.00, t + INTERVAL '5 minutes');
        v_j := public.fn_conciliar_movimientos();
        v_total := v_total + 1;
        IF (SELECT id_movimiento_vinculado FROM public.movimientos WHERE id_movimiento = r5) IS NOT NULL
           OR (SELECT candidatos FROM public.conciliacion_revision WHERE id_recibo = r5 AND resuelta_en IS NULL) IS DISTINCT FROM ARRAY[b5a, b5b] THEN
            v_fallas := v_fallas || 'C6 ambiguo va a revisión; ';
        END IF;
        v_total := v_total + 1;
        IF (SELECT count(*) FROM public.conciliacion_revision
            WHERE id_recibo IN (r6a, r6b) AND resuelta_en IS NULL AND motivo LIKE '%otro recibo%') <> 2
           OR EXISTS (SELECT 1 FROM public.movimientos WHERE id_movimiento IN (r6a, r6b) AND id_movimiento_vinculado IS NOT NULL) THEN
            v_fallas := v_fallas || 'C7 un cargo dos recibos; ';
        END IF;

        -- C8: la vista de Retool muestra el recibo con sus 2 candidatos.
        v_total := v_total + 1;
        IF (SELECT jsonb_array_length(candidatos) FROM public.v_conciliacion_por_revisar WHERE id_recibo = r5) IS DISTINCT FROM 2 THEN
            v_fallas := v_fallas || 'C8 vista por revisar; ';
        END IF;

        -- C9: decisión manual (Retool) → vinculado; la automática la respeta.
        PERFORM public.fn_resolver_conciliacion(r5, b5b);
        PERFORM public.fn_resolver_conciliacion(r5, b5b);           -- doble clic: sin error
        PERFORM public.fn_conciliar_movimientos();
        v_total := v_total + 1;
        IF (SELECT id_movimiento_vinculado FROM public.movimientos WHERE id_movimiento = r5) IS DISTINCT FROM b5b
           OR (SELECT resultado FROM public.conciliacion_revision WHERE id_recibo = r5) IS DISTINCT FROM 'vinculado' THEN
            v_fallas := v_fallas || 'C9 resolver a mano; ';
        END IF;

        -- C10: un cargo que ya tiene recibo no acepta otro.
        v_total := v_total + 1;
        BEGIN
            PERFORM public.fn_resolver_conciliacion(r6a, b5b);
            v_fallas := v_fallas || 'C10 cargo ocupado debía fallar; ';
        EXCEPTION WHEN raise_exception THEN NULL;   -- esperado
        END;

        -- C11: "no es el mismo" (r6a) → no se vuelve a proponer, y r6b queda
        --      como pareja única de b6 → se vincula sola y sale de revisión.
        PERFORM public.fn_resolver_conciliacion(r6a, NULL);
        PERFORM public.fn_conciliar_movimientos();
        v_total := v_total + 1;
        IF (SELECT id_movimiento_vinculado FROM public.movimientos WHERE id_movimiento = r6a) IS NOT NULL
           OR (SELECT id_movimiento_vinculado FROM public.movimientos WHERE id_movimiento = r6b) IS DISTINCT FROM b6
           OR EXISTS (SELECT 1 FROM public.conciliacion_revision WHERE id_recibo = r6b) THEN
            v_fallas := v_fallas || 'C11 no es el mismo + ambigüedad resuelta; ';
        END IF;

        -- C12: si se anula el cargo, el recibo se desvincula y vuelve a contar.
        UPDATE public.movimientos SET estado = 'anulado' WHERE id_movimiento = b1;
        v_j := public.fn_conciliar_movimientos();
        v_total := v_total + 1;
        IF (v_j->>'desvinculados')::int < 1
           OR NOT EXISTS (SELECT 1 FROM public.v_movimientos_contables WHERE id_movimiento = r1) THEN
            v_fallas := v_fallas || 'C12 cargo anulado desvincula; ';
        END IF;

        -- C13: conciliacion_activa = false → no toca nada.
        UPDATE public.parametros SET valor = 'false' WHERE clave = 'conciliacion_activa';
        r7 := pg_temp.zz_mov(RECIBO, v_c1, 85.00, t);  b7 := pg_temp.zz_mov(BANCO, v_c1, 85.00, t);
        v_j := public.fn_conciliar_movimientos();
        UPDATE public.parametros SET valor = 'true' WHERE clave = 'conciliacion_activa';
        v_total := v_total + 1;
        IF (v_j->>'activa')::boolean
           OR (SELECT id_movimiento_vinculado FROM public.movimientos WHERE id_movimiento = r7) IS NOT NULL THEN
            v_fallas := v_fallas || 'C13 interruptor apagado; ';
        END IF;

        -- ================= RESUMEN MENSUAL (marzo 2031) =================
        SELECT id_cuenta INTO STRICT v_ef FROM public.cuentas WHERE alias = 'Efectivo';
        INSERT INTO public.categorias (nombre, tipo, icono) VALUES ('zz prueba resumen A', 'egreso', '🧪') RETURNING id_categoria INTO v_a;
        INSERT INTO public.categorias (nombre, tipo)        VALUES ('zz prueba resumen B', 'egreso')       RETURNING id_categoria INTO v_b;
        INSERT INTO public.presupuestos (id_categoria, monto_mensual, vigente_desde) VALUES (v_a, 100, '2031-03-01'), (v_b, 200, '2031-03-01');
        INSERT INTO public.movimientos (fecha, monto, sentido, id_cuenta, id_categoria, origen, estado, descripcion)
        SELECT (v.dia + TIME '12:00') AT TIME ZONE 'America/Lima', v.monto, v.sentido, v_ef,
               CASE v.cat WHEN 'A' THEN v_a WHEN 'B' THEN v_b
                          ELSE (SELECT id_categoria FROM public.categorias WHERE nombre = v.cat) END,
               'telegram', v.estado, 'zz prueba'
        FROM (VALUES
            (DATE '2031-03-05',  60.00, 'egreso',  'A',                  'activo'),
            (DATE '2031-03-20',  50.00, 'egreso',  'A',                  'activo'),
            (DATE '2031-03-21', 999.00, 'egreso',  'A',                  'anulado'),    -- no cuenta
            (DATE '2031-03-10', 170.00, 'egreso',  'B',                  'activo'),
            (DATE '2031-03-11',  12.34, 'egreso',  NULL,                 'activo'),     -- Sin categoría
            (DATE '2031-03-01', 500.00, 'ingreso', 'Otros ingresos',     'activo'),
            (DATE '2031-03-03', 300.00, 'egreso',  'Retiro de efectivo', 'activo'),     -- transferencia: no cuenta
            (DATE '2031-02-10', 100.00, 'egreso',  'B',                  'activo')      -- mes anterior (comparación)
        ) AS v(dia, monto, sentido, cat, estado);

        -- R1: día 1 a las 7:30 → todavía no (hora de envío = 8).
        v_total := v_total + 1;
        IF public.fn_generar_resumen_mensual(NULL, TIMESTAMP '2031-04-01 07:30' AT TIME ZONE 'America/Lima') <> 0 THEN
            v_fallas := v_fallas || 'R1 antes de la hora; ';
        END IF;
        -- R2: día 10 → fuera de los días de gracia.
        v_total := v_total + 1;
        IF public.fn_generar_resumen_mensual(NULL, TIMESTAMP '2031-04-10 09:00' AT TIME ZONE 'America/Lima') <> 0 THEN
            v_fallas := v_fallas || 'R2 fuera de gracia; ';
        END IF;
        -- R3: resumen_activo = false → el automático no sale.
        UPDATE public.parametros SET valor = 'false' WHERE clave = 'resumen_activo';
        v_total := v_total + 1;
        IF public.fn_generar_resumen_mensual(NULL, TIMESTAMP '2031-04-01 09:00' AT TIME ZONE 'America/Lima') <> 0 THEN
            v_fallas := v_fallas || 'R3 interruptor apagado; ';
        END IF;
        UPDATE public.parametros SET valor = 'true' WHERE clave = 'resumen_activo';

        -- R4: día 1 a las 9:00 → un resumen de marzo, pendiente de envío.
        -- (La función y la verificación van en sentencias separadas: una
        --  subconsulta en la MISMA sentencia no ve lo que la función insertó.)
        v_res := public.fn_generar_resumen_mensual(NULL, TIMESTAMP '2031-04-01 09:00' AT TIME ZONE 'America/Lima');
        v_total := v_total + 1;
        IF v_res <> '1'
           OR NOT EXISTS (SELECT 1 FROM public.v_alertas_pendientes v JOIN public.alertas a USING (id)
                          WHERE a.clave = 'resumen:2031-03' AND a.tipo = 'resumen' AND a.mes = DATE '2031-03-01') THEN
            v_fallas := v_fallas || 'R4 genera y queda pendiente; ';
        END IF;

        -- R5: contenido (anulado y transferencia fuera; % y colores por presupuesto).
        SELECT mensaje INTO v_msg FROM public.alertas WHERE clave = 'resumen:2031-03';
        v_total := v_total + 1;
        IF v_msg NOT LIKE '📊 Resumen de marzo 2031%'
           OR v_msg NOT LIKE '%Ingresos: S/ 500.00 · Gastos: S/ 292.34%'
           OR v_msg NOT LIKE '%Balance: +S/ 207.66%'
           OR v_msg NOT LIKE '%Gastos vs febrero: ▲ +192 %%'
           OR v_msg NOT LIKE '%🧪 zz prueba resumen A: S/ 110.00 de 100.00 (110 %) 🔴%'
           OR v_msg NOT LIKE '%zz prueba resumen B: S/ 170.00 de 200.00 (85 %) 🟠%'
           OR v_msg NOT LIKE '%❓ Sin categoría: S/ 12.34 en 1 mov.%'
           OR v_msg NOT LIKE '%Mayor gasto: S/ 170.00%'
           OR v_msg LIKE '%999%' OR v_msg LIKE '%300.00%' THEN
            v_fallas := v_fallas || 'R5 contenido del mensaje; ';
            RAISE NOTICE 'Mensaje obtenido:%', E'\n' || v_msg;
        END IF;

        -- R6: idempotente: 100 corridas el mismo día → un solo resumen.
        PERFORM public.fn_generar_resumen_mensual(NULL, TIMESTAMP '2031-04-01 09:15' AT TIME ZONE 'America/Lima')
        FROM generate_series(1, 100);
        v_total := v_total + 1;
        IF (SELECT count(*) FROM public.alertas WHERE clave = 'resumen:2031-03') <> 1 THEN
            v_fallas := v_fallas || 'R6 idempotente; ';
        END IF;

        -- R7: día de gracia (3) a las 2:00 → sí genera (el día 1 el sistema estuvo caído).
        INSERT INTO public.movimientos (fecha, monto, sentido, id_cuenta, id_categoria, origen)
        VALUES (TIMESTAMP '2031-05-15 12:00' AT TIME ZONE 'America/Lima', 10, 'egreso', v_ef, v_a, 'telegram');
        v_total := v_total + 1;
        IF public.fn_generar_resumen_mensual(NULL, TIMESTAMP '2031-06-03 02:00' AT TIME ZONE 'America/Lima') <> 1 THEN
            v_fallas := v_fallas || 'R7 día de gracia; ';
        END IF;

        -- R8: automático en un mes sin movimientos → no avisa; a mano, sí.
        v_res := public.fn_generar_resumen_mensual(NULL, TIMESTAMP '2031-08-01 09:00' AT TIME ZONE 'America/Lima')::text
                 || public.fn_generar_resumen_mensual(DATE '2031-07-20')::text;      -- '0' || '1'
        v_total := v_total + 1;
        IF v_res <> '01'
           OR NOT EXISTS (SELECT 1 FROM public.alertas WHERE clave = 'resumen:2031-07') THEN
            v_fallas := v_fallas || 'R8 mes vacío; ';
        END IF;

        RAISE EXCEPTION USING ERRCODE = 'PZ001', MESSAGE = v_total || '|' || v_fallas;
    EXCEPTION WHEN SQLSTATE 'PZ001' THEN
        v_res := SQLERRM;
    END;

    v_total  := split_part(v_res, '|', 1)::int;
    v_fallas := split_part(v_res, '|', 2);
    IF v_fallas <> '' THEN
        RAISE EXCEPTION 'Pruebas de conciliación/resumen fallidas: %', v_fallas;
    END IF;
    RAISE NOTICE 'Conciliación y resumen: %/% pruebas OK (datos de prueba deshechos)', v_total, v_total;
END
$$;

-- Uso:
--   SELECT public.fn_conciliar_movimientos();                 -- {"vinculados": 1, "por_revisar": 0, ...}
--   SELECT * FROM public.v_conciliacion_por_revisar;           -- lo que hay que decidir en Retool
--   SELECT public.fn_resolver_conciliacion(<id_recibo>, <id_cargo>);   -- o NULL = "no es el mismo"
--   SELECT public.fn_generar_resumen_mensual('2026-10-01');   -- resumen de octubre YA (se envía en ≤ 15 min)
-- Marcar una fuente como recibo (sin tocar código):
--   UPDATE public.fuentes SET es_recibo = true WHERE nombre = 'Uber · Recibo de viaje';
SELECT 'parametros nuevos' AS que, count(*) AS filas
FROM public.parametros WHERE clave LIKE 'conciliacion\_%' OR clave LIKE 'resumen\_%';
