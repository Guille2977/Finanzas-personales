-- =====================================================================
-- 07_bot_telegram.sql · Soporte para el bot de Telegram
-- Requiere: 01 a 06. Idempotente. Ejecutar ANTES de pegar Bot.gs.
--
-- 1. diccionario.origen: saber qué palabras escribiste tú ('manual') y
--    cuáles aprendió el bot al confirmar una categoría ('bot').
-- 2. Palabras típicas de gastos en efectivo / Yape.
-- 3. Índice para "deshacer" (último movimiento del bot).
--
-- No hace falta tabla de "propuestas pendientes": el botón de Telegram
-- lleva los datos en su callback_data y el update_id da la idempotencia
-- (numero_operacion = 'TG-<update_id>-<n>' + el UNIQUE que ya existía).
-- =====================================================================
BEGIN;

-- ADD COLUMN IF NOT EXISTS es propio de PostgreSQL. En SQL Server harías
-- IF COL_LENGTH('dbo.diccionario', 'origen') IS NULL ALTER TABLE ... ADD ...
-- Agregar una columna con DEFAULT constante no reescribe la tabla (PG 11+).
ALTER TABLE public.diccionario
    ADD COLUMN IF NOT EXISTS origen TEXT NOT NULL DEFAULT 'manual'
        CHECK (origen IN ('manual', 'bot'));

COMMENT ON COLUMN public.diccionario.origen IS 'manual = semilla o Retool; bot = aprendida al confirmar una categoría en Telegram.';

INSERT INTO public.diccionario (palabra, id_categoria)
SELECT v.palabra, c.id_categoria
FROM (VALUES
    ('almuerzo',  'Comida'),
    ('cena',      'Comida'),
    ('queque',    'Comida'),
    ('golosina',  'Comida'),
    ('galletas',  'Comida'),
    ('pan',       'Comida'),
    ('agua',      'Comida'),
    ('cafe',      'Comida'),
    ('pollo',     'Comida'),
    ('chifa',     'Comida'),
    ('combi',     'Transporte'),
    ('micro',     'Transporte'),
    ('bus',       'Transporte'),
    ('taxi',      'Transporte'),
    ('metropolitano', 'Transporte'),
    ('copias',    'Educación'),
    ('impresion', 'Educación')
) AS v(palabra, categoria)
JOIN public.categorias c ON c.nombre = v.categoria
ON CONFLICT (palabra) DO NOTHING;

-- "deshacer" busca el último movimiento activo del bot.
-- Índice PARCIAL (≈ filtered index de SQL Server): solo filas de Telegram.
CREATE INDEX IF NOT EXISTS ix_mov_telegram_creado
    ON public.movimientos (creado_en DESC)
    WHERE origen = 'telegram';

COMMIT;

-- Verificación
SELECT origen, COUNT(*) AS palabras FROM public.diccionario GROUP BY origen;

-- Consultas útiles una vez que uses el bot:
-- Palabras que aprendió el bot:
--   SELECT d.palabra, c.nombre, d.creado_en FROM public.diccionario d
--   JOIN public.categorias c USING (id_categoria) WHERE d.origen = 'bot' ORDER BY d.creado_en DESC;
--   (USING (col) ≈ ON a.col = b.col cuando la columna se llama igual; no existe en SQL Server)
-- Uso de la IA por día:
--   SELECT inicio::date AS dia, SUM(llamadas_ia) AS llamadas, SUM(errores) AS errores
--   FROM public.ejecuciones WHERE proceso = 'bot' GROUP BY 1 ORDER BY 1 DESC;
