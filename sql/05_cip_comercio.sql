-- =====================================================================
-- 05_cip_comercio.sql · Rellena la tienda y el código de los pagos CIP ya
-- registrados, leyendo el cuerpo guardado en correos_raw (sin volver a Gmail).
-- Idempotente. Los CIP nuevos ya llegan así desde Extractores.gs.
--
-- PostgreSQL permite regex dentro de SQL:
--   substring(texto FROM 'patrón (captura)')  → devuelve lo capturado.
--   regexp_replace(texto, patrón, reemplazo, 'i') → 'i' = sin distinguir mayúsculas.
-- SQL Server no tiene regex nativo (solo LIKE / PATINDEX).
-- =====================================================================
BEGIN;

-- 1. Tienda (contraparte) y código CIP como número de operación.
UPDATE public.movimientos m
SET contraparte      = regexp_replace(substring(c.cuerpo FROM 'informar a\s+(.+?)\s+para continuar'), '\s+QR$', '', 'i'),
    numero_operacion = 'CIP-' || substring(c.cuerpo FROM '[Cc][oó]digo de pago\D{0,25}(\d{6,})'),
    descripcion      = 'Pago con código CIP'
FROM public.correos_raw c
JOIN public.fuentes f ON f.id_fuente = c.id_fuente
WHERE m.id_correo = c.id_correo
  AND f.nombre = 'PagoEfectivo · CIP pagado';

-- 2. Categoría según la tienda, con el diccionario (la palabra más larga gana).
UPDATE public.movimientos m
SET id_categoria = (SELECT d.id_categoria
                    FROM public.diccionario d
                    WHERE d.activo AND lower(coalesce(m.contraparte, '')) LIKE '%' || d.palabra || '%'
                    ORDER BY length(d.palabra) DESC
                    LIMIT 1)
FROM public.correos_raw c
JOIN public.fuentes f ON f.id_fuente = c.id_fuente
WHERE m.id_correo = c.id_correo
  AND f.nombre = 'PagoEfectivo · CIP pagado';

COMMIT;

-- Verificación
SELECT m.fecha::date AS fecha, m.monto, m.contraparte, m.numero_operacion,
       coalesce(cat.nombre, 'Sin categoría') AS categoria
FROM public.movimientos m
JOIN public.correos_raw c       ON c.id_correo = m.id_correo
JOIN public.fuentes f           ON f.id_fuente = c.id_fuente
LEFT JOIN public.categorias cat ON cat.id_categoria = m.id_categoria
WHERE f.nombre = 'PagoEfectivo · CIP pagado'
ORDER BY m.fecha DESC;
