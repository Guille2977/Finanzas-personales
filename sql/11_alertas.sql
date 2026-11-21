-- =====================================================================
-- 11_alertas.sql · Alertas por Telegram: presupuesto y fallas del sistema
-- Requiere: 01 a 10. Idempotente (se puede correr varias veces).
--
-- Qué avisa:
--   1. Presupuesto: una categoría pasa el 80 % o el 100 % de su límite del
--      mes (umbrales en la tabla umbrales_presupuesto).
--   2. Error en la captura de correos: una corrida terminó con errores o se
--      cortó sin terminar (Apps Script la mató a los 6 min).
--   3. Captura detenida: hace más de N horas que no corre (parametros).
--
-- Reparto de trabajo (por qué):
--   · SQL DECIDE qué hay que avisar (fn_generar_alertas) y GUARDA cada aviso
--     en la tabla alertas. La regla vive en un solo lugar, se prueba aquí y
--     Retool puede mostrar el historial.
--   · Apps Script (Alertas.gs) solo ENVÍA los pendientes por Telegram y los
--     marca como enviados. Corre con su propio activador cada 15 min.
--
-- Idempotencia: cada aviso tiene una "clave" UNIQUE que dice QUÉ se avisó:
--     presupuesto:2026-11:cat3:80    error_captura:ejec1234    sin_captura:20261121083000
--   Generar dos veces la misma alerta choca con la clave (ON CONFLICT DO
--   NOTHING): llamar a la función 1 o 100 veces deja lo mismo.
--
-- Patrón "bandeja de salida" (outbox): primero se guarda el aviso con
--   enviada_en = NULL; se marca recién DESPUÉS de que Telegram confirma.
--   Si Telegram falla, el aviso sigue pendiente y se reintenta en la
--   siguiente corrida (hasta alerta_max_intentos). Se prefiere un aviso
--   repetido en un caso raro antes que un aviso perdido.
--
-- PostgreSQL vs SQL Server en este script:
--   · DISTINCT ON (id_categoria) ... ORDER BY umbral DESC ≈ ROW_NUMBER()
--     OVER (PARTITION BY id_categoria ORDER BY umbral DESC) = 1.
--   · format('%s', x) ≈ CONCAT / FORMATMESSAGE; to_char(n, 'FM990.00') ≈ FORMAT(n, '0.00').
--   · GET DIAGNOSTICS n = ROW_COUNT ≈ @@ROWCOUNT.
--   · INTERVAL '1 hour' * n ≈ DATEADD(hour, n, ...).
--   · Un bloque BEGIN ... EXCEPTION dentro de plpgsql crea un SAVEPOINT
--     (≈ SAVE TRAN + ROLLBACK TRAN savepoint); las pruebas lo usan para
--     deshacer sus datos de prueba.
-- =====================================================================
BEGIN;

-- ---------------------------------------------------------------------
-- 1. Configuración (en tablas, editable desde Retool sin tocar código)
-- ---------------------------------------------------------------------
-- Umbrales de presupuesto. Una tabla y no "80,100" en un texto: así cada
-- umbral es una fila que se activa/desactiva, y se valida con CHECK.
CREATE TABLE IF NOT EXISTS public.umbrales_presupuesto (
    porcentaje INT     PRIMARY KEY CHECK (porcentaje BETWEEN 1 AND 300),
    activo     BOOLEAN NOT NULL DEFAULT true
);
INSERT INTO public.umbrales_presupuesto (porcentaje) VALUES (80), (100)
ON CONFLICT (porcentaje) DO NOTHING;

-- Parámetros sueltos (clave → valor). Tabla genérica para no crear una
-- tabla por cada número configurable.
CREATE TABLE IF NOT EXISTS public.parametros (
    clave       TEXT PRIMARY KEY,
    valor       TEXT NOT NULL,
    descripcion TEXT
);
INSERT INTO public.parametros (clave, valor, descripcion) VALUES
    ('alerta_horas_sin_captura',      '3',
     'Si la captura de correos (cada 15 min) no corre en estas horas, se avisa una vez.'),
    ('alerta_silencio_errores_horas', '6',
     'Tras avisar un error de captura, no se avisa otro hasta pasadas estas horas (evita 96 mensajes al día si el error se repite).'),
    ('alerta_max_intentos',           '5',
     'Intentos de envío por Telegram antes de dejar un aviso como fallido (queda visible en la tabla alertas).')
ON CONFLICT (clave) DO NOTHING;   -- no pisa lo que el usuario ya cambió

-- ---------------------------------------------------------------------
-- 2. Bandeja de salida: un aviso por fila
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.alertas (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tipo         TEXT        NOT NULL CHECK (tipo IN ('presupuesto', 'error_captura', 'sin_captura')),
    clave        TEXT        NOT NULL UNIQUE,      -- QUÉ se avisó: la idempotencia
    mensaje      TEXT        NOT NULL,             -- texto listo para Telegram
    id_categoria INT         REFERENCES public.categorias (id_categoria),
    mes          DATE,
    umbral       INT,
    creada_en    TIMESTAMPTZ NOT NULL DEFAULT now(),
    enviada_en   TIMESTAMPTZ,                      -- NULL = pendiente
    intentos     INT         NOT NULL DEFAULT 0,
    ultimo_error TEXT,
    CONSTRAINT ck_alerta_presupuesto CHECK (
        tipo <> 'presupuesto' OR (id_categoria IS NOT NULL AND mes IS NOT NULL AND umbral IS NOT NULL))
);
-- Índice parcial: solo las pendientes (pocas), que es lo que se consulta cada 15 min.
CREATE INDEX IF NOT EXISTS ix_alertas_pendientes ON public.alertas (id) WHERE enviada_en IS NULL;
COMMENT ON TABLE public.alertas IS
    'Avisos por Telegram (bandeja de salida). clave UNIQUE = no se repite; enviada_en NULL = pendiente.';

-- Lo que Apps Script debe enviar: pendientes con intentos disponibles.
CREATE OR REPLACE VIEW public.v_alertas_pendientes
WITH (security_invoker = true) AS
SELECT a.id, a.tipo, a.mensaje, a.intentos
FROM public.alertas a
WHERE a.enviada_en IS NULL
  AND a.intentos < COALESCE((SELECT p.valor::int FROM public.parametros p
                             WHERE p.clave = 'alerta_max_intentos'), 5)
ORDER BY a.id;

-- ---------------------------------------------------------------------
-- 3. fn_generar_alertas(): decide qué avisar y lo encola. Devuelve
--    cuántos avisos NUEVOS creó. No envía nada.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_generar_alertas()
RETURNS INT
LANGUAGE plpgsql
VOLATILE                    -- escribe en la tabla alertas
SET search_path = ''
AS $$
DECLARE
    v_nuevas      INT := 0;
    v_n           INT;
    v_meses       TEXT[] := ARRAY['enero','febrero','marzo','abril','mayo','junio','julio',
                                  'agosto','septiembre','octubre','noviembre','diciembre'];
    v_hoy         DATE := (now() AT TIME ZONE 'America/Lima')::date;
    v_silencio    INT  := COALESCE((SELECT valor::int FROM public.parametros WHERE clave = 'alerta_silencio_errores_horas'), 6);
    v_horas_sin   INT  := COALESCE((SELECT valor::int FROM public.parametros WHERE clave = 'alerta_horas_sin_captura'), 3);
    v_ultimo      TIMESTAMPTZ;
    v_fallidas    INT;
    v_id_ultima   BIGINT;
    v_detalle     TEXT;
    v_ultima_cap  TIMESTAMPTZ;
BEGIN
    -- 3.1 PRESUPUESTO ----------------------------------------------------
    -- Reutiliza v_avance_presupuesto (sql/01): gasto del mes actual en Lima,
    -- sin anulados ni recibos conciliados. Por categoría se toma solo el
    -- umbral MÁS ALTO que ya cruzó: si un gasto grande salta de 70 % a 110 %,
    -- llega un aviso de 100 %, no dos. Y si ya se avisó 100 %, el de 80 %
    -- no llega nunca (NOT EXISTS con umbral >=).
    INSERT INTO public.alertas (tipo, clave, mensaje, id_categoria, mes, umbral)
    SELECT 'presupuesto',
           format('presupuesto:%s:cat%s:%s', to_char(x.mes, 'YYYY-MM'), x.id_categoria, x.umbral),
           CASE WHEN x.gastado >= x.limite THEN
               format(E'🔴 Presupuesto excedido: %s %s\nGastaste S/ %s de S/ %s (%s %%) en %s. Te pasaste por S/ %s.',
                      COALESCE(x.icono, ''), x.categoria,
                      to_char(x.gastado, 'FM999990.00'), to_char(x.limite, 'FM999990.00'),
                      round(100 * x.gastado / x.limite), v_meses[EXTRACT(MONTH FROM x.mes)],
                      to_char(x.gastado - x.limite, 'FM999990.00'))
           ELSE
               format(E'🟠 %s %s: ya usaste el %s %% del presupuesto\nS/ %s de S/ %s. Te quedan S/ %s para %s día(s) de %s.',
                      COALESCE(x.icono, ''), x.categoria, round(100 * x.gastado / x.limite),
                      to_char(x.gastado, 'FM999990.00'), to_char(x.limite, 'FM999990.00'),
                      to_char(x.limite - x.gastado, 'FM999990.00'),
                      (x.mes + INTERVAL '1 month')::date - v_hoy, v_meses[EXTRACT(MONTH FROM x.mes)])
           END,
           x.id_categoria, x.mes, x.umbral
    FROM (
        SELECT DISTINCT ON (c.id_categoria)
               a.mes, c.id_categoria, c.nombre AS categoria, c.icono, a.limite, a.gastado, u.porcentaje AS umbral
        FROM public.v_avance_presupuesto a
        JOIN public.categorias c            ON c.nombre = a.categoria     -- nombre es UNIQUE
        JOIN public.umbrales_presupuesto u  ON u.activo
                                           AND a.gastado >= a.limite * u.porcentaje / 100.0
        ORDER BY c.id_categoria, u.porcentaje DESC
    ) x
    WHERE NOT EXISTS (SELECT 1 FROM public.alertas al
                      WHERE al.tipo = 'presupuesto' AND al.id_categoria = x.id_categoria
                        AND al.mes = x.mes AND al.umbral >= x.umbral)
    ON CONFLICT (clave) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_nuevas := v_nuevas + v_n;

    -- 3.2 ERRORES DE CAPTURA ---------------------------------------------
    -- Corrida fallida = terminó con errores > 0, o empezó hace más de 30 min
    -- y nunca terminó (fin NULL: Apps Script la cortó). Se cuentan las
    -- fallidas desde el último aviso (máximo 24 h atrás, para no avisar
    -- historia vieja al instalar) y se manda UN aviso con el resumen.
    -- Silencio: si ya se avisó hace menos de v_silencio horas, se espera.
    SELECT max(creada_en) INTO v_ultimo FROM public.alertas WHERE tipo = 'error_captura';
    IF v_ultimo IS NULL OR v_ultimo < now() - INTERVAL '1 hour' * v_silencio THEN
        SELECT count(*), max(e.id), (array_agg(e.detalle ORDER BY e.id DESC))[1]
          INTO v_fallidas, v_id_ultima, v_detalle
        FROM public.ejecuciones e
        WHERE e.proceso = 'captura'
          AND e.inicio >= GREATEST(COALESCE(v_ultimo, '-infinity'), now() - INTERVAL '24 hours')
          AND (e.errores > 0 OR (e.fin IS NULL AND e.inicio < now() - INTERVAL '30 minutes'));

        IF v_fallidas > 0 THEN
            INSERT INTO public.alertas (tipo, clave, mensaje)
            VALUES ('error_captura', 'error_captura:ejec' || v_id_ultima,
                    format(E'⚠️ La captura de correos falló en %s corrida(s).\nÚltimo detalle: %s\nRevisa Supabase → ejecuciones (id %s) o el registro de Apps Script.',
                           v_fallidas,
                           COALESCE(left(v_detalle, 300), 'se cortó sin terminar (límite de 6 min o error grave)'),
                           v_id_ultima))
            ON CONFLICT (clave) DO NOTHING;
            GET DIAGNOSTICS v_n = ROW_COUNT;
            v_nuevas := v_nuevas + v_n;
        END IF;
    END IF;

    -- 3.3 CAPTURA DETENIDA -------------------------------------------------
    -- Un aviso por "apagón": la clave lleva la hora de la última corrida.
    -- Si vuelve a correr y luego se detiene otra vez, la clave cambia.
    SELECT max(inicio) INTO v_ultima_cap FROM public.ejecuciones WHERE proceso = 'captura';
    IF v_ultima_cap IS NOT NULL AND v_ultima_cap < now() - INTERVAL '1 hour' * v_horas_sin THEN
        INSERT INTO public.alertas (tipo, clave, mensaje)
        VALUES ('sin_captura',
                'sin_captura:' || to_char(v_ultima_cap AT TIME ZONE 'UTC', 'YYYYMMDDHH24MISS'),
                format(E'⏸️ La captura de correos no corre hace %s h (última: %s, hora de Lima).\nRevisa los activadores de Apps Script o si hay que volver a dar permisos.',
                       floor(EXTRACT(EPOCH FROM now() - v_ultima_cap) / 3600),
                       to_char(v_ultima_cap AT TIME ZONE 'America/Lima', 'DD/MM HH24:MI')))
        ON CONFLICT (clave) DO NOTHING;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_nuevas := v_nuevas + v_n;
    END IF;

    RETURN v_nuevas;
END;
$$;
COMMENT ON FUNCTION public.fn_generar_alertas() IS
    'Encola avisos nuevos (presupuesto, error de captura, captura detenida) en alertas. Idempotente. No envía.';

-- ---------------------------------------------------------------------
-- 4. Seguridad: igual que el resto (RLS sin políticas + solo service_role)
-- ---------------------------------------------------------------------
ALTER TABLE public.umbrales_presupuesto ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.parametros           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.alertas              ENABLE ROW LEVEL SECURITY;
-- En PostgreSQL toda función nueva la puede ejecutar PUBLIC (en SQL Server, nadie).
REVOKE ALL ON FUNCTION public.fn_generar_alertas() FROM PUBLIC;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON public.umbrales_presupuesto, public.parametros, public.alertas TO service_role;
        GRANT SELECT ON public.v_alertas_pendientes TO service_role;
        GRANT EXECUTE ON FUNCTION public.fn_generar_alertas() TO service_role;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON public.umbrales_presupuesto, public.parametros, public.alertas, public.v_alertas_pendientes
            FROM anon, authenticated;
        REVOKE ALL ON FUNCTION public.fn_generar_alertas() FROM anon, authenticated;
    END IF;
END
$$;

COMMIT;

-- =====================================================================
-- Pruebas. Crean datos de prueba, revisan y DESHACEN todo (también en la
-- base real): el bloque interno termina siempre con un error propio
-- (PZ001) que hace ROLLBACK a su savepoint. Si algo falla, el script
-- termina en error con la lista de pruebas que fallaron.
-- =====================================================================
DO $$
DECLARE
    v_cat_a   INT;
    v_cat_b   INT;
    v_cuenta  INT;
    v_fallas  TEXT := '';
    v_total   INT  := 0;
    v_res     TEXT;
BEGIN
    -- Cada prueba suma 1 a v_total y, si no se cumple, agrega su nombre a v_fallas.
    BEGIN
        SELECT id_cuenta INTO STRICT v_cuenta FROM public.cuentas WHERE alias = 'Efectivo';
        INSERT INTO public.categorias (nombre, tipo) VALUES ('zz prueba alerta A', 'egreso') RETURNING id_categoria INTO v_cat_a;
        INSERT INTO public.categorias (nombre, tipo) VALUES ('zz prueba alerta B', 'egreso') RETURNING id_categoria INTO v_cat_b;
        INSERT INTO public.presupuestos (id_categoria, monto_mensual, vigente_desde)
        SELECT c, 100, date_trunc('month', now() AT TIME ZONE 'America/Lima')::date FROM unnest(ARRAY[v_cat_a, v_cat_b]) c;
        -- Estado limpio para las alertas de sistema (se deshace al final).
        DELETE FROM public.alertas WHERE tipo IN ('error_captura', 'sin_captura');
        DELETE FROM public.ejecuciones WHERE proceso = 'captura';
        INSERT INTO public.ejecuciones (proceso, inicio, fin) VALUES ('captura', now() - INTERVAL '5 minutes', now());

        -- P1: 79 de 100 → sin aviso para A.
        INSERT INTO public.movimientos (fecha, monto, sentido, id_cuenta, id_categoria, origen)
        VALUES (now(), 79, 'egreso', v_cuenta, v_cat_a, 'telegram');
        PERFORM public.fn_generar_alertas();
        v_total := v_total + 1;
        IF EXISTS (SELECT 1 FROM public.alertas WHERE id_categoria = v_cat_a) THEN v_fallas := v_fallas || 'P1 79 % no avisa; '; END IF;

        -- P2: +1 → 80 % exacto → un aviso de 80.
        INSERT INTO public.movimientos (fecha, monto, sentido, id_cuenta, id_categoria, origen)
        VALUES (now(), 1, 'egreso', v_cuenta, v_cat_a, 'telegram');
        PERFORM public.fn_generar_alertas();
        v_total := v_total + 1;
        IF (SELECT array_agg(umbral) FROM public.alertas WHERE id_categoria = v_cat_a) IS DISTINCT FROM ARRAY[80] THEN
            v_fallas := v_fallas || 'P2 80 % avisa una vez; ';
        END IF;

        -- P3: volver a generar no repite (idempotencia).
        v_total := v_total + 1;
        IF public.fn_generar_alertas() <> 0
           OR (SELECT count(*) FROM public.alertas WHERE id_categoria = v_cat_a) <> 1 THEN
            v_fallas := v_fallas || 'P3 no repite; ';
        END IF;

        -- P4: un anulado no cuenta (95 anulado → sigue en 80 %).
        INSERT INTO public.movimientos (fecha, monto, sentido, id_cuenta, id_categoria, origen, estado)
        VALUES (now(), 95, 'egreso', v_cuenta, v_cat_a, 'telegram', 'anulado');
        PERFORM public.fn_generar_alertas();
        v_total := v_total + 1;
        IF (SELECT count(*) FROM public.alertas WHERE id_categoria = v_cat_a) <> 1 THEN v_fallas := v_fallas || 'P4 anulado no cuenta; '; END IF;

        -- P5: pasa el 100 % → llega el de 100 y el mensaje dice "excedido".
        INSERT INTO public.movimientos (fecha, monto, sentido, id_cuenta, id_categoria, origen)
        VALUES (now(), 25.5, 'egreso', v_cuenta, v_cat_a, 'telegram');
        PERFORM public.fn_generar_alertas();
        v_total := v_total + 1;
        IF (SELECT array_agg(umbral ORDER BY umbral) FROM public.alertas WHERE id_categoria = v_cat_a) IS DISTINCT FROM ARRAY[80, 100]
           OR NOT EXISTS (SELECT 1 FROM public.alertas WHERE id_categoria = v_cat_a AND umbral = 100
                          AND mensaje LIKE '%excedido%' AND mensaje LIKE '%S/ 105.50 de S/ 100.00%') THEN
            v_fallas := v_fallas || 'P5 100 % excedido; ';
        END IF;

        -- P6: salto directo de 0 a 120 % → SOLO el aviso de 100 (no también el de 80).
        INSERT INTO public.movimientos (fecha, monto, sentido, id_cuenta, id_categoria, origen)
        VALUES (now(), 120, 'egreso', v_cuenta, v_cat_b, 'telegram');
        PERFORM public.fn_generar_alertas();
        v_total := v_total + 1;
        IF (SELECT array_agg(umbral) FROM public.alertas WHERE id_categoria = v_cat_b) IS DISTINCT FROM ARRAY[100] THEN
            v_fallas := v_fallas || 'P6 salto directo solo 100; ';
        END IF;

        -- P7: un ingreso no consume presupuesto (ya cubierto por la vista; se verifica igual).
        v_total := v_total + 1;
        IF (SELECT gastado FROM public.v_avance_presupuesto WHERE categoria = 'zz prueba alerta A') <> 105.5 THEN
            v_fallas := v_fallas || 'P7 gastado = 105.50; ';
        END IF;

        -- P8: corrida de captura con error → un aviso; una segunda → silencio.
        INSERT INTO public.ejecuciones (proceso, inicio, fin, errores, detalle)
        VALUES ('captura', now() - INTERVAL '2 minutes', now(), 1, 'Supabase 503: prueba');
        PERFORM public.fn_generar_alertas();
        INSERT INTO public.ejecuciones (proceso, inicio, fin, errores, detalle)
        VALUES ('captura', now() - INTERVAL '1 minute', now(), 1, 'otra falla');
        PERFORM public.fn_generar_alertas();
        v_total := v_total + 1;
        IF (SELECT count(*) FROM public.alertas WHERE tipo = 'error_captura') <> 1
           OR NOT EXISTS (SELECT 1 FROM public.alertas WHERE tipo = 'error_captura' AND mensaje LIKE '%Supabase 503: prueba%') THEN
            v_fallas := v_fallas || 'P8 error avisa una vez y luego silencio; ';
        END IF;

        -- P9: corrida cortada (fin NULL hace 40 min) también es falla, pero sigue en silencio.
        INSERT INTO public.ejecuciones (proceso, inicio) VALUES ('captura', now() - INTERVAL '40 minutes');
        PERFORM public.fn_generar_alertas();
        v_total := v_total + 1;
        IF (SELECT count(*) FROM public.alertas WHERE tipo = 'error_captura') <> 1 THEN v_fallas := v_fallas || 'P9 silencio; '; END IF;

        -- P10: pasado el silencio, la corrida cortada SÍ se avisa.
        UPDATE public.alertas SET creada_en = now() - INTERVAL '7 hours' WHERE tipo = 'error_captura';
        UPDATE public.ejecuciones SET inicio = now() - INTERVAL '7 hours 30 minutes', fin = now() - INTERVAL '7 hours 29 minutes'
        WHERE proceso = 'captura' AND errores > 0;      -- las ya avisadas quedan antes del último aviso
        PERFORM public.fn_generar_alertas();
        v_total := v_total + 1;
        IF (SELECT count(*) FROM public.alertas WHERE tipo = 'error_captura') <> 2
           OR NOT EXISTS (SELECT 1 FROM public.alertas WHERE tipo = 'error_captura' AND mensaje LIKE '%se cortó sin terminar%') THEN
            v_fallas := v_fallas || 'P10 corrida cortada tras silencio; ';
        END IF;

        -- P11: sin captura hace 5 h → un aviso, una sola vez.
        DELETE FROM public.ejecuciones WHERE proceso = 'captura';
        INSERT INTO public.ejecuciones (proceso, inicio, fin) VALUES ('captura', now() - INTERVAL '5 hours', now() - INTERVAL '5 hours');
        PERFORM public.fn_generar_alertas();
        PERFORM public.fn_generar_alertas();
        v_total := v_total + 1;
        IF (SELECT count(*) FROM public.alertas WHERE tipo = 'sin_captura') <> 1 THEN v_fallas := v_fallas || 'P11 sin captura una vez; '; END IF;

        -- P12: la vista de pendientes respeta el máximo de intentos.
        UPDATE public.alertas SET intentos = 5 WHERE id_categoria = v_cat_b;
        v_total := v_total + 1;
        IF EXISTS (SELECT 1 FROM public.v_alertas_pendientes v JOIN public.alertas a USING (id) WHERE a.id_categoria = v_cat_b)
           OR NOT EXISTS (SELECT 1 FROM public.v_alertas_pendientes v JOIN public.alertas a USING (id) WHERE a.id_categoria = v_cat_a) THEN
            v_fallas := v_fallas || 'P12 max intentos; ';
        END IF;

        -- Deshacer TODO lo de arriba (savepoint), llevando el resultado en el mensaje.
        RAISE EXCEPTION USING ERRCODE = 'PZ001', MESSAGE = v_total || '|' || v_fallas;
    EXCEPTION WHEN SQLSTATE 'PZ001' THEN
        v_res := SQLERRM;
    END;

    v_total  := split_part(v_res, '|', 1)::int;
    v_fallas := split_part(v_res, '|', 2);
    IF v_fallas <> '' THEN
        RAISE EXCEPTION 'Pruebas de alertas fallidas: %', v_fallas;
    END IF;
    RAISE NOTICE 'Alertas: %/% pruebas OK (datos de prueba deshechos)', v_total, v_total;
END
$$;

-- Qué se avisaría hoy con los datos reales (o demo). Esto SÍ encola:
--   SELECT public.fn_generar_alertas();
--   SELECT id, tipo, mensaje, enviada_en FROM public.alertas ORDER BY id DESC;
-- Cambiar un umbral o un parámetro (sin tocar código):
--   INSERT INTO public.umbrales_presupuesto (porcentaje) VALUES (50) ON CONFLICT DO NOTHING;
--   UPDATE public.parametros SET valor = '6' WHERE clave = 'alerta_horas_sin_captura';
SELECT 'alertas' AS tabla, count(*) FILTER (WHERE enviada_en IS NULL) AS pendientes, count(*) AS total
FROM public.alertas;
