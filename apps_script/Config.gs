/**
 * Config.gs — claves y constantes. Ningún secreto vive en el código.
 *
 * Por qué PropertiesService: las claves quedan guardadas en el proyecto de
 * Apps Script (Configuración del proyecto → Propiedades del script), no en
 * el código. Así el código puede ir a GitHub sin exponer nada.
 *
 * Propiedades requeridas:
 *   SUPABASE_URL   → https://xxxx.supabase.co   (Project Settings → API)
 *   SUPABASE_KEY   → clave service_role / secret (NUNCA la anon/publishable)
 * El bot de Telegram ya NO vive aquí: es la Edge Function de Supabase
 * supabase/functions/telegram-webhook (sus claves van en Edge Functions → Secrets).
 * Para las alertas (Alertas.gs), los mismos valores que la Edge Function:
 *   TELEGRAM_TOKEN    → token del bot (@BotFather)
 *   TELEGRAM_CHAT_ID  → tu chat_id
 * Opcionales:
 *   HOJA_ID        → ID de la hoja "Movimientos bancarios" (solo para migrar)
 *   GMAIL_CONSULTA → reemplaza la consulta por defecto sin tocar código
 */

const CONFIG = {
  // Remitentes conocidos, sin correos propios (-from:me) y con una ventana
  // de días hacia atrás: si el activador se detiene unos días, al volver se
  // pone al día solo. Los ya procesados se saltan (idempotencia por id).
  CONSULTA_DEFECTO:
    '{from:notificacionesbcp.com.pe from:notificaciones.bcp.com.pe from:pagoefectivo from:betsafe} ' +
    // Se excluyen en la búsqueda (no gastan cuota de Gmail): publicidad y
    // órdenes de pago aún no pagadas.
    '-from:me -from:news@email.betsafe.pe -from:news@email.betsafe.com -subject:"orden pendiente" newer_than:10d',
  MAX_CORREOS_POR_CORRIDA: 200,
  // Apps Script corta una ejecución a los 6 min. Paramos antes y lo que
  // falte se procesa en la siguiente corrida (cada 15 min).
  LIMITE_MS: 4.5 * 60 * 1000,
  MINUTOS_ACTIVADOR: 15,
  // Alertas (Alertas.gs): QUÉ avisar y los umbrales viven en la base
  // (sql/11: umbrales_presupuesto, parametros); aquí solo el ritmo de envío.
  MINUTOS_ALERTAS: 15,
  MAX_ALERTAS_POR_CORRIDA: 20,
  ZONA: 'America/Lima',
  PESTANA_MIGRACION: 'Movimientos',
};

/** Lee una propiedad obligatoria; si falta, el error dice cuál y dónde ponerla. */
let PROPS_CACHE_ = null;   // se lee una vez por ejecución (cada lectura cuesta tiempo)
function propiedad_(nombre, opcional) {
  if (!PROPS_CACHE_) PROPS_CACHE_ = PropertiesService.getScriptProperties().getProperties();
  const valor = PROPS_CACHE_[nombre];
  if (!valor && !opcional) {
    throw new Error(`Falta la propiedad del script "${nombre}" (Configuración del proyecto → Propiedades del script).`);
  }
  return valor;
}

function consultaGmail_() {
  return propiedad_('GMAIL_CONSULTA', true) || CONFIG.CONSULTA_DEFECTO;
}
