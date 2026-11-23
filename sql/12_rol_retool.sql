-- =====================================================================
-- 12_rol_retool.sql · Usuario de base de datos para el panel de Retool
-- Requiere: 01 a 11 (11 = alertas). Idempotente (se puede ejecutar N veces).
-- Ejecutar en: SQL Editor de Supabase (como postgres).
--
-- Por qué (sección 10 del documento): Retool NO usa la clave service_role
-- ni el usuario postgres. Se conecta con "retool_panel", que solo puede
-- hacer lo que el panel necesita. Si alguien obtiene su contraseña, no
-- puede borrar datos, crear tablas, ver telegram_updates ni cambiar montos.
--
-- Principio de mínimo privilegio, en 3 capas:
--   1. GRANT  → qué COMANDOS y qué COLUMNAS (SELECT, INSERT, UPDATE).
--   2. RLS    → qué FILAS. Las tablas tienen RLS sin políticas (01), así
--               que sin una política este rol vería 0 filas. Se crea una
--               política SOLO para retool_panel (anon y authenticated
--               siguen sin ver nada).
--   3. Función SECURITY DEFINER → la única operación de varios pasos
--      (resolver un "Por revisar") se hace con una función, no dándole
--      INSERT sobre movimientos.
--
-- Qué puede hacer el panel:
--   · Leer: catálogos, movimientos, correos, ejecuciones y vistas v_*.
--   · Corregir movimientos: categoría, descripción, contraparte y estado
--     (anular/reactivar). NO monto, fecha, cuenta ni borrar.
--   · "Por revisar": descartar (estado → ignorado) o resolver con
--     fn_resolver_por_revisar (crea el movimiento y marca el correo).
--   · Configuración: agregar y editar categorías, diccionario,
--     frases_sentido, fuentes y presupuestos; umbrales de alerta y
--     parámetros. Las alertas (11) solo se leen.
--   · NUNCA DELETE: el borrado lógico (activo = false / anulado) lo
--     impone la base, no la buena voluntad del panel.
--
-- CONTRASEÑA: este archivo NO la tiene (va a GitHub). El rol se crea con
-- LOGIN pero sin contraseña, así que nadie puede entrar hasta que la
-- pongas tú (ver docs/retool.md, paso 1):
--   ALTER ROLE retool_panel WITH PASSWORD '<CONTRASEÑA_LARGA_GENERADA>';
--
-- PostgreSQL vs SQL Server:
--   · En PostgreSQL usuario y rol son lo mismo (ROLE con LOGIN). En SQL
--     Server hay LOGIN (servidor) + USER (base) + ROLE por separado.
--   · GRANT UPDATE (col1, col2) ON tabla: permisos por columna. SQL Server
--     también los tiene: GRANT UPDATE ON tabla (col1, col2).
--   · RLS (CREATE POLICY) ≈ Row-Level Security de SQL Server, que usa una
--     función predicado + CREATE SECURITY POLICY.
--   · SECURITY DEFINER ≈ EXECUTE AS OWNER en un procedimiento: el clásico
--     "da EXECUTE sobre el procedimiento, no permisos sobre la tabla".
--   · No hay CREATE ROLE IF NOT EXISTS ni CREATE POLICY IF NOT EXISTS:
--     se usa un DO con IF NOT EXISTS y DROP POLICY IF EXISTS + CREATE.
-- =====================================================================
BEGIN;
SET LOCAL client_min_messages = warning;   -- oculta los avisos de DROP ... IF EXISTS

-- ---------------------------------------------------------------------
-- 1. El rol (usuario). Sin superpoderes, con límites de sesión.
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'retool_panel') THEN
        CREATE ROLE retool_panel LOGIN;   -- sin PASSWORD: no puede entrar aún
    END IF;
END
$$;

-- CREATE ROLE ya lo crea NOSUPERUSER, NOCREATEDB, NOBYPASSRLS, etc.
-- (no se escriben: en Supabase postgres no es superusuario y no puede
-- tocar esos atributos; las pruebas del final verifican que estén así).
ALTER ROLE retool_panel LOGIN NOCREATEROLE CONNECTION LIMIT 10;   -- Retool abre pocas conexiones

-- Valores por defecto de SUS sesiones (≈ opciones del LOGIN en SQL Server):
ALTER ROLE retool_panel SET statement_timeout = '15s';                 -- una consulta mala no traba la base
ALTER ROLE retool_panel SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE retool_panel SET timezone = 'America/Lima';                -- now()::date = hoy en Lima

COMMENT ON ROLE retool_panel IS 'Panel de Retool: lectura + edición de configuración y correcciones. Sin DELETE.';

-- ---------------------------------------------------------------------
-- 2. Limpieza: se quitan TODOS sus permisos y se vuelven a dar.
--    Así, si una columna sale de la lista, el permiso desaparece
--    (un GRANT repetido no hace nada; un permiso olvidado sí es riesgo).
--    REVOKE sobre la tabla también quita los permisos por columna.
--    OJO: también quita los que agrega sql/13 (conciliación). Si vuelves a
--    correr este script, corre sql/13 justo después.
-- ---------------------------------------------------------------------
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM retool_panel;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM retool_panel;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM retool_panel;
GRANT USAGE ON SCHEMA public TO retool_panel;   -- "ver" el esquema, no crear en él

-- ---------------------------------------------------------------------
-- 3. Lectura (tablas que el panel muestra + vistas de reportes).
--    telegram_updates queda fuera: el panel no la necesita.
-- ---------------------------------------------------------------------
GRANT SELECT ON
    public.entidades, public.cuentas, public.categorias, public.diccionario,
    public.fuentes, public.frases_sentido, public.presupuestos,
    public.movimientos, public.correos_raw, public.ejecuciones,
    public.alertas, public.umbrales_presupuesto, public.parametros,   -- de sql/11
    public.v_movimientos_contables, public.v_alertas_pendientes, public.v_gasto_mensual,
    public.v_gasto_categoria_mes, public.v_avance_presupuesto, public.v_salud_sistema
TO retool_panel;

-- ---------------------------------------------------------------------
-- 4. Escritura por columna (lo que el panel edita y nada más).
--    Las columnas id son IDENTITY: no hace falta permiso sobre secuencias.
-- ---------------------------------------------------------------------
-- Corrección de movimientos (sin monto, fecha, cuenta ni origen: esos
-- vienen del banco; si están mal, se anula y se registra de nuevo).
GRANT UPDATE (id_categoria, descripcion, contraparte, estado) ON public.movimientos TO retool_panel;

-- "Por revisar": solo cambiar el estado (descartar / restaurar). La
-- política de RLS de abajo impide marcarlo 'procesado' a mano.
GRANT UPDATE (estado, detalle_error, procesado_en) ON public.correos_raw TO retool_panel;

-- Configuración. INSERT por columnas: p. ej. diccionario.origen no está,
-- así que una palabra creada en Retool siempre queda como 'manual'.
GRANT INSERT (nombre, tipo, icono)                 ON public.categorias     TO retool_panel;
GRANT UPDATE (nombre, icono, activo)               ON public.categorias     TO retool_panel;

GRANT INSERT (palabra, id_categoria)               ON public.diccionario    TO retool_panel;
GRANT UPDATE (id_categoria, activo)                ON public.diccionario    TO retool_panel;

GRANT INSERT (frase, sentido)                      ON public.frases_sentido TO retool_panel;
GRANT UPDATE (sentido, activo)                     ON public.frases_sentido TO retool_panel;

GRANT INSERT (nombre, remitente_patron, asunto_patron, accion, extractor,
              id_cuenta_defecto, id_categoria_defecto, sentido_defecto, prioridad)
                                                   ON public.fuentes        TO retool_panel;
GRANT UPDATE (remitente_patron, asunto_patron, accion, extractor,
              id_cuenta_defecto, id_categoria_defecto, sentido_defecto, prioridad, activo)
                                                   ON public.fuentes        TO retool_panel;

GRANT INSERT (id_categoria, monto_mensual, vigente_desde) ON public.presupuestos TO retool_panel;
GRANT UPDATE (monto_mensual)                              ON public.presupuestos TO retool_panel;

-- Alertas (sql/11): umbrales y parámetros editables; la tabla alertas,
-- solo lectura (la escribe fn_generar_alertas y la marca Apps Script).
-- parametros: solo el VALOR. Una clave nueva no sirve sin código que la lea.
GRANT INSERT (porcentaje)                          ON public.umbrales_presupuesto TO retool_panel;
GRANT UPDATE (activo)                              ON public.umbrales_presupuesto TO retool_panel;
GRANT UPDATE (valor)                               ON public.parametros           TO retool_panel;

-- ---------------------------------------------------------------------
-- 5. RLS: políticas SOLO para retool_panel (TO retool_panel).
--    La política dice qué FILAS; el GRANT de arriba, qué COMANDOS.
--    Tablas de solo lectura → política FOR SELECT (defensa en
--    profundidad: aunque alguien le diera UPDATE por error, RLS lo frena).
-- ---------------------------------------------------------------------
DO $$
DECLARE
    t RECORD;
BEGIN
    FOR t IN SELECT * FROM (VALUES
        ('entidades',      'SELECT'),
        ('cuentas',        'SELECT'),
        ('ejecuciones',    'SELECT'),
        ('alertas',        'SELECT'),
        ('categorias',     'ALL'),
        ('diccionario',    'ALL'),
        ('frases_sentido', 'ALL'),
        ('fuentes',        'ALL'),
        ('presupuestos',   'ALL'),
        ('umbrales_presupuesto', 'ALL'),
        ('parametros',     'ALL'),
        ('movimientos',    'ALL')
    ) AS v(tabla, comando)
    LOOP
        -- format('%I') pone comillas si hace falta (≈ QUOTENAME de SQL Server).
        EXECUTE format('DROP POLICY IF EXISTS retool_panel_acceso ON public.%I', t.tabla);
        IF t.comando = 'SELECT' THEN
            EXECUTE format('CREATE POLICY retool_panel_acceso ON public.%I FOR SELECT TO retool_panel USING (true)', t.tabla);
        ELSE
            EXECUTE format('CREATE POLICY retool_panel_acceso ON public.%I FOR ALL TO retool_panel USING (true) WITH CHECK (true)', t.tabla);
        END IF;
    END LOOP;
END
$$;

-- correos_raw: ve todos, pero solo cambia los que están sin resolver y
-- solo a 'ignorado' o de vuelta a 'por_revisar'. 'procesado' exige un
-- movimiento, y eso lo garantiza fn_resolver_por_revisar.
--   USING      = qué filas puede tocar (≈ predicado FILTER/BLOCK BEFORE UPDATE)
--   WITH CHECK = cómo deben quedar después (≈ BLOCK AFTER UPDATE)
DROP POLICY IF EXISTS retool_panel_acceso    ON public.correos_raw;
DROP POLICY IF EXISTS retool_panel_lectura   ON public.correos_raw;
DROP POLICY IF EXISTS retool_panel_descartar ON public.correos_raw;
CREATE POLICY retool_panel_lectura ON public.correos_raw
    FOR SELECT TO retool_panel USING (true);
CREATE POLICY retool_panel_descartar ON public.correos_raw
    FOR UPDATE TO retool_panel
    USING      (estado IN ('por_revisar', 'error', 'ignorado'))
    WITH CHECK (estado IN ('por_revisar', 'ignorado'));

-- ---------------------------------------------------------------------
-- 6. Resolver un "Por revisar": crea el movimiento y marca el correo
--    como procesado, en UNA transacción (o las dos cosas o ninguna).
--    En Retool cada consulta es su propia transacción; por eso la lógica
--    de varios pasos vive aquí y no en dos consultas del panel.
--
--    SECURITY DEFINER: corre con los permisos del dueño (postgres), así
--    retool_panel NO necesita INSERT sobre movimientos. Reglas de oro:
--    SET search_path = '' y EXECUTE solo para quien lo necesita.
--    Idempotente: si ese correo ya tiene movimiento (doble clic), lo
--    devuelve en vez de crear otro.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_resolver_por_revisar(
    p_id_correo        BIGINT,
    p_monto            NUMERIC,
    p_sentido          TEXT,
    p_id_cuenta        INT,
    p_id_categoria     INT         DEFAULT NULL,   -- NULL = "Sin categoría"
    p_fecha            TIMESTAMPTZ DEFAULT NULL,   -- NULL = fecha del correo
    p_descripcion      TEXT        DEFAULT NULL,   -- NULL = asunto del correo
    p_contraparte      TEXT        DEFAULT NULL,
    p_numero_operacion TEXT        DEFAULT NULL,
    p_moneda           TEXT        DEFAULT 'PEN'
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_correo public.correos_raw%ROWTYPE;   -- ≈ una variable con la forma de la fila
    v_tipo   TEXT;
    v_id     BIGINT;
BEGIN
    -- FOR UPDATE bloquea la fila: dos clics simultáneos se ponen en fila.
    -- (≈ WITH (UPDLOCK, ROWLOCK) de SQL Server)
    SELECT * INTO v_correo FROM public.correos_raw WHERE id_correo = p_id_correo FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el correo %', p_id_correo;
    END IF;

    -- Idempotencia: ya resuelto → mismo movimiento.
    SELECT id_movimiento INTO v_id FROM public.movimientos WHERE id_correo = p_id_correo;
    IF FOUND THEN
        RETURN v_id;
    END IF;

    IF v_correo.estado NOT IN ('por_revisar', 'error') THEN
        RAISE EXCEPTION 'El correo % está "%": solo se resuelven los que están por revisar o con error',
            p_id_correo, v_correo.estado;
    END IF;

    -- Coherencia: un egreso no va a una categoría de ingreso (y viceversa).
    -- Monto > 0, sentido y moneda válidos ya los validan los CHECK de la tabla.
    IF p_id_categoria IS NOT NULL THEN
        SELECT tipo INTO v_tipo FROM public.categorias WHERE id_categoria = p_id_categoria AND activo;
        IF v_tipo IS NULL THEN
            RAISE EXCEPTION 'La categoría % no existe o está inactiva', p_id_categoria;
        ELSIF v_tipo <> 'transferencia' AND v_tipo <> p_sentido THEN
            RAISE EXCEPTION 'La categoría es de tipo "%" y el movimiento es "%"', v_tipo, p_sentido;
        END IF;
    END IF;

    INSERT INTO public.movimientos
        (fecha, monto, moneda, sentido, id_cuenta, id_categoria,
         descripcion, contraparte, numero_operacion, origen, id_correo)
    VALUES
        (coalesce(p_fecha, v_correo.fecha_correo), p_monto, coalesce(p_moneda, 'PEN'), p_sentido,
         p_id_cuenta, p_id_categoria,
         coalesce(nullif(btrim(p_descripcion), ''), v_correo.asunto),
         nullif(btrim(p_contraparte), ''),
         nullif(btrim(p_numero_operacion), ''),
         'correo', p_id_correo)
    RETURNING id_movimiento INTO v_id;   -- ≈ OUTPUT inserted.id_movimiento

    UPDATE public.correos_raw
    SET estado        = 'procesado',
        procesado_en  = now(),
        detalle_error = concat_ws(' · ', detalle_error, 'Resuelto a mano en Retool')
    WHERE id_correo = p_id_correo;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.fn_resolver_por_revisar(BIGINT, NUMERIC, TEXT, INT, INT, TIMESTAMPTZ, TEXT, TEXT, TEXT, TEXT) IS
    'Retool: convierte un correo "por revisar" en movimiento y lo marca procesado, en una transacción. Idempotente.';

-- Funciones: en PostgreSQL PUBLIC puede ejecutar toda función nueva; se
-- quita y se da solo a quien la usa. Las de 09 (solo leen) también, para
-- normalizar palabras y "probar el clasificador" desde Configuración.
REVOKE ALL ON FUNCTION public.fn_resolver_por_revisar(BIGINT, NUMERIC, TEXT, INT, INT, TIMESTAMPTZ, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_resolver_por_revisar(BIGINT, NUMERIC, TEXT, INT, INT, TIMESTAMPTZ, TEXT, TEXT, TEXT, TEXT) TO retool_panel;
GRANT EXECUTE ON FUNCTION public.fn_normalizar(TEXT)            TO retool_panel;
GRANT EXECUTE ON FUNCTION public.fn_clasificar(TEXT, INT, TEXT) TO retool_panel;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON FUNCTION public.fn_resolver_por_revisar(BIGINT, NUMERIC, TEXT, INT, INT, TIMESTAMPTZ, TEXT, TEXT, TEXT, TEXT)
            FROM anon, authenticated;
    END IF;
END
$$;

SET LOCAL client_min_messages = notice;    -- vuelve a mostrar avisos (resultado de las pruebas)

-- ---------------------------------------------------------------------
-- 7. Pruebas de permisos (dentro de la transacción: si una falla,
--    RAISE EXCEPTION deshace TODO el script y no queda nada a medias).
--    has_table_privilege & cía. ≈ HAS_PERMS_BY_NAME de SQL Server.
--    Las pruebas de COMPORTAMIENTO (entrar como el rol e intentar cosas)
--    están en sql/pruebas/12_rol_retool_pruebas.sql.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    fallas TEXT;
    r CONSTANT TEXT := 'retool_panel';
BEGIN
    SELECT string_agg(prueba, '; ') INTO fallas
    FROM (VALUES
        ('el rol puede entrar pero no es superusuario ni salta RLS',
            (SELECT rolcanlogin AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcreaterole AND NOT rolcreatedb
             FROM pg_roles WHERE rolname = r)),
        ('lee todas las tablas y vistas del panel',
            (SELECT bool_and(has_table_privilege(r, 'public.' || t, 'SELECT'))
             FROM unnest(ARRAY['entidades','cuentas','categorias','diccionario','fuentes','frases_sentido',
                               'presupuestos','movimientos','correos_raw','ejecuciones',
                               'alertas','umbrales_presupuesto','parametros','v_alertas_pendientes',
                               'v_movimientos_contables','v_gasto_mensual','v_gasto_categoria_mes',
                               'v_avance_presupuesto','v_salud_sistema']) AS t)),
        ('no tiene DELETE ni TRUNCATE en ninguna tabla',
            NOT EXISTS (SELECT 1 FROM pg_class c
                        WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p')
                          AND (has_table_privilege(r, c.oid, 'DELETE')
                            OR has_table_privilege(r, c.oid, 'TRUNCATE')))),
        ('alertas: solo lectura; de parametros solo cambia el valor',
            NOT has_table_privilege(r, 'public.alertas', 'INSERT')
            AND NOT has_table_privilege(r, 'public.alertas', 'UPDATE')
            AND has_column_privilege(r, 'public.parametros', 'valor', 'UPDATE')
            AND NOT has_column_privilege(r, 'public.parametros', 'clave', 'UPDATE')
            AND NOT has_table_privilege(r, 'public.parametros', 'INSERT')),
        ('no ejecuta fn_generar_alertas (eso es de Apps Script)',
            NOT has_function_privilege(r, 'public.fn_generar_alertas()', 'EXECUTE')),
        ('no ve telegram_updates',
            NOT has_table_privilege(r, 'public.telegram_updates', 'SELECT')),
        ('no inserta movimientos directo (solo vía la función)',
            NOT has_table_privilege(r, 'public.movimientos', 'INSERT')),
        ('corrige la categoría pero no el monto, la fecha ni la cuenta',
            has_column_privilege(r, 'public.movimientos', 'id_categoria', 'UPDATE')
            AND NOT has_column_privilege(r, 'public.movimientos', 'monto', 'UPDATE')
            AND NOT has_column_privilege(r, 'public.movimientos', 'fecha', 'UPDATE')
            AND NOT has_column_privilege(r, 'public.movimientos', 'id_cuenta', 'UPDATE')),
        ('no cambia el cuerpo ni el remitente de un correo',
            NOT has_column_privilege(r, 'public.correos_raw', 'cuerpo', 'UPDATE')
            AND NOT has_column_privilege(r, 'public.correos_raw', 'remitente', 'UPDATE')),
        ('una palabra creada en Retool no puede fingir ser del bot',
            has_column_privilege(r, 'public.diccionario', 'palabra', 'INSERT')
            AND NOT has_column_privilege(r, 'public.diccionario', 'origen', 'INSERT')),
        ('ejecuta fn_resolver_por_revisar; PUBLIC no',
            has_function_privilege(r, 'public.fn_resolver_por_revisar(bigint,numeric,text,integer,integer,timestamptz,text,text,text,text)', 'EXECUTE')
            AND NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                            WHERE p.oid = 'public.fn_resolver_por_revisar(bigint,numeric,text,integer,integer,timestamptz,text,text,text,text)'::regprocedure
                              AND a.grantee = 0)),   -- grantee 0 = PUBLIC
        ('cada tabla que lee tiene su política RLS para el rol',
            (SELECT count(DISTINCT tablename) FROM pg_policies
             WHERE schemaname = 'public' AND r = ANY (roles)) >= 13)   -- >= : sql/13 agrega conciliacion_revision
    ) AS t(prueba, ok)
    WHERE ok IS NOT TRUE;     -- NULL también cuenta como falla

    IF fallas IS NOT NULL THEN
        RAISE EXCEPTION 'Pruebas de 12_rol_retool fallidas: %', fallas;
    END IF;
    RAISE NOTICE '12_rol_retool: 12/12 pruebas de permisos OK';
END
$$;

COMMIT;

-- =====================================================================
-- Vistazo (solo lee): qué puede hacer retool_panel en cada tabla.
-- =====================================================================
SELECT table_name,
       string_agg(DISTINCT privilege_type, ', ' ORDER BY privilege_type) AS permisos_tabla
FROM information_schema.role_table_grants
WHERE grantee = 'retool_panel'
GROUP BY table_name
ORDER BY table_name;

SELECT table_name, privilege_type, string_agg(column_name, ', ' ORDER BY column_name) AS columnas
FROM information_schema.column_privileges
WHERE grantee = 'retool_panel' AND privilege_type IN ('INSERT', 'UPDATE')
  AND (table_name, privilege_type) NOT IN (SELECT table_name, privilege_type
                                           FROM information_schema.role_table_grants
                                           WHERE grantee = 'retool_panel')
GROUP BY table_name, privilege_type
ORDER BY table_name, privilege_type;

-- Para quitar el acceso de Retool por completo (p. ej. si se filtró la contraseña):
--   ALTER ROLE retool_panel NOLOGIN;            -- corta el acceso al instante
--   ALTER ROLE retool_panel WITH PASSWORD NULL; -- y borra la contraseña
