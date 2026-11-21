-- =====================================================================
-- sql/pruebas/12_rol_retool_pruebas.sql · Pruebas de COMPORTAMIENTO del
-- rol retool_panel (sql/12). Entra como el rol e intenta cosas permitidas
-- y prohibidas.
--
-- Requiere: sql/01 a sql/12 y los datos demo (sql/demo/datos_demo.sql).
-- Úsalo en la base DEMO o en un PostgreSQL local. No deja rastro: todo
-- corre dentro de una transacción que termina en ROLLBACK.
--
-- 12_rol_retool.sql ya prueba los PERMISOS (has_table_privilege...).
-- Este archivo prueba que la base REALMENTE se comporta así: un permiso
-- bien declarado pero una política RLS mal escrita solo se detecta
-- ejecutando la consulta como el rol.
--
-- PostgreSQL vs SQL Server:
--   · SET ROLE retool_panel ≈ EXECUTE AS USER = 'retool_panel' (y
--     RESET ROLE ≈ REVERT).
--   · EXCEPTION WHEN insufficient_privilege ≈ BEGIN TRY ... BEGIN CATCH
--     con ERROR_NUMBER() = 229 (permiso denegado).
-- =====================================================================
BEGIN;

-- Para "ser" retool_panel hay que ser miembro del rol. Se concede solo
-- dentro de esta transacción (el ROLLBACK final lo deshace).
GRANT retool_panel TO CURRENT_USER;
SET LOCAL ROLE retool_panel;

DO $$
DECLARE
    fallas  TEXT[] := '{}';
    ok      INT    := 0;
    n       BIGINT;
    v_id    BIGINT;
    v_id2   BIGINT;
    v_cat   INT;
    v_otro  INT;
    v_yape  INT;
BEGIN
    IF current_user <> 'retool_panel' THEN
        RAISE EXCEPTION 'Estas pruebas deben correr como retool_panel (current_user = %)', current_user;
    END IF;

    -- 1. RLS deja ver las filas (sin política vería 0) ------------------
    SELECT count(*) INTO n FROM public.movimientos;
    IF n > 0 THEN ok := ok + 1; ELSE fallas := fallas || 've 0 movimientos (falta política RLS)'; END IF;

    SELECT count(*) INTO n FROM public.v_gasto_mensual;
    IF n > 0 THEN ok := ok + 1; ELSE fallas := fallas || 'la vista v_gasto_mensual sale vacía'; END IF;

    -- 2. Lo prohibido falla con 42501 (insufficient_privilege) ----------
    BEGIN
        DELETE FROM public.movimientos WHERE false;
        fallas := fallas || 'pudo hacer DELETE en movimientos';
    EXCEPTION WHEN insufficient_privilege THEN ok := ok + 1;
    END;

    BEGIN
        UPDATE public.movimientos SET monto = monto WHERE false;
        fallas := fallas || 'pudo cambiar el monto';
    EXCEPTION WHEN insufficient_privilege THEN ok := ok + 1;
    END;

    BEGIN
        INSERT INTO public.movimientos (fecha, monto, sentido, id_cuenta, origen)
        VALUES (now(), 1, 'egreso', 1, 'manual');
        fallas := fallas || 'pudo insertar un movimiento directo';
    EXCEPTION WHEN insufficient_privilege THEN ok := ok + 1;
    END;

    BEGIN
        PERFORM 1 FROM public.telegram_updates;
        fallas := fallas || 'pudo leer telegram_updates';
    EXCEPTION WHEN insufficient_privilege THEN ok := ok + 1;
    END;

    BEGIN
        CREATE TABLE public.intruso (id INT);
        fallas := fallas || 'pudo crear una tabla';
    EXCEPTION WHEN insufficient_privilege THEN ok := ok + 1;
    END;

    BEGIN
        INSERT INTO public.diccionario (palabra, id_categoria, origen)
        VALUES ('prueba retool', 1, 'bot');
        fallas := fallas || 'pudo insertar una palabra como origen bot';
    EXCEPTION WHEN insufficient_privilege THEN ok := ok + 1;
    END;

    -- 3. Lo permitido funciona -----------------------------------------
    SELECT id_categoria INTO v_cat  FROM public.categorias WHERE nombre = 'Compras online';
    SELECT id_categoria INTO v_otro FROM public.categorias WHERE nombre = 'Otros ingresos';
    SELECT id_cuenta    INTO v_yape FROM public.cuentas    WHERE alias  = 'BCP Débito';

    UPDATE public.movimientos SET id_categoria = v_cat
    WHERE id_movimiento = (SELECT min(id_movimiento) FROM public.movimientos WHERE id_categoria IS NULL);
    GET DIAGNOSTICS n = ROW_COUNT;      -- ≈ @@ROWCOUNT
    IF n = 1 THEN ok := ok + 1; ELSE fallas := fallas || 'no pudo corregir la categoría'; END IF;

    INSERT INTO public.diccionario (palabra, id_categoria)
    VALUES (public.fn_normalizar('Tienda Ficticia'), v_cat);
    IF (SELECT origen FROM public.diccionario WHERE palabra = 'tienda ficticia') = 'manual'
    THEN ok := ok + 1; ELSE fallas := fallas || 'la palabra nueva no quedó como manual'; END IF;

    -- Presupuesto del mes: "upsert" (≈ MERGE). Requiere INSERT + UPDATE (monto_mensual).
    INSERT INTO public.presupuestos (id_categoria, monto_mensual, vigente_desde)
    VALUES (v_cat, 55, date_trunc('month', now() AT TIME ZONE 'America/Lima')::date)
    ON CONFLICT (id_categoria, vigente_desde) DO UPDATE SET monto_mensual = EXCLUDED.monto_mensual;
    IF EXISTS (SELECT 1 FROM public.v_avance_presupuesto WHERE categoria = 'Compras online' AND limite = 55)
    THEN ok := ok + 1; ELSE fallas := fallas || 'no pudo fijar el presupuesto del mes'; END IF;

    -- 4. "Por revisar": RLS no deja marcar 'procesado' a mano -----------
    BEGIN
        UPDATE public.correos_raw SET estado = 'procesado' WHERE gmail_message_id = 'demo-revisar-1';
        fallas := fallas || 'pudo marcar procesado un correo sin movimiento';
    EXCEPTION WHEN insufficient_privilege THEN ok := ok + 1;   -- "new row violates row-level security policy"
    END;

    -- Descartar sí; y un correo ya procesado ni se toca (USING lo filtra: 0 filas).
    UPDATE public.correos_raw SET estado = 'ignorado', detalle_error = 'Descartado en Retool'
    WHERE gmail_message_id = 'demo-revisar-1';
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n = 1 THEN ok := ok + 1; ELSE fallas := fallas || 'no pudo descartar un por revisar'; END IF;

    UPDATE public.correos_raw SET estado = 'ignorado'
    WHERE estado = 'procesado';
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n = 0 THEN ok := ok + 1; ELSE fallas := fallas || 'pudo cambiar correos ya procesados'; END IF;

    -- 5. fn_resolver_por_revisar ----------------------------------------
    BEGIN
        PERFORM public.fn_resolver_por_revisar(
            p_id_correo    => (SELECT id_correo FROM public.correos_raw WHERE gmail_message_id = 'demo-revisar-ia'),
            p_monto        => 59.90, p_sentido => 'egreso', p_id_cuenta => v_yape,
            p_id_categoria => v_otro);
        fallas := fallas || 'aceptó un egreso con categoría de ingreso';
    EXCEPTION WHEN raise_exception THEN ok := ok + 1;
    END;

    v_id := public.fn_resolver_por_revisar(
        p_id_correo    => (SELECT id_correo FROM public.correos_raw WHERE gmail_message_id = 'demo-revisar-ia'),
        p_monto        => 59.90, p_sentido => 'egreso', p_id_cuenta => v_yape,
        p_id_categoria => v_cat, p_contraparte => 'Tienda Ficticia SAC');
    IF EXISTS (SELECT 1 FROM public.movimientos m JOIN public.correos_raw c USING (id_correo)
               WHERE m.id_movimiento = v_id AND m.origen = 'correo' AND c.estado = 'procesado')
    THEN ok := ok + 1; ELSE fallas := fallas || 'resolver no creó el movimiento o no marcó el correo'; END IF;

    -- Doble clic: mismo id, sin duplicar.
    v_id2 := public.fn_resolver_por_revisar(
        p_id_correo => (SELECT id_correo FROM public.correos_raw WHERE gmail_message_id = 'demo-revisar-ia'),
        p_monto => 59.90, p_sentido => 'egreso', p_id_cuenta => v_yape);
    IF v_id2 = v_id THEN ok := ok + 1; ELSE fallas := fallas || 'resolver dos veces creó otro movimiento'; END IF;

    -- 6. Resultado -------------------------------------------------------
    IF cardinality(fallas) > 0 THEN
        RAISE EXCEPTION 'Pruebas del rol retool_panel fallidas (% OK): %', ok, array_to_string(fallas, '; ');
    END IF;
    RAISE NOTICE 'retool_panel: %/17 pruebas de comportamiento OK', ok;
END
$$;

ROLLBACK;   -- no deja nada: ni cambios de datos ni la membresía del rol
