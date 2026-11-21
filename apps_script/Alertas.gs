/**
 * Alertas.gs — envía por Telegram los avisos que DECIDE la base.
 *
 *   revisarAlertas()          → lo llama su activador cada 15 min.
 *   crearActivadorAlertas()   → crea ese activador (idempotente: no se duplica).
 *   probarAlertaTelegram()    → manda un mensaje de prueba (verifica token y chat).
 *
 * Reparto (ver sql/11_alertas.sql):
 *   1. db_.rpc('fn_generar_alertas') → la base revisa presupuestos, errores de
 *      captura y captura detenida, y ENCOLA en la tabla `alertas` lo que haya
 *      que avisar. La clave UNIQUE impide repetir un aviso.
 *   2. Aquí se leen los pendientes (v_alertas_pendientes), se envían y se
 *      marcan con enviada_en SOLO después de que Telegram responde 200.
 *      Si falla, queda pendiente y se reintenta en la siguiente corrida.
 *
 * Por qué un activador APARTE del de captura: si el de captura se borra o
 * se detiene, este sigue corriendo y avisa "la captura no corre hace N h".
 * (Si Google revoca los permisos se detienen ambos; eso lo cubre el correo
 * automático de fallas de Apps Script y el panel de salud.)
 *
 * Propiedades del script requeridas (las mismas que tiene la Edge Function):
 *   TELEGRAM_TOKEN    → token de @BotFather
 *   TELEGRAM_CHAT_ID  → tu chat_id (el bot solo te escribe a ti)
 */

function revisarAlertas() {
  const lock = LockService.getScriptLock();
  // Comparte el candado con la captura: si está corriendo, espera hasta 30 s;
  // si no lo obtiene, sale y lo intenta en 15 min (nada se pierde: la cola está en la base).
  if (!lock.tryLock(30000)) { console.log('La captura sigue en curso; las alertas se revisan en la próxima corrida.'); return; }

  let idEjecucion = null;
  const cont = { leidos: 0, insertados: 0, errores: 0 };
  const mensajes = [];
  try {
    const nuevas = db_.rpc('fn_generar_alertas');
    const pendientes = db_.leer('v_alertas_pendientes', `select=id,mensaje,intentos&limit=${CONFIG.MAX_ALERTAS_POR_CORRIDA}`);
    // Sin pendientes no se registra la corrida: si cada revisión dejara una
    // fila en `ejecuciones`, v_salud_sistema (que mira la última ejecución de
    // cualquier proceso) diría "ok" aunque la captura estuviera detenida.
    if (!pendientes.length) { console.log('Sin alertas pendientes.'); return; }

    idEjecucion = iniciarEjecucion_('alertas');
    const r = enviarPendientes_(pendientes, enviarTelegram_, marcarAlerta_);
    cont.leidos = pendientes.length;
    cont.insertados = r.enviadas;           // en esta tabla "insertados" = avisos enviados
    cont.errores = r.fallidas;
    mensajes.push(`Nuevas: ${nuevas} · enviadas: ${r.enviadas} · fallidas: ${r.fallidas}`, ...r.errores);
    console.log(mensajes.join('\n'));
  } catch (e) {
    // Error general (Supabase caído, fn_generar_alertas no existe...). Se
    // intenta dejar constancia y se relanza para que Apps Script marque la
    // ejecución como fallida (y te llegue su correo de fallas).
    cont.errores++;
    mensajes.push('Error general: ' + e.message);
    try { if (!idEjecucion) idEjecucion = iniciarEjecucion_('alertas'); } catch (_) { /* base caída */ }
    throw e;
  } finally {
    finalizarEjecucion_(idEjecucion, cont, mensajes);
    lock.releaseLock();
  }
}

function crearActivadorAlertas() {
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === 'revisarAlertas')
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('revisarAlertas').timeBased().everyMinutes(CONFIG.MINUTOS_ALERTAS).create();
  console.log(`✅ Activador creado: revisarAlertas cada ${CONFIG.MINUTOS_ALERTAS} min.`);
}

function probarAlertaTelegram() {
  enviarTelegram_('✅ Prueba de alertas desde Apps Script. Si lees esto, TELEGRAM_TOKEN y TELEGRAM_CHAT_ID están bien.');
  console.log('✅ Mensaje enviado. Revisa Telegram.');
}

// ---------------------------------------------------------------------
// Lógica pura (se prueba en Pruebas.gs sin red: recibe sus dependencias)
// ---------------------------------------------------------------------

/**
 * Envía los pendientes EN ORDEN. Ante el primer error se detiene: casi
 * siempre es un problema general (token, red, Telegram caído, 429) y los
 * demás fallarían igual. El que falló suma un intento; al llegar a
 * alerta_max_intentos deja de aparecer en v_alertas_pendientes, así un
 * mensaje "venenoso" no bloquea la cola para siempre.
 *
 * Se marca DESPUÉS de enviar ("al menos una vez"): si la base se cae justo
 * entre el envío y la marca, el aviso podría llegar dos veces; nunca se pierde.
 *
 * @param pendientes [{ id, mensaje, intentos }]
 * @param enviar     (texto) => void, lanza si falla
 * @param marcar     (id, cambios) => void
 */
function enviarPendientes_(pendientes, enviar, marcar) {
  const r = { enviadas: 0, fallidas: 0, errores: [] };
  for (const a of pendientes) {
    try {
      enviar(a.mensaje);
    } catch (e) {
      r.fallidas++;
      r.errores.push(`Alerta ${a.id}: ${e.message}`);
      marcar(a.id, { intentos: a.intentos + 1, ultimo_error: String(e.message).slice(0, 500) });
      break;
    }
    marcar(a.id, { enviada_en: new Date().toISOString(), intentos: a.intentos + 1, ultimo_error: null });
    r.enviadas++;
  }
  return r;
}

function marcarAlerta_(id, cambios) {
  db_.actualizar('alertas', `id=eq.${id}`, cambios);
}

/**
 * sendMessage de la API de Telegram. Texto plano (sin parse_mode): un "<" en
 * el nombre de una categoría no rompe el mensaje.
 * opciones (para pruebas): { fetch, token, chat }.
 * Seguridad: el token va en la URL; si UrlFetchApp falla, su mensaje de error
 * puede incluir la URL. Se reemplaza el token antes de relanzar, para que no
 * termine guardado en alertas.ultimo_error ni en ejecuciones.detalle.
 */
function enviarTelegram_(texto, opciones) {
  const o = opciones || {};
  const token = o.token || propiedad_('TELEGRAM_TOKEN');
  const chat = o.chat || propiedad_('TELEGRAM_CHAT_ID');
  const url = `https://api.telegram.org/bot${token}/sendMessage`;
  const peticion = {
    method: 'post',
    contentType: 'application/json',
    muteHttpExceptions: true,     // leemos el código nosotros
    payload: JSON.stringify({ chat_id: chat, text: texto, disable_web_page_preview: true }),
  };
  let r;
  try {
    r = o.fetch ? o.fetch(url, peticion) : UrlFetchApp.fetch(url, peticion);
  } catch (e) {
    throw new Error('Telegram sin respuesta: ' + ocultarToken_(e.message, token));
  }
  const codigo = r.getResponseCode();
  if (codigo === 200) return;
  let descripcion = '';
  try { descripcion = JSON.parse(r.getContentText()).description; } catch (_) { /* no JSON */ }
  throw new Error(ocultarToken_(`Telegram ${codigo}: ${descripcion || r.getContentText()}`, token).slice(0, 300));
}

function ocultarToken_(texto, token) {
  return token ? String(texto).split(token).join('***') : String(texto);
}
