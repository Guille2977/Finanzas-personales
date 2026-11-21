-- =====================================================================
-- 08_bot_edge.sql · El bot pasa a una Edge Function de Supabase
-- Requiere: 01 a 07. Idempotente.
--
-- telegram_updates: un registro por update de Telegram ya atendido.
-- PRIMARY KEY (update_id) = idempotencia en la base: si Telegram reenvía
-- el mismo update, el INSERT falla con 23505 y la función lo ignora.
-- (En Apps Script esto se guardaba en Propiedades del script.)
-- =====================================================================
BEGIN;

CREATE TABLE IF NOT EXISTS public.telegram_updates (
    update_id   BIGINT      PRIMARY KEY,            -- lo numera Telegram
    recibido_en TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.telegram_updates IS 'Updates de Telegram ya atendidos (idempotencia del bot).';

-- Seguridad igual que el resto: RLS sin políticas + permisos solo a service_role.
ALTER TABLE public.telegram_updates ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        GRANT SELECT, INSERT, DELETE ON public.telegram_updates TO service_role;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE ALL ON public.telegram_updates FROM anon, authenticated;
    END IF;
END
$$;

COMMIT;

-- Mantenimiento (opcional, una vez al mes): Telegram no reenvía updates
-- de más de 24 h, así que los viejos se pueden borrar.
--   DELETE FROM public.telegram_updates WHERE recibido_en < now() - INTERVAL '7 days';
-- (INTERVAL '7 days' ≈ DATEADD(day, -7, GETDATE()) de SQL Server)
