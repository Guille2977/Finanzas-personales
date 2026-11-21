-- =====================================================================
-- 06_diccionario_comercios.sql · Más comercios en el diccionario
-- Idempotente. Solo clasifica movimientos que estén SIN categoría
-- (no pisa lo que ya tenga una).
-- Nota: el clasificador compara palabras completas, por eso "steam" no
-- reconocía "STEAMGAMES": se agrega la palabra exacta.
-- =====================================================================
BEGIN;

INSERT INTO public.categorias (nombre, tipo, icono) VALUES
    ('Educación',     'egreso', '🎓'),
    ('Suscripciones', 'egreso', '🔁')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO public.diccionario (palabra, id_categoria)
SELECT v.palabra, c.id_categoria
FROM (VALUES
    ('steamgames', 'Entretenimiento'),
    ('discord',    'Entretenimiento'),
    ('kfc',        'Comida'),
    ('amazon',     'Compras online'),
    ('entel',      'Servicios'),
    ('universidad','Servicios'),
    ('udemy',      'Educación'),
    ('openai',     'Suscripciones'),
    ('chatgpt',    'Suscripciones')
) AS v(palabra, categoria)
JOIN public.categorias c ON c.nombre = v.categoria
ON CONFLICT (palabra) DO NOTHING;

-- Reclasificar lo que está sin categoría, por palabra completa en la
-- contraparte. '\m' y '\M' = inicio y fin de palabra en regex de PostgreSQL.
UPDATE public.movimientos m
SET id_categoria = (SELECT d.id_categoria
                    FROM public.diccionario d
                    WHERE d.activo AND lower(coalesce(m.contraparte, '')) ~ ('\m' || d.palabra || '\M')
                    ORDER BY length(d.palabra) DESC
                    LIMIT 1)
WHERE m.id_categoria IS NULL
  AND m.contraparte IS NOT NULL;

COMMIT;

-- Lo que sigue sin categoría (para revisar a mano o agregar palabras).
SELECT fecha::date, monto, contraparte, descripcion
FROM public.movimientos
WHERE estado = 'activo' AND id_categoria IS NULL
ORDER BY fecha DESC;
