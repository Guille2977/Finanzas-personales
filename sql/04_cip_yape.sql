-- =====================================================================
-- 04_cip_yape.sql · Pagos CIP (PagoEfectivo) pagados con Yape
-- Idempotente: se puede ejecutar varias veces con el mismo resultado.
--
-- Un CIP no siempre es una apuesta (también Steam vía PagSeguro, etc.).
-- Por eso la fuente NO fija una categoría: se clasifica por el COMERCIO
-- (contraparte) usando el diccionario, como cualquier otro gasto.
-- =====================================================================
BEGIN;

-- Categoría de egreso para recargas en casas de apuestas.
INSERT INTO public.categorias (nombre, tipo, icono)
VALUES ('Recargas de apuestas', 'egreso', '🎰')
ON CONFLICT (nombre) DO NOTHING;

-- Comercio → categoría (palabras normalizadas: minúsculas, sin tildes).
INSERT INTO public.diccionario (palabra, id_categoria)
SELECT v.palabra, c.id_categoria
FROM (VALUES
    ('betsafe',       'Recargas de apuestas'),
    ('betsson',       'Recargas de apuestas'),
    ('apuesta total', 'Recargas de apuestas')
    -- PagSeguro NO va aquí: es un intermediario de pago (Steam u otras
    -- tiendas), así que no dice en qué gastaste. Esos pagos quedan
    -- "Sin categoría" y se clasifican a mano en Retool.
) AS v(palabra, categoria)
JOIN public.categorias c ON c.nombre = v.categoria
ON CONFLICT (palabra) DO NOTHING;

-- Configuración: los CIP salen de BCP Yape y sin categoría fija.
UPDATE public.fuentes
SET id_cuenta_defecto    = (SELECT id_cuenta FROM public.cuentas WHERE alias = 'BCP Yape'),
    id_categoria_defecto = NULL
WHERE nombre = 'PagoEfectivo · CIP pagado';

-- Datos ya registrados: cuenta Yape y categoría según el comercio.
-- UPDATE ... FROM es propio de PostgreSQL (SQL Server: UPDATE m SET ... FROM ... JOIN).
UPDATE public.movimientos m
SET id_cuenta    = f.id_cuenta_defecto,
    id_categoria = (SELECT d.id_categoria
                    FROM public.diccionario d
                    WHERE d.activo
                      AND lower(coalesce(m.contraparte, '') || ' ' || coalesce(m.descripcion, '')) LIKE '%' || d.palabra || '%'
                    ORDER BY length(d.palabra) DESC      -- la palabra más específica gana
                    LIMIT 1)                             -- LIMIT 1 ≈ TOP 1 de SQL Server
FROM public.correos_raw c
JOIN public.fuentes f ON f.id_fuente = c.id_fuente
WHERE m.id_correo = c.id_correo
  AND f.nombre = 'PagoEfectivo · CIP pagado';

COMMIT;

-- Verificación: cada pago CIP con su comercio y categoría.
-- Si alguno queda "Sin categoría", mira su contraparte y agrega esa
-- palabra al diccionario.
SELECT m.fecha::date AS fecha, m.monto, m.contraparte,
       coalesce(cat.nombre, 'Sin categoría') AS categoria, cu.alias AS cuenta
FROM public.movimientos m
JOIN public.correos_raw c       ON c.id_correo = m.id_correo
JOIN public.fuentes f           ON f.id_fuente = c.id_fuente
JOIN public.cuentas cu          ON cu.id_cuenta = m.id_cuenta
LEFT JOIN public.categorias cat ON cat.id_categoria = m.id_categoria
WHERE f.nombre = 'PagoEfectivo · CIP pagado'
ORDER BY m.fecha DESC;
