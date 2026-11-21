-- =====================================================================
-- 10_frases_sentido.sql · Frases que deciden si un mensaje del bot es
-- INGRESO o GASTO (configuración en lugar de código)
-- Requiere: 01 a 09. Idempotente (se puede correr varias veces).
--
-- Bug que corrige (20/11): "me han yapeado 1 sol" se registró como gasto.
-- La lista de frases de ingreso estaba escrita en logica.ts y solo tenía
-- "me yapearon"; cualquier otra forma ("me han yapeado", "me yapeó",
-- "me abonaron"...) caía en el valor por defecto: egreso.
--
-- Ahora las frases viven aquí. Agregar una = un INSERT (o editarla en
-- Retool), sin volver a desplegar la Edge Function. El bot las lee cada
-- 60 s; si esta tabla falla, usa una lista corta de respaldo del código.
--
-- Regla (la misma que fn_clasificar en sql/09):
--   · Frase COMPLETA, palabra por palabra ("gane" no coincide con "ganesha").
--   · Si coinciden varias, gana la MÁS LARGA. Por eso existe la columna
--     sentido también para egreso: "se me cayo" (perdí plata → egreso)
--     le gana a "me cayo" (me cayó plata → ingreso).
--   · Sin frase → egreso (lo más común en el bot).
--
-- PostgreSQL vs SQL Server:
--   · INSERT ... ON CONFLICT (frase) DO NOTHING ≈ MERGE ... WHEN NOT MATCHED
--     THEN INSERT (o IF NOT EXISTS). Es lo que hace el script idempotente.
--   · CROSS JOIN LATERAL (VALUES ...) ≈ CROSS APPLY (VALUES ...): por cada
--     verbo genera sus conjugaciones, en vez de escribir 80 filas a mano.
--   · El CHECK con ~ (expresión regular) no existe en SQL Server; allá
--     sería LIKE o una función CLR.
-- =====================================================================
BEGIN;

CREATE TABLE IF NOT EXISTS public.frases_sentido (
    id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,   -- ≈ IDENTITY(1,1)
    -- Normalizada igual que diccionario.palabra (minúsculas, sin tildes):
    -- el bot compara contra el texto normalizado.
    frase     TEXT        NOT NULL UNIQUE CHECK (frase ~ '^[a-zñ0-9]+( [a-zñ0-9]+)*$'),
    sentido   TEXT        NOT NULL CHECK (sentido IN ('ingreso', 'egreso')),
    activo    BOOLEAN     NOT NULL DEFAULT true,
    creado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.frases_sentido IS
    'Frases del bot que fijan el sentido (ingreso/egreso). Gana la más larga. Sin frase → egreso.';

-- Seguridad igual que el resto: RLS sin políticas + permisos solo a service_role.
ALTER TABLE public.frases_sentido ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON public.frases_sentido TO service_role;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON public.frases_sentido FROM anon, authenticated;
    END IF;
END
$$;

-- ---------------------------------------------------------------------
-- 1. Ingresos generados: "me" + verbo conjugado.
--    Columnas: pretérito plural · pretérito singular · participio · infinitivo
--    (me pagaron · me pagó · me han pagado · me acaban de pagar)
-- ---------------------------------------------------------------------
INSERT INTO public.frases_sentido (frase, sentido)
SELECT DISTINCT public.fn_normalizar(f.frase), 'ingreso'
FROM (VALUES
    ('yapearon',      'yapeó',      'yapeado',      'yapear'),
    ('plinearon',     'plineó',     'plineado',     'plinear'),
    ('pagaron',       'pagó',       'pagado',       'pagar'),
    ('depositaron',   'depositó',   'depositado',   'depositar'),
    ('transfirieron', 'transfirió', 'transferido',  'transferir'),
    ('abonaron',      'abonó',      'abonado',      'abonar'),
    ('devolvieron',   'devolvió',   'devuelto',     'devolver'),
    ('reembolsaron',  'reembolsó',  'reembolsado',  'reembolsar'),
    ('dieron',        'dio',        'dado',         'dar'),
    ('pasaron',       'pasó',       'pasado',       'pasar'),
    ('enviaron',      'envió',      'enviado',      'enviar'),
    ('mandaron',      'mandó',      'mandado',      'mandar'),
    ('giraron',       'giró',       'girado',       'girar'),
    ('regalaron',     'regaló',     'regalado',     'regalar'),
    ('prestaron',     'prestó',     'prestado',     'prestar'),
    ('cancelaron',    'canceló',    'cancelado',    'cancelar'),   -- peruanismo: "me canceló la deuda"
    ('cayeron',       'cayó',       'caído',        'caer'),       -- "me cayó plata"
    ('llegaron',      'llegó',      'llegado',      'llegar')      -- "me llegó el sueldo"
) AS v(pret_pl, pret_sg, participio, infinitivo)
CROSS JOIN LATERAL (VALUES
    ('me ' || v.pret_pl),
    ('me ' || v.pret_sg),
    ('me han ' || v.participio),
    ('me ha ' || v.participio),
    ('me acaban de ' || v.infinitivo),
    ('me acaba de ' || v.infinitivo)
) AS f(frase)
ON CONFLICT (frase) DO NOTHING;

-- ---------------------------------------------------------------------
-- 2. Ingresos sueltos y frases de egreso que deben ganarle a una de ingreso.
-- ---------------------------------------------------------------------
INSERT INTO public.frases_sentido (frase, sentido)
SELECT public.fn_normalizar(v.frase), v.sentido
FROM (VALUES
    ('recibí',                    'ingreso'),
    ('cobré',                     'ingreso'),
    ('gané',                      'ingreso'),
    ('vendí',                     'ingreso'),
    ('ingreso',                   'ingreso'),
    ('me hicieron un yape',       'ingreso'),
    ('me hicieron un plin',       'ingreso'),
    ('me hicieron una transferencia', 'ingreso'),
    ('me hicieron un depósito',   'ingreso'),
    ('me pagan',                  'ingreso'),
    ('me yapean',                 'ingreso'),
    -- Egreso explícito: más largas que su "gemela" de ingreso, así ganan.
    ('se me cayó',                'egreso'),   -- perdí plata  (vs "me cayó")
    ('se me cayeron',             'egreso'),
    ('le devolví',                'egreso'),
    ('le presté',                 'egreso'),
    ('le pagué',                  'egreso'),
    ('le yapeé',                  'egreso'),
    ('me cobraron',               'egreso')
) AS v(frase, sentido)
ON CONFLICT (frase) DO NOTHING;

COMMIT;

-- =====================================================================
-- Pruebas (solo leen). Cada fila debe decir ok = true.
-- =====================================================================
SELECT prueba, ok FROM (VALUES
    ('todas las frases están normalizadas',
        NOT EXISTS (SELECT 1 FROM public.frases_sentido WHERE frase <> public.fn_normalizar(frase))),
    ('existe "me han yapeado" (el bug del 20/11)',
        EXISTS (SELECT 1 FROM public.frases_sentido WHERE frase = 'me han yapeado' AND sentido = 'ingreso')),
    ('"se me cayo" es egreso y es más larga que "me cayo"',
        (SELECT sentido FROM public.frases_sentido WHERE frase = 'se me cayo') = 'egreso'
        AND EXISTS (SELECT 1 FROM public.frases_sentido WHERE frase = 'me cayo' AND sentido = 'ingreso'))
) AS t(prueba, ok);

-- Cuántas hay de cada tipo:
SELECT sentido, count(*) FROM public.frases_sentido GROUP BY sentido;

-- Agregar una frase nueva (sin tocar código):
--   INSERT INTO public.frases_sentido (frase, sentido)
--   VALUES (public.fn_normalizar('Me chapó el sencillo'), 'ingreso')
--   ON CONFLICT (frase) DO NOTHING;
-- Desactivarla sin borrarla:  UPDATE public.frases_sentido SET activo = false WHERE frase = '...';
