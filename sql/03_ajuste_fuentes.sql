-- =====================================================================
-- 03_ajuste_fuentes.sql · Ajustes de fuentes tras la primera reconstrucción
-- Idempotente: UPDATE con valores fijos + INSERT ... ON CONFLICT DO NOTHING.
-- Ejemplo de "configuración en lugar de código": ningún .gs cambia.
-- =====================================================================
BEGIN;

-- El BCP también envía "ENVIO AUTOMATICO - CONSTANCIA DE PAGO DE SERVICIO".
-- Se quita el "^" (inicio de texto) para aceptar ese prefijo.
UPDATE public.fuentes
SET asunto_patron = 'CONSTANCIA DE PAGO DE SERVICIO'
WHERE nombre = 'BCP · Pago de servicio';

INSERT INTO public.fuentes (nombre, remitente_patron, asunto_patron, accion, prioridad) VALUES
    -- Órdenes de pago generadas (aún NO pagadas). El pago real llega
    -- después como "Tu código CIP ha sido pagado".
    ('PagoEfectivo · Orden pendiente', 'pagoefectivo', 'orden pendiente de pago', 'ignorar', 10),
    -- Publicidad de Betsafe.
    ('Betsafe · Publicidad', 'news@email\.betsafe\.', NULL, 'ignorar', 10),   -- .pe y .com
    -- Avisos del BCP que no son movimientos de dinero.
    ('BCP · Avisos de seguridad y cuenta', 'notificacionesbcp\.com\.pe',
     'clave de internet|actualizado tus datos|repuesto tu tarjeta|bienvenida|token digital', 'ignorar', 10)
ON CONFLICT (nombre) DO NOTHING;

-- Betsafe también escribe desde news@email.betsafe.com (no solo .pe).
UPDATE public.fuentes
SET remitente_patron = 'news@email\.betsafe\.'
WHERE nombre = 'Betsafe · Publicidad';

COMMIT;
