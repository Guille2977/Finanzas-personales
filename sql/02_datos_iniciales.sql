-- =====================================================================
-- 02_datos_iniciales.sql · Semillas de configuración
-- Requiere: 01_esquema.sql
--
-- Solo CONFIGURACIÓN (entidades, cuentas, categorías, diccionario,
-- fuentes). Nada de movimientos reales: este archivo puede ir a GitHub.
--
-- Idempotente con INSERT ... ON CONFLICT DO NOTHING: si la fila ya
-- existe (misma clave UNIQUE), no hace nada. En SQL Server harías
-- IF NOT EXISTS (...) INSERT o un MERGE. Se eligió DO NOTHING (y no
-- DO UPDATE) para que volver a ejecutar NO pise lo que luego edites
-- desde Retool.
--
-- Las FK se resuelven por nombre (subconsultas), nunca con ids fijos:
-- los ids IDENTITY pueden variar entre una base y otra.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Entidades
-- ---------------------------------------------------------------------
INSERT INTO public.entidades (nombre, tipo) VALUES
    ('BCP',          'banco'),
    ('Efectivo',     'efectivo'),
    ('PagoEfectivo', 'app'),
    ('Betsafe',      'app')
ON CONFLICT (nombre) DO NOTHING;

-- ---------------------------------------------------------------------
-- Cuentas (sección 6: BCP Débito, BCP Yape, Efectivo)
-- ---------------------------------------------------------------------
INSERT INTO public.cuentas (id_entidad, tipo, alias)
SELECT e.id_entidad, v.tipo, v.alias
FROM (VALUES
    ('BCP',      'debito',    'BCP Débito'),
    ('BCP',      'yape',      'BCP Yape'),
    ('Efectivo', 'billetera', 'Efectivo')
) AS v(entidad, tipo, alias)
JOIN public.entidades e ON e.nombre = v.entidad
ON CONFLICT (alias) DO NOTHING;

-- ---------------------------------------------------------------------
-- Categorías
-- ---------------------------------------------------------------------
INSERT INTO public.categorias (nombre, tipo, icono) VALUES
    -- Egresos acordados
    ('Transporte',         'egreso',        '🚌'),
    ('Comida',             'egreso',        '🍽️'),
    ('Compras online',     'egreso',        '📦'),
    ('Entretenimiento',    'egreso',        '🎮'),
    -- Egresos de apoyo (destino por defecto de algunas fuentes)
    ('Servicios',          'egreso',        '🧾'),
    ('Otros gastos',       'egreso',        '➖'),
    -- Ingresos
    ('Pagos recibidos',    'ingreso',       '💸'),
    ('Devoluciones',       'ingreso',       '↩️'),
    ('Apuestas',           'ingreso',       '🎲'),
    ('Otros ingresos',     'ingreso',       '➕'),
    -- Movimiento entre cuentas propias (no cuenta como gasto ni ingreso)
    ('Retiro de efectivo', 'transferencia', '🏧')
ON CONFLICT (nombre) DO NOTHING;

-- ---------------------------------------------------------------------
-- Diccionario (palabras normalizadas: minúsculas, sin tildes)
-- ---------------------------------------------------------------------
INSERT INTO public.diccionario (palabra, id_categoria)
SELECT v.palabra, c.id_categoria
FROM (VALUES
    ('tren',       'Transporte'),
    ('corredor',   'Transporte'),
    ('moto',       'Transporte'),
    ('carro',      'Transporte'),
    ('indrive',    'Transporte'),
    ('pasaje',     'Transporte'),
    ('menu',       'Comida'),
    ('desayuno',   'Comida'),
    ('rappi',      'Comida'),
    ('antojo',     'Comida'),
    ('gaseosa',    'Comida'),
    ('temu',       'Compras online'),
    ('aliexpress', 'Compras online'),
    ('steam',      'Entretenimiento')
) AS v(palabra, categoria)
JOIN public.categorias c ON c.nombre = v.categoria
ON CONFLICT (palabra) DO NOTHING;

-- ---------------------------------------------------------------------
-- Fuentes de correo
-- Patrones = regex sin distinguir mayúsculas (Apps Script: RegExp(p, 'i')).
--   '^...'      → el asunto EMPIEZA con ese texto.
--   'd[eé]bito' → acepta con o sin tilde.
--   '\.'        → punto literal en el dominio.
-- Prioridad: las reglas de "ignorar" (10) se evalúan antes que las de
-- procesar (100), por si un asunto encaja en ambas.
-- Publicidad y correos propios se filtran antes, en la búsqueda de
-- Gmail (filtros por remitente + "-from:me"), así ni siquiera se leen.
-- Remitentes de PagoEfectivo y Betsafe: patrón por dominio; confirmar
-- con Inventario.gs y ajustar desde Retool si hace falta.
-- ---------------------------------------------------------------------
INSERT INTO public.fuentes
    (nombre, remitente_patron, asunto_patron, accion, extractor,
     id_cuenta_defecto, id_categoria_defecto, sentido_defecto, prioridad)
SELECT v.nombre, v.remitente, v.asunto, v.accion, v.extractor,
       cu.id_cuenta, ca.id_categoria, v.sentido, v.prioridad
FROM (VALUES
    -- BCP: se procesan
    ('BCP · Consumo tarjeta de débito',
     'notificaciones@notificacionesbcp\.com\.pe', '^Realizaste un consumo con tu Tarjeta de D[eé]bito',
     'procesar', 'bcp_consumo_debito',        'BCP Débito', NULL,                 'egreso',  100),
    ('BCP · Yape recibido',
     'notificaciones@notificacionesbcp\.com\.pe', '^Constancia de recepci[oó]n de Yapeo a celular',
     'procesar', 'bcp_yape_recibido',         'BCP Yape',   'Pagos recibidos',    'ingreso', 100),
    ('BCP · Transferencia a terceros',
     'notificaciones@notificacionesbcp\.com\.pe', '^Constancia de Transferencia a Terceros',
     'procesar', 'bcp_transferencia_terceros','BCP Débito', NULL,                 'egreso',  100),
    ('BCP · Pago de servicio',
     'notificaciones@notificacionesbcp\.com\.pe', '^CONSTANCIA DE PAGO DE SERVICIO',
     'procesar', 'bcp_pago_servicio',         'BCP Débito', 'Servicios',          'egreso',  100),
    ('BCP · Devolución',
     'notificaciones@notificacionesbcp\.com\.pe', '^Realizamos una devoluci[oó]n',
     'procesar', 'bcp_devolucion',            'BCP Débito', 'Devoluciones',       'ingreso', 100),
    -- Retiro: egreso del débito con categoría de tipo 'transferencia'
    -- (no suma como gasto; el gasto real se registra al usar el efectivo).
    ('BCP · Retiro en Agente',
     'notificaciones@notificacionesbcp\.com\.pe', '^Realizaste un retiro en un Agente BCP',
     'procesar', 'bcp_retiro_agente',         'BCP Débito', 'Retiro de efectivo', 'egreso',  100),
    -- BCP: se ignoran (no son movimientos reales)
    ('BCP · Operación rechazada',
     'notificaciones@notificacionesbcp\.com\.pe', 'rechaz',
     'ignorar',  NULL,                        NULL,         NULL,                 NULL,      10),
    ('BCP · Orden pendiente',
     'notificaciones@notificacionesbcp\.com\.pe', 'pendiente',
     'ignorar',  NULL,                        NULL,         NULL,                 NULL,      10),
    -- Otras apps
    -- PagoEfectivo: el pago sale del débito; si el BCP también envía
    -- constancia, la conciliación vincula ambos y solo cuenta uno.
    ('PagoEfectivo · CIP pagado',
     'pagoefectivo',                              '^Tu c[oó]digo CIP ha sido pagado',
     'procesar', 'pagoefectivo_cip_pagado',   'BCP Débito', NULL,                 'egreso',  100),
    ('Betsafe · Retiro aprobado',
     'betsafe',                                   '^Tu retiro ha sido aprobado',
     'procesar', 'betsafe_retiro_aprobado',   'BCP Débito', 'Apuestas',           'ingreso', 100)
) AS v(nombre, remitente, asunto, accion, extractor, cuenta, categoria, sentido, prioridad)
LEFT JOIN public.cuentas    cu ON cu.alias  = v.cuenta      -- LEFT: algunas filas no tienen cuenta
LEFT JOIN public.categorias ca ON ca.nombre = v.categoria
ON CONFLICT (nombre) DO NOTHING;

COMMIT;
