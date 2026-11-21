/**
 * Telegram.gs — conexión con la API de Telegram: recibir mensajes (webhook o
 * polling), enviar respuestas, idempotencia y cola si Supabase no responde.
 * QUÉ hacer con cada mensaje lo decide Bot.gs (separación de responsabilidades).
 *
 * Camino de un mensaje (webhook):
 *   Telegram → Edge Function de Supabase (responde 200 al instante)
 *            → doPost de esta app web → Bot.gs → respuesta a Telegram.
 *   Por qué el paso intermedio: Apps Script responde con una redirección 302,
 *   Telegram la toma como fallo, reintenta y frena los mensajes siguientes.
 *   Ver supabase/functions/telegram-webhook/index.ts.
 *
 * Funciones para ejecutar desde el editor (en este orden la primera vez):
 *   obtenerChatId()        → ANTES del webhook: muestra tu chat_id.
 *   datosWebhook()         → muestra los 2 secretos para la Edge Function.
 *   configurarWebhook()    → conecta Telegram con la Edge Function (idempotente).
 *   estadoWebhook()        → muestra si Telegram llega bien (errores, pendientes).
 *   activarPolling()       → plan B: quita el webhook y lee cada minuto.
 *   procesarColaTelegram() → registra lo que quedó guardado cuando la base falló.
 *
 * Propiedades: TELEGRAM_TOKEN, TELEGRAM_CHAT_ID, WEBAPP_URL.
 *              TELEGRAM_SECRETO lo crea configurarWebhook() solo.
 *
 * Idempotencia (3 barreras):
 *   1. update_id: Telegram numera cada evento en orden creciente. Guardamos el
 *      último atendido; si llega uno igual o menor (reintento), se ignora.
 *   2. max_connections = 1: Telegram entrega de a un mensaje, sin carreras.
 *   3. En la base: numero_operacion = "TG-<update_id>-<n>" con el UNIQUE
 *      (id_cuenta, numero_operacion) que ya existía para los correos.
 */

const TG = {
  API: 'https://api.telegram.org/bot',
  CLAVE_ULTIMO: 'TG_ULTIMO_UPDATE',
  PREFIJO_COLA: 'TG_COLA_',
  MAX_COLA: 100,
  EVENTOS: ['message', 'callback_query'],
};

// ---------------------------------------------------------------------
// Entradas
// ---------------------------------------------------------------------

/**
 * Webhook: Telegram hace POST a la URL de la app web por cada mensaje.
 * Apps Script NO deja leer cabeceras HTTP, así que el secreto viaja en la
 * URL (?s=...). Sin él, cualquiera que adivine la URL podría inyectar
 * mensajes falsos. Además, solo se atiende al TELEGRAM_CHAT_ID.
 * Siempre responde "ok": un error nuestro no debe hacer que Telegram reintente.
 */
function doPost(e) {
  try {
    const secreto = propiedad_('TELEGRAM_SECRETO', true);
    if (!secreto || !e || !e.parameter || e.parameter.s !== secreto) {
      console.warn('doPost sin secreto válido: ignorado.');
    } else {
      recibirUpdate_(JSON.parse(e.postData.contents));
    }
  } catch (err) {
    console.error('doPost: ' + err.message);
  }
  return ContentService.createTextOutput('ok');
}

/** Polling (plan B): lo llama un activador cada minuto si activas activarPolling(). */
function leerTelegram() {
  const ultimo = Number(propiedad_(TG.CLAVE_ULTIMO, true) || 0);
  const updates = tg_('getUpdates', { offset: ultimo + 1, timeout: 0, allowed_updates: TG.EVENTOS });
  updates.forEach(recibirUpdate_);
}

// ---------------------------------------------------------------------
// Configuración (se ejecutan a mano)
// ---------------------------------------------------------------------

function obtenerChatId() {
  const bot = tg_('getMe', {});
  console.log(`Token del bot @${bot.username}. Escríbele a ESE bot.`);
  let updates;
  try {
    updates = tg_('getUpdates', { timeout: 0 });
  } catch (e) {
    throw new Error('No se pudo leer (¿webhook activo? getUpdates no funciona con webhook): ' + e.message);
  }
  const chats = {};
  updates.forEach(u => {
    const m = u.message || (u.callback_query && u.callback_query.message);
    if (m) chats[m.chat.id] = `${m.chat.first_name || ''} ${m.chat.username ? '@' + m.chat.username : ''}`.trim();
  });
  if (!Object.keys(chats).length) return console.log('No hay mensajes. Escríbele /start a tu bot y vuelve a ejecutar.');
  Object.keys(chats).forEach(id => console.log(`chat_id ${id} → ${chats[id]}`));
  console.log('Copia TU chat_id en la propiedad TELEGRAM_CHAT_ID.');
}

/** Secreto compartido (Telegram ↔ Edge Function ↔ Apps Script). Se crea una sola vez. */
function secretoWebhook_() {
  const props = PropertiesService.getScriptProperties();
  let secreto = props.getProperty('TELEGRAM_SECRETO');
  if (!secreto) {
    secreto = Utilities.getUuid().replace(/-/g, '');      // solo letras y números: Telegram lo acepta
    props.setProperty('TELEGRAM_SECRETO', secreto);
  }
  return secreto;
}

function urlWebApp_() {
  const url = propiedad_('WEBAPP_URL').trim();
  if (!/^https:\/\/script\.google\.com\/macros\/s\/.+\/exec$/.test(url)) {
    throw new Error('WEBAPP_URL debe ser la URL de la implementación y terminar en /exec');
  }
  return url;
}

/** URL de la Edge Function, derivada de SUPABASE_URL (no hace falta otra propiedad). */
function urlEdgeFunction_() {
  return propiedad_('SUPABASE_URL').replace(/\/+$/, '') + '/functions/v1/telegram-webhook';
}

/** Muestra lo que se pega en Supabase → Edge Functions → Secrets. */
function datosWebhook() {
  const secreto = secretoWebhook_();
  console.log('Pega estos 2 secretos en Supabase → Edge Functions → Secrets:');
  console.log('TELEGRAM_SECRETO = ' + secreto);
  console.log('APPS_SCRIPT_URL  = ' + `${urlWebApp_()}?s=${secreto}`);
  console.log('La función debe llamarse telegram-webhook: ' + urlEdgeFunction_());
}

function configurarWebhook() {
  propiedad_('TELEGRAM_CHAT_ID');                         // falla con mensaje claro si falta
  const secreto = secretoWebhook_();
  urlWebApp_();
  borrarActivadores_('leerTelegram');                     // webhook y polling no conviven
  tg_('setWebhook', {
    url: urlEdgeFunction_(),
    secret_token: secreto,                                // Telegram lo manda en una cabecera
    allowed_updates: TG.EVENTOS,
    max_connections: 1,
    drop_pending_updates: false,
  });
  tg_('setMyCommands', { commands: [
    { command: 'hoy', description: 'Movimientos de hoy' },
    { command: 'semana', description: 'Gasto de la semana por categoría' },
    { command: 'mes', description: 'Gasto del mes por categoría' },
    { command: 'presupuesto', description: 'Avance de presupuestos' },
    { command: 'ayuda', description: 'Cómo escribir un gasto' },
  ] });
  console.log('✅ Webhook configurado. Escríbele "pasaje 3" al bot y luego ejecuta estadoWebhook().');
}

function estadoWebhook() {
  const i = tg_('getWebhookInfo', {});
  console.log(JSON.stringify({
    url_configurada: Boolean(i.url),
    pendientes: i.pending_update_count,
    ultimo_error: i.last_error_message || 'ninguno',
    fecha_ultimo_error: i.last_error_date ? new Date(i.last_error_date * 1000).toString() : null,
  }, null, 2));
}

/** Plan B si el webhook da problemas: lectura cada minuto con getUpdates. */
function activarPolling() {
  tg_('deleteWebhook', { drop_pending_updates: false });
  borrarActivadores_('leerTelegram');
  ScriptApp.newTrigger('leerTelegram').timeBased().everyMinutes(1).create();
  console.log('✅ Polling activo (cada minuto). Para volver al webhook: configurarWebhook().');
}

function procesarColaTelegram() {
  const n = vaciarCola_();
  console.log(n === null ? 'La base sigue sin responder.' : `Cola procesada: ${n} mensaje(s).`);
}

// ---------------------------------------------------------------------
// Núcleo
// ---------------------------------------------------------------------

function recibirUpdate_(update) {
  if (!update || typeof update.update_id !== 'number') return;
  if (!marcarUpdate_(update.update_id)) return;           // reintento: ya atendido
  if (!esDelDueno_(update)) return;                       // otro chat: silencio
  atenderUpdate_(update);
}

/**
 * true si el update es nuevo (y lo marca). Se marca ANTES de procesar:
 * preferimos "como máximo una vez" (un error se avisa al usuario) a
 * repetir registros. Los fallos transitorios se guardan en la cola.
 */
function marcarUpdate_(updateId) {
  const props = PropertiesService.getScriptProperties();
  const ultimo = Number(props.getProperty(TG.CLAVE_ULTIMO) || 0);
  if (updateId <= ultimo) return false;
  props.setProperty(TG.CLAVE_ULTIMO, String(updateId));
  return true;
}

function chatDe_(update) {
  const m = update.message || (update.callback_query && update.callback_query.message);
  return m && m.chat ? String(m.chat.id) : null;
}

function esDelDueno_(update) {
  return chatDe_(update) === String(propiedad_('TELEGRAM_CHAT_ID'));
}

/**
 * Procesa un update registrando la ejecución (proceso 'bot') en `ejecuciones`.
 * - Base caída (error transitorio) → se guarda en la cola y se avisa.
 * - Otro error → se avisa con la causa; queda en ejecuciones.detalle.
 */
function atenderUpdate_(update, desdeCola) {
  const cont = { leidos: 1, insertados: 0, por_revisar: 0, errores: 0, llamadas_ia: 0 };
  const mensajes = [];
  const inicio = new Date().toISOString();
  try {
    manejarUpdate_(update, cont);                          // Bot.gs: responde primero
    if (!desdeCola) vaciarCola_();                         // la base responde: lo pendiente después
  } catch (e) {
    cont.errores++;
    mensajes.push(e.message);
    if (e.transitorio && !desdeCola) {
      encolar_(update);
      avisarSeguro_(update, '⏳ La base no responde. Guardé tu mensaje y lo registro en cuanto vuelva.');
    } else if (!e.transitorio) {
      avisarSeguro_(update, '❌ No pude procesarlo: ' + e.message.slice(0, 200));
    }
    if (desdeCola) throw e;
  } finally {
    cont.llamadas_ia = IA_USO.llamadas;
    if (IA_USO.fallos) mensajes.push(`IA: ${IA_USO.fallos} fallo(s)`);
    console.log(`Update ${update.update_id} atendido en ${Date.now() - new Date(inicio).getTime()} ms`);
    registrarEjecucionBot_(inicio, cont, mensajes);
  }
}

/**
 * El bot registra su ejecución con UN solo INSERT al final (no INSERT al
 * inicio + UPDATE al final como la captura): una llamada menos a la base
 * antes de responder. Nunca lanza.
 */
function registrarEjecucionBot_(inicio, cont, mensajes) {
  try {
    db_.insertar('ejecuciones', [Object.assign({
      proceso: 'bot', inicio: inicio, fin: new Date().toISOString(),
      detalle: mensajes.length ? mensajes.join('\n').slice(0, 2000) : null,
    }, cont)]);
  } catch (e) {
    console.error('No se pudo registrar la ejecución del bot: ' + e.message);
  }
}

// --- Cola: una propiedad por update (cada valor tiene un límite de ~9 KB) ---

function encolar_(update) {
  const props = PropertiesService.getScriptProperties();
  const claves = Object.keys(props.getProperties()).filter(k => k.startsWith(TG.PREFIJO_COLA));
  if (claves.length >= TG.MAX_COLA) { console.error('Cola de Telegram llena; se descarta ' + update.update_id); return; }
  props.setProperty(TG.PREFIJO_COLA + update.update_id, JSON.stringify(update));
}

/** Devuelve cuántos procesó, o null si la base sigue caída. */
function vaciarCola_() {
  const props = PropertiesService.getScriptProperties();
  const claves = Object.keys(props.getProperties())
    .filter(k => k.startsWith(TG.PREFIJO_COLA))
    .sort((a, b) => Number(a.slice(TG.PREFIJO_COLA.length)) - Number(b.slice(TG.PREFIJO_COLA.length)));
  let n = 0;
  for (const clave of claves) {
    try {
      atenderUpdate_(JSON.parse(props.getProperty(clave)), true);
    } catch (e) {
      if (e.transitorio) return null;                      // sigue caída: se queda en cola
      console.error(`Cola ${clave}: ${e.message}`);        // error de datos: se descarta (ya se avisó)
    }
    props.deleteProperty(clave);
    n++;
  }
  return n;
}

// ---------------------------------------------------------------------
// API de Telegram
// ---------------------------------------------------------------------

/**
 * Llama a un método de la Bot API. El token va en la URL, así que los
 * errores se limpian antes de relanzarlos: nunca debe quedar en un log.
 */
function tg_(metodo, datos) {
  const token = propiedad_('TELEGRAM_TOKEN');
  let r;
  try {
    r = UrlFetchApp.fetch(TG.API + token + '/' + metodo, {
      method: 'post',
      contentType: 'application/json',
      payload: JSON.stringify(datos || {}),
      muteHttpExceptions: true,
    });
  } catch (e) {
    throw new Error(`Telegram ${metodo}: ${String(e.message).split(token).join('***')}`);
  }
  let j = {};
  try { j = JSON.parse(r.getContentText()); } catch (_) { /* no JSON */ }
  if (!j.ok) throw new Error(`Telegram ${metodo}: ${j.description || 'HTTP ' + r.getResponseCode()}`);
  return j.result;
}

/** Envía un mensaje en HTML, como respuesta a otro (para poder recuperar su texto luego). */
function enviar_(chatId, html, teclado, responderA) {
  const datos = { chat_id: chatId, text: html, parse_mode: 'HTML', link_preview_options: { is_disabled: true } };
  if (teclado) datos.reply_markup = { inline_keyboard: teclado };
  if (responderA) datos.reply_parameters = { message_id: responderA, allow_sending_without_reply: true };
  return tg_('sendMessage', datos);
}

function editar_(chatId, idMensaje, html, teclado) {
  try {
    tg_('editMessageText', {
      chat_id: chatId, message_id: idMensaje, text: html, parse_mode: 'HTML',
      reply_markup: { inline_keyboard: teclado || [] },
    });
  } catch (e) {
    if (!/not modified/i.test(e.message)) throw e;        // mismo texto: no es error
  }
}

/** Avisar nunca debe tapar el error original. */
function avisarSeguro_(update, texto) {
  try {
    const chat = chatDe_(update);
    if (chat) enviar_(chat, escaparHtml_(texto));
  } catch (e) {
    console.error('No se pudo avisar por Telegram: ' + e.message);
  }
}

function escaparHtml_(t) {
  return String(t == null ? '' : t).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function borrarActivadores_(funcion) {
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === funcion)
    .forEach(t => ScriptApp.deleteTrigger(t));
}
