-- =====================================================================
-- 01_esquema.sql · Sistema de finanzas personales automatizado
-- Base: Supabase (PostgreSQL 15+) · Ejecutar en: SQL Editor
--
-- Qué crea: 9 tablas, 1 trigger, 5 vistas, RLS y permisos.
-- Idempotente: se puede ejecutar N veces sin error ni duplicados
--   (IF NOT EXISTS, CREATE OR REPLACE). Ojo: si una tabla YA existe,
--   CREATE TABLE IF NOT EXISTS no le aplica cambios nuevos; los cambios
--   de estructura futuros irán en scripts numerados (03_..., 04_...).
--
-- Convenciones (sección 6 del documento del proyecto):
--   · snake_case en español.
--   · Montos NUMERIC(12,2) siempre > 0; el signo lo da "sentido".
--   · Fechas TIMESTAMPTZ; los reportes convierten a America/Lima.
--   · Borrado lógico: activo = false / estado = 'anulado'.
-- =====================================================================

BEGIN;  -- Todo o nada: si algo falla, no queda un esquema a medias.
        -- (SQL Server: BEGIN TRAN ... COMMIT TRAN)

-- ---------------------------------------------------------------------
-- Diferencias clave con SQL Server que verás en este script
-- ---------------------------------------------------------------------
-- · GENERATED ALWAYS AS IDENTITY  ≈ IDENTITY(1,1). "ALWAYS" impide
--   insertar el id a mano por error (como no activar IDENTITY_INSERT).
-- · TIMESTAMPTZ ≈ DATETIMEOFFSET, pero NO guarda el offset: convierte
--   todo a UTC al guardar y lo muestra en la zona de la sesión. Por eso
--   las vistas usan "fecha AT TIME ZONE 'America/Lima'".
-- · TEXT ≈ NVARCHAR(MAX), sin penalidad de rendimiento en PostgreSQL.
-- · BOOLEAN ≈ BIT, pero acepta true/false.
-- · CHECK (col IN (...)) en vez de ENUM: un ENUM de PostgreSQL es un
--   tipo propio; agregarle valores es fácil pero quitarlos no. Un CHECK
--   se cambia con un ALTER TABLE y se entiende igual que en SQL Server.
-- · Índice único PARCIAL (WHERE ...) ≈ "filtered index" de SQL Server.
-- · CREATE OR REPLACE / IF NOT EXISTS ≈ CREATE OR ALTER / IF OBJECT_ID.

-- =====================================================================
-- 1. CATÁLOGOS (configuración en tablas, no en código)
-- =====================================================================

-- entidades: bancos, billeteras, apps y efectivo.
-- Separada de cuentas porque una entidad (BCP) tiene varias cuentas
-- (débito, Yape). Agregar un banco = insertar filas, no cambiar el modelo.
CREATE TABLE IF NOT EXISTS public.entidades (
    id_entidad  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre      TEXT    NOT NULL UNIQUE,
    tipo        TEXT    NOT NULL CHECK (tipo IN ('banco','billetera','app','efectivo')),
    activo      BOOLEAN NOT NULL DEFAULT true
);

-- cuentas: de dónde sale o a dónde entra el dinero.
CREATE TABLE IF NOT EXISTS public.cuentas (
    id_cuenta   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_entidad  INT     NOT NULL REFERENCES public.entidades (id_entidad),
    tipo        TEXT    NOT NULL CHECK (tipo IN ('debito','credito','yape','billetera')),
    alias       TEXT    NOT NULL UNIQUE,   -- clave natural: las semillas buscan por alias
    moneda      CHAR(3) NOT NULL DEFAULT 'PEN' CHECK (moneda IN ('PEN','USD')),
    activo      BOOLEAN NOT NULL DEFAULT true
);

-- categorias. tipo 'transferencia' = mover dinero entre MIS cuentas
-- (p. ej. retiro en agente: sale del débito y entra al efectivo).
-- No es gasto ni ingreso, así que las vistas lo excluyen de los totales
-- para no contar dos veces (el retiro y luego el gasto en efectivo).
CREATE TABLE IF NOT EXISTS public.categorias (
    id_categoria INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre       TEXT    NOT NULL UNIQUE,
    tipo         TEXT    NOT NULL CHECK (tipo IN ('egreso','ingreso','transferencia')),
    icono        TEXT,
    activo       BOOLEAN NOT NULL DEFAULT true
);

-- diccionario: palabra → categoría. Lo usan el bot y el clasificador.
-- El CHECK obliga a guardar la palabra normalizada (minúsculas, sin
-- tildes, sin espacios extremos); Apps Script normaliza igual el texto
-- de entrada antes de buscar. Así "Menú", "MENU" y "menu" coinciden.
CREATE TABLE IF NOT EXISTS public.diccionario (
    id           INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    palabra      TEXT    NOT NULL UNIQUE CHECK (palabra ~ '^[a-zñ0-9]+( [a-zñ0-9]+)*$'),
    id_categoria INT     NOT NULL REFERENCES public.categorias (id_categoria),
    activo       BOOLEAN NOT NULL DEFAULT true,
    creado_en    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- fuentes: remitentes/asuntos de correo configurados.
-- remitente_patron y asunto_patron son EXPRESIONES REGULARES sin
-- distinguir mayúsculas (las evalúa Apps Script con RegExp(..., 'i')).
-- accion = 'ignorar' permite descartar correos (rechazos, órdenes
-- pendientes) por configuración, sin tocar código.
-- prioridad: menor número = se evalúa primero (las reglas de ignorar
-- van antes que las generales).
CREATE TABLE IF NOT EXISTS public.fuentes (
    id_fuente            INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre               TEXT    NOT NULL UNIQUE,
    remitente_patron     TEXT    NOT NULL,
    asunto_patron        TEXT,                        -- NULL = cualquier asunto
    accion               TEXT    NOT NULL DEFAULT 'procesar' CHECK (accion IN ('procesar','ignorar')),
    extractor            TEXT,                        -- nombre de la función en Extractores.gs o 'generico'
    id_cuenta_defecto    INT REFERENCES public.cuentas (id_cuenta),
    id_categoria_defecto INT REFERENCES public.categorias (id_categoria),
    sentido_defecto      TEXT CHECK (sentido_defecto IN ('ingreso','egreso')),
    prioridad            INT     NOT NULL DEFAULT 100,
    activo               BOOLEAN NOT NULL DEFAULT true,
    -- Si se procesa, debe saberse con qué extractor.
    CONSTRAINT ck_fuentes_extractor CHECK (accion = 'ignorar' OR extractor IS NOT NULL)
);

-- =====================================================================
-- 2. DATOS DE OPERACIÓN
-- =====================================================================

-- correos_raw: copia del correo original. Sirve para trazabilidad
-- (de dónde salió cada movimiento) y para reprocesar si un extractor
-- tenía un error, sin volver a leer Gmail.
-- gmail_message_id UNIQUE = primera barrera de idempotencia: el mismo
-- correo no puede entrar dos veces.
-- estado 'pendiente': guardado pero aún no procesado. Si el script se
-- cae a la mitad, queda visible en vez de perderse.
CREATE TABLE IF NOT EXISTS public.correos_raw (
    id_correo        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gmail_message_id TEXT        NOT NULL UNIQUE,
    remitente        TEXT        NOT NULL,
    asunto           TEXT,
    fecha_correo     TIMESTAMPTZ NOT NULL,
    cuerpo           TEXT,
    id_fuente        INT REFERENCES public.fuentes (id_fuente),   -- NULL = fuente desconocida
    estado           TEXT        NOT NULL DEFAULT 'pendiente'
                     CHECK (estado IN ('pendiente','procesado','por_revisar','ignorado','error')),
    detalle_error    TEXT,
    datos_extraidos  JSONB,      -- campos prellenados para "Por revisar" (JSONB ≈ NVARCHAR + JSON_VALUE, pero indexable)
    sugerido_por_ia  BOOLEAN     NOT NULL DEFAULT false,
    creado_en        TIMESTAMPTZ NOT NULL DEFAULT now(),
    procesado_en     TIMESTAMPTZ
);

-- movimientos: tabla central, UNA sola para todas las entidades
-- (diseño normalizado: un banco nuevo no crea tablas nuevas).
CREATE TABLE IF NOT EXISTS public.movimientos (
    id_movimiento           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fecha                   TIMESTAMPTZ   NOT NULL,
    monto                   NUMERIC(12,2) NOT NULL CHECK (monto > 0),   -- NUMERIC, no FLOAT: exacto para dinero
    moneda                  CHAR(3)       NOT NULL DEFAULT 'PEN' CHECK (moneda IN ('PEN','USD')),
    sentido                 TEXT          NOT NULL CHECK (sentido IN ('ingreso','egreso')),
    id_cuenta               INT           NOT NULL REFERENCES public.cuentas (id_cuenta),
    id_categoria            INT           REFERENCES public.categorias (id_categoria),  -- NULL = sin clasificar
    descripcion             TEXT,
    contraparte             TEXT,
    numero_operacion        TEXT,         -- TEXT: puede tener ceros a la izquierda
    origen                  TEXT          NOT NULL CHECK (origen IN ('correo','telegram','manual','recurrente')),
    -- UNIQUE: un correo genera como máximo un movimiento.
    -- PostgreSQL permite varios NULL en un UNIQUE (SQL Server solo uno),
    -- así que los movimientos del bot (sin correo) no chocan entre sí.
    id_correo               BIGINT        UNIQUE REFERENCES public.correos_raw (id_correo),
    -- Conciliación: el recibo (p. ej. Uber) apunta al movimiento bancario.
    id_movimiento_vinculado BIGINT        REFERENCES public.movimientos (id_movimiento),
    estado                  TEXT          NOT NULL DEFAULT 'activo' CHECK (estado IN ('activo','anulado')),
    creado_en               TIMESTAMPTZ   NOT NULL DEFAULT now(),
    actualizado_en          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT ck_mov_correo   CHECK (origen <> 'correo' OR id_correo IS NOT NULL),
    CONSTRAINT ck_mov_vinculo  CHECK (id_movimiento_vinculado IS DISTINCT FROM id_movimiento)
);

-- Segunda barrera de idempotencia: el mismo número de operación no se
-- repite en la misma cuenta. Índice PARCIAL: solo aplica cuando hay
-- número de operación (el efectivo y el bot no lo tienen).
-- SQL Server: CREATE UNIQUE INDEX ... WHERE numero_operacion IS NOT NULL
-- (filtered index); la idea es la misma.
CREATE UNIQUE INDEX IF NOT EXISTS ux_mov_cuenta_operacion
    ON public.movimientos (id_cuenta, numero_operacion)
    WHERE numero_operacion IS NOT NULL;

-- Índices para los filtros más usados (por fecha, por categoría).
-- PostgreSQL, igual que SQL Server, NO indexa las FK automáticamente.
CREATE INDEX IF NOT EXISTS ix_mov_fecha           ON public.movimientos (fecha);
CREATE INDEX IF NOT EXISTS ix_mov_categoria_fecha ON public.movimientos (id_categoria, fecha);
CREATE INDEX IF NOT EXISTS ix_mov_vinculado       ON public.movimientos (id_movimiento_vinculado)
    WHERE id_movimiento_vinculado IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_correos_estado      ON public.correos_raw (estado);

-- presupuestos: límite mensual por categoría con historial.
-- Para cambiar un presupuesto se inserta una fila con nueva fecha
-- (no se pisa la anterior), así los meses pasados se comparan con el
-- límite que tenían entonces.
CREATE TABLE IF NOT EXISTS public.presupuestos (
    id             INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_categoria   INT           NOT NULL REFERENCES public.categorias (id_categoria),
    monto_mensual  NUMERIC(12,2) NOT NULL CHECK (monto_mensual > 0),
    vigente_desde  DATE          NOT NULL DEFAULT date_trunc('month', now() AT TIME ZONE 'America/Lima')::date
                   CHECK (EXTRACT(DAY FROM vigente_desde) = 1),   -- siempre el día 1 del mes
    CONSTRAINT uq_presupuesto UNIQUE (id_categoria, vigente_desde)
);

-- ejecuciones: monitoreo. Cada corrida de un activador deja una fila.
CREATE TABLE IF NOT EXISTS public.ejecuciones (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    proceso      TEXT        NOT NULL CHECK (proceso IN ('captura','bot','alertas','latido')),
    inicio       TIMESTAMPTZ NOT NULL DEFAULT now(),
    fin          TIMESTAMPTZ,
    leidos       INT NOT NULL DEFAULT 0,
    insertados   INT NOT NULL DEFAULT 0,
    por_revisar  INT NOT NULL DEFAULT 0,
    errores      INT NOT NULL DEFAULT 0,
    llamadas_ia  INT NOT NULL DEFAULT 0,   -- sección 8.1: medir uso y fallos de Gemini
    detalle      TEXT,
    CONSTRAINT ck_ejec_fin CHECK (fin IS NULL OR fin >= inicio)
);
CREATE INDEX IF NOT EXISTS ix_ejec_proceso_inicio ON public.ejecuciones (proceso, inicio DESC);

-- Comentarios: aparecen como descripción en el Table Editor de Supabase.
COMMENT ON TABLE public.movimientos  IS 'Tabla central: un registro por ingreso o egreso, de cualquier entidad.';
COMMENT ON TABLE public.correos_raw  IS 'Copia del correo original para trazabilidad y reprocesamiento.';
COMMENT ON TABLE public.fuentes      IS 'Remitentes/asuntos configurados (regex) y el extractor que les corresponde.';
COMMENT ON TABLE public.diccionario  IS 'Palabra normalizada → categoría, para el bot y el clasificador.';
COMMENT ON TABLE public.ejecuciones  IS 'Registro de cada ejecución de los activadores (monitoreo).';

-- =====================================================================
-- 3. TRIGGER: actualizado_en automático
-- =====================================================================
-- Diferencia con SQL Server: allá harías un trigger AFTER UPDATE que
-- hace UPDATE ... FROM inserted. En PostgreSQL el trigger es una
-- FUNCIÓN aparte + un trigger BEFORE UPDATE FOR EACH ROW que modifica
-- la fila NEW antes de guardarla (sin un segundo UPDATE).
-- SET search_path = '' es la práctica que recomienda Supabase para
-- que nadie pueda "secuestrar" la función con un objeto de otro esquema.
CREATE OR REPLACE FUNCTION public.fn_set_actualizado_en()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    NEW.actualizado_en := now();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_movimientos_actualizado_en   -- OR REPLACE: PostgreSQL 14+
    BEFORE UPDATE ON public.movimientos
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_set_actualizado_en();

-- =====================================================================
-- 4. VISTAS (la lógica de negocio de los reportes vive en SQL)
-- =====================================================================
-- security_invoker = true: la vista se consulta con los permisos de
-- quien la llama (no de su dueño), así respeta RLS. Supabase lo marca
-- como alerta de seguridad si falta.

-- Base común: qué movimientos cuentan en los totales.
--  · estado 'activo' (los anulados no cuentan).
--  · sin id_movimiento_vinculado: el recibo conciliado NO cuenta; cuenta
--    el movimiento bancario al que apunta (evita doble conteo).
--  · categorías de tipo 'transferencia' se marcan aparte.
-- Las fechas se pasan a hora de Lima ANTES de agrupar: un gasto del
-- 31/10 a las 23:00 en Lima es 01/11 en UTC y caería en otro mes.
CREATE OR REPLACE VIEW public.v_movimientos_contables
WITH (security_invoker = true) AS
SELECT
    m.id_movimiento,
    (m.fecha AT TIME ZONE 'America/Lima')                         AS fecha_lima,
    date_trunc('day',   m.fecha AT TIME ZONE 'America/Lima')::date AS dia,
    date_trunc('week',  m.fecha AT TIME ZONE 'America/Lima')::date AS semana,  -- semana empieza lunes
    date_trunc('month', m.fecha AT TIME ZONE 'America/Lima')::date AS mes,
    date_trunc('year',  m.fecha AT TIME ZONE 'America/Lima')::date AS anio,
    m.monto, m.moneda, m.sentido,
    c.alias                                AS cuenta,
    COALESCE(cat.nombre, 'Sin categoría')  AS categoria,
    COALESCE(cat.tipo = 'transferencia', false) AS es_transferencia,
    m.descripcion, m.contraparte, m.origen
FROM public.movimientos m
JOIN public.cuentas c          ON c.id_cuenta = m.id_cuenta
LEFT JOIN public.categorias cat ON cat.id_categoria = m.id_categoria
WHERE m.estado = 'activo'
  AND m.id_movimiento_vinculado IS NULL;

-- Total por mes. FILTER es propio de PostgreSQL; en SQL Server sería
-- SUM(CASE WHEN sentido = 'ingreso' THEN monto ELSE 0 END).
CREATE OR REPLACE VIEW public.v_gasto_mensual
WITH (security_invoker = true) AS
SELECT
    mes,
    moneda,
    COALESCE(SUM(monto) FILTER (WHERE sentido = 'ingreso' AND NOT es_transferencia), 0) AS ingresos,
    COALESCE(SUM(monto) FILTER (WHERE sentido = 'egreso'  AND NOT es_transferencia), 0) AS egresos,
    COALESCE(SUM(monto) FILTER (WHERE sentido = 'ingreso' AND NOT es_transferencia), 0)
  - COALESCE(SUM(monto) FILTER (WHERE sentido = 'egreso'  AND NOT es_transferencia), 0) AS balance,
    COUNT(*) FILTER (WHERE NOT es_transferencia)                                        AS cantidad
FROM public.v_movimientos_contables
GROUP BY mes, moneda;

-- Total por categoría y mes (sin transferencias).
CREATE OR REPLACE VIEW public.v_gasto_categoria_mes
WITH (security_invoker = true) AS
SELECT mes, moneda, sentido, categoria,
       SUM(monto) AS total,
       COUNT(*)   AS cantidad
FROM public.v_movimientos_contables
WHERE NOT es_transferencia
GROUP BY mes, moneda, sentido, categoria;

-- Avance del presupuesto del MES ACTUAL (hora de Lima).
-- DISTINCT ON (id_categoria) ... ORDER BY vigente_desde DESC toma el
-- presupuesto vigente más reciente de cada categoría. Es propio de
-- PostgreSQL; en SQL Server usarías ROW_NUMBER() OVER (PARTITION BY
-- id_categoria ORDER BY vigente_desde DESC) y filtrarías rn = 1.
CREATE OR REPLACE VIEW public.v_avance_presupuesto
WITH (security_invoker = true) AS
WITH mes_actual AS (
    SELECT date_trunc('month', now() AT TIME ZONE 'America/Lima')::date AS mes
),
vigente AS (
    SELECT DISTINCT ON (p.id_categoria)
           p.id_categoria, p.monto_mensual
    FROM public.presupuestos p, mes_actual ma
    WHERE p.vigente_desde <= ma.mes
    ORDER BY p.id_categoria, p.vigente_desde DESC
),
gastado AS (
    SELECT m.id_categoria, SUM(m.monto) AS total
    FROM public.movimientos m, mes_actual ma
    WHERE m.estado = 'activo'
      AND m.id_movimiento_vinculado IS NULL
      AND m.sentido = 'egreso'
      AND m.moneda  = 'PEN'
      AND date_trunc('month', m.fecha AT TIME ZONE 'America/Lima')::date = ma.mes
    GROUP BY m.id_categoria
)
SELECT
    ma.mes,
    cat.nombre                                       AS categoria,
    v.monto_mensual                                  AS limite,
    COALESCE(g.total, 0)                             AS gastado,
    v.monto_mensual - COALESCE(g.total, 0)           AS disponible,
    ROUND(100 * COALESCE(g.total, 0) / v.monto_mensual, 1) AS porcentaje,
    CASE
        WHEN COALESCE(g.total, 0) >= v.monto_mensual       THEN 'excedido'
        WHEN COALESCE(g.total, 0) >= 0.8 * v.monto_mensual THEN 'alerta'
        ELSE 'ok'
    END                                              AS estado
FROM vigente v
CROSS JOIN mes_actual ma
JOIN public.categorias cat ON cat.id_categoria = v.id_categoria
LEFT JOIN gastado g        ON g.id_categoria  = v.id_categoria
WHERE cat.activo;

-- Salud del sistema: una sola fila para el panel "Salud" de Retool y
-- para la alerta de "más de 24 h sin ejecución".
CREATE OR REPLACE VIEW public.v_salud_sistema
WITH (security_invoker = true) AS
SELECT
    (SELECT MAX(inicio) FROM public.ejecuciones)                               AS ultima_ejecucion,
    (SELECT MAX(inicio) FROM public.ejecuciones WHERE proceso = 'captura')     AS ultima_captura,
    ROUND(EXTRACT(EPOCH FROM now() - (SELECT MAX(inicio) FROM public.ejecuciones)) / 3600, 1)
                                                                               AS horas_sin_ejecucion,
    (SELECT COALESCE(SUM(errores), 0) FROM public.ejecuciones
      WHERE inicio >= now() - INTERVAL '24 hours')                             AS errores_24h,
    (SELECT COUNT(*) FROM public.correos_raw WHERE estado = 'por_revisar')     AS por_revisar,
    (SELECT COUNT(*) FROM public.correos_raw WHERE estado IN ('error','pendiente')) AS correos_error_o_pendientes,
    (SELECT COUNT(*) FROM public.movimientos
      WHERE estado = 'activo' AND id_categoria IS NULL)                        AS sin_categoria,
    CASE
        WHEN (SELECT MAX(inicio) FROM public.ejecuciones) IS NULL
          OR (SELECT MAX(inicio) FROM public.ejecuciones) < now() - INTERVAL '24 hours' THEN 'alerta: sin ejecuciones en 24 h'
        WHEN (SELECT COALESCE(SUM(errores), 0) FROM public.ejecuciones
               WHERE inicio >= now() - INTERVAL '24 hours') > 0                 THEN 'revisar: hay errores en 24 h'
        ELSE 'ok'
    END                                                                        AS estado;

-- =====================================================================
-- 5. SEGURIDAD: RLS y permisos
-- =====================================================================
-- RLS activado SIN políticas = nadie con las claves públicas (anon,
-- authenticated) puede leer ni escribir. La service_role (solo Apps
-- Script, guardada en Propiedades del script) se salta RLS por diseño.
-- El proyecto ya activa RLS automáticamente; lo repetimos para que el
-- script sea reproducible en cualquier proyecto (ENABLE es idempotente).
ALTER TABLE public.entidades    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cuentas      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categorias   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.diccionario  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fuentes      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.correos_raw  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.movimientos  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.presupuestos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ejecuciones  ENABLE ROW LEVEL SECURITY;

-- Con "exponer tablas automáticamente" desactivado, las tablas nuevas no
-- reciben permisos para la API REST. Damos acceso SOLO a service_role
-- (Apps Script usa la API REST) y quitamos todo a anon/authenticated
-- (defensa en profundidad: aunque falle RLS, no hay permiso).
-- El bloque DO verifica que los roles existan, para que el script
-- también corra en un PostgreSQL local de pruebas.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT USAGE ON SCHEMA public TO service_role;
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO service_role;
        GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA public TO service_role;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon;
        REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM authenticated;
        REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM authenticated;
    END IF;
END
$$;

COMMIT;
