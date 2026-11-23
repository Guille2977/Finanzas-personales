/**
 * Main.gs — funciones que se ejecutan desde el menú o el activador.
 *
 *   probarConexion()     → paso 1: verifica URL, clave y permisos.
 *   capturarCorreos()    → lo llama el activador cada 15 min.
 *   crearActivador()     → crea el activador (idempotente: no se duplica).
 *   reprocesarErrores()  → tras corregir un extractor, reintenta los 'error'.
 *   (Sugerencias de IA para correos desconocidos: IA.gs.)
 *   (La reconstrucción completa está en Reconstruccion.gs.)
 * (Las funciones que terminan en "_" son internas y no salen en el menú.)
 */

function probarConexion() {
  const id = iniciarEjecucion_('latido');                       // INSERT
  const [leida] = db_.leer('ejecuciones', `select=id,proceso,inicio&id=eq.${id}`);   // SELECT
  finalizarEjecucion_(id, {}, ['Prueba de conexión desde Apps Script']);
  const fuentes = db_.leer('fuentes', 'select=nombre&activo=is.true');
  console.log(`✅ Conexión OK. Ejecución de prueba #${leida.id} (${leida.inicio}). Fuentes activas: ${fuentes.length}.`);
}

function capturarCorreos() {
  const ids = buscarIds_(consultaGmail_(), CONFIG.MAX_CORREOS_POR_CORRIDA);
  procesarLote_(ids, 'captura', { soloNuevos: true });
}

function reprocesarErrores() {
  const filas = db_.leer('correos_raw', 'select=gmail_message_id&estado=in.(error,pendiente)&limit=200');
  console.log(`Reprocesando ${filas.length} correo(s)…`);
  procesarLote_(filas.map(f => f.gmail_message_id), 'captura', { soloNuevos: false });
}

function crearActivador() {
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === 'capturarCorreos')
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('capturarCorreos').timeBased().everyMinutes(CONFIG.MINUTOS_ACTIVADOR).create();
  console.log(`✅ Activador creado: capturarCorreos cada ${CONFIG.MINUTOS_ACTIVADOR} min.`);
}

// ---------------------------------------------------------------------

/**
 * Procesa una lista de ids de Gmail.
 * - LockService: si una corrida aún no termina cuando arranca la siguiente,
 *   la segunda sale sin hacer nada (evita procesar dos veces a la vez).
 * - try/catch POR CORREO: un correo raro no detiene el lote.
 * - Si Supabase no responde, se corta el lote: los correos no marcados se
 *   reintentan en la siguiente corrida.
 */
function procesarLote_(ids, proceso, opciones) {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(5000)) { console.log('Otra ejecución sigue en curso; se omite esta.'); return; }

  const t0 = Date.now();
  const cont = { leidos: 0, insertados: 0, por_revisar: 0, errores: 0 };
  const mensajes = [];
  let idEjecucion = null;
  let ctx = null;
  try {
    idEjecucion = iniciarEjecucion_(proceso);
    ctx = { fuentes: cargarFuentes_() };
    const porProcesar = opciones.soloNuevos ? filtrarNuevos_(ids) : ids;

    for (const id of porProcesar) {
      if (Date.now() - t0 > CONFIG.LIMITE_MS) {
        mensajes.push('Límite de tiempo alcanzado; el resto sigue en la próxima corrida.');
        break;
      }
      cont.leidos++;
      try {
        const resultado = procesarCorreo_(leerCorreo_(id), ctx);
        if (resultado === 'procesado') cont.insertados++;
        if (resultado === 'por_revisar') cont.por_revisar++;
      } catch (e) {
        cont.errores++;
        mensajes.push(`${id}: ${e.message}`);
        if (e.transitorio) {
          mensajes.push('Supabase no responde; se corta el lote y se reintenta luego.');
          break;
        }
      }
    }
    console.log(`Leídos ${cont.leidos} · insertados ${cont.insertados} · por revisar ${cont.por_revisar} · errores ${cont.errores}`);
  } catch (e) {
    // Error general (p. ej. Supabase caído al inicio). Se relanza para que
    // Apps Script marque la ejecución como fallida y avise por correo.
    cont.errores++;
    mensajes.push('Error general: ' + e.message);
    throw e;
  } finally {
    const ia = ctx && ctx.ia;   // uso de Gemini en esta corrida (IA.gs)
    if (ia) {
      cont.llamadas_ia = ia.llamadas;
      if (ia.fallos || ia.cortada) mensajes.push(`IA: ${ia.llamadas} llamada(s), ${ia.fallos} fallo(s)${ia.cortada ? ', se dejó de llamar: ' + ia.cortada : ''}`);
    }
    finalizarEjecucion_(idEjecucion, cont, mensajes);
    lock.releaseLock();
  }
}

/**
 * Idempotencia: de los ids que trae Gmail, deja solo los que no están en
 * correos_raw o quedaron 'pendiente' (una corrida se cortó a la mitad).
 * Se consulta en grupos de 50 porque UrlFetch limita el largo de la URL.
 */
function filtrarNuevos_(ids) {
  const estado = {};
  for (let i = 0; i < ids.length; i += 50) {
    const grupo = ids.slice(i, i + 50);
    db_.leer('correos_raw', `select=gmail_message_id,estado&gmail_message_id=in.(${grupo.join(',')})`)
      .forEach(f => { estado[f.gmail_message_id] = f.estado; });
  }
  return ids.filter(id => !estado[id] || estado[id] === 'pendiente');
}

/**
 * Decide qué hacer con un correo SIN escribir en la base (solo lee: fn_clasificar).
 * La usan la captura normal y la reconstrucción, así ambas aplican
 * exactamente las mismas reglas.
 * Devuelve { fuente, estado: 'procesado'|'por_revisar'|'ignorado',
 *            detalle, datos, movimiento (solo si estado = 'procesado') }.
 */
function decidir_(correo, ctx) {
  const fuente = identificarFuente_(ctx.fuentes, correo.remitente, correo.asunto);

  // ¿Se ignora? Por configuración (tabla fuentes) o por texto de rechazo.
  if (fuente && fuente.accion === 'ignorar') return { fuente, estado: 'ignorado', detalle: `Regla: ${fuente.nombre}` };
  if (NO_MOVIMIENTO.test(correo.asunto)) return { fuente, estado: 'ignorado', detalle: 'Asunto de operación no realizada' };

  // Extraer con el extractor que dice la fuente (o el genérico).
  const nombreExtractor = fuente ? fuente.extractor : 'generico';
  const extractor = EXTRACTORES[nombreExtractor];
  if (!extractor) throw new Error(`El extractor "${nombreExtractor}" no existe en Extractores.gs`);
  const datos = extractor(correo);

  // Fuente desconocida o datos dudosos → "Por revisar" con los datos
  // prellenados; nunca se inserta algo dudoso.
  const motivo = !fuente ? 'Fuente desconocida (extractor genérico)'
               : !fuente.id_cuenta_defecto ? `La fuente "${fuente.nombre}" no tiene cuenta por defecto`
               : validarExtraccion_(datos);
  if (motivo) return { fuente, estado: 'por_revisar', detalle: motivo, datos };

  return {
    fuente, estado: 'procesado', datos,
    movimiento: {
      fecha: datos.fecha,
      monto: datos.monto,
      moneda: datos.moneda,
      sentido: fuente.sentido_defecto || datos.sentido,   // la configuración manda
      id_cuenta: fuente.id_cuenta_defecto,
      id_categoria: clasificar_(datos, fuente),
      descripcion: datos.descripcion,
      contraparte: datos.contraparte || null,
      numero_operacion: datos.numeroOperacion,
      origen: 'correo',
    },
  };
}

/** Guarda SIEMPRE el original primero (trazabilidad). Upsert por gmail_message_id. */
function guardarCorreo_(correo, fuente) {
  // No enviamos "estado": uno nuevo queda 'pendiente' (valor por defecto).
  return db_.upsert('correos_raw', [{
    gmail_message_id: correo.id,
    remitente: correo.remitente,
    asunto: correo.asunto,
    fecha_correo: correo.fecha,
    cuerpo: correo.cuerpo,
    id_fuente: fuente ? fuente.id_fuente : null,
  }], 'gmail_message_id')[0];
}

/**
 * Captura normal de un correo: guardar original → decidir → (IA si las
 * reglas no alcanzan; solo para "Por revisar") → insertar → marcar.
 * Devuelve 'procesado' | 'por_revisar' | 'ignorado'.
 */
function procesarCorreo_(correo, ctx) {
  const fuente = identificarFuente_(ctx.fuentes, correo.remitente, correo.asunto);
  const raw = guardarCorreo_(correo, fuente);
  try {
    // La IA solo completa un "Por revisar": nunca convierte un correo en movimiento.
    const d = completarConIA_(correo, decidir_(correo, ctx), ctx);
    if (d.estado !== 'procesado') return marcar_(raw, d.estado, d.detalle, d.datos, d.sugeridoPorIA);
    try {
      db_.insertar('movimientos', [Object.assign({}, d.movimiento, { id_correo: raw.id_correo })]);
    } catch (e) {
      // Segunda barrera de idempotencia: UNIQUE en la base.
      if (!esDuplicado_(e)) throw e;
      return /ux_mov_cuenta_operacion/.test(e.message)
        ? marcar_(raw, 'ignorado', `Duplicado: ya existe la operación ${d.movimiento.numero_operacion} en esa cuenta`)
        : marcar_(raw, 'procesado', 'El movimiento de este correo ya existía');
    }
    return marcar_(raw, 'procesado', null);
  } catch (e) {
    // Error de datos o de código: el correo queda en 'error' con la causa,
    // para verlo en Retool. Si la base está caída, ni esto se puede: queda
    // 'pendiente' y se reintenta solo.
    if (!e.transitorio) {
      try { marcar_(raw, 'error', e.message); } catch (_) { /* base caída */ }
    }
    throw e;
  }
}

function marcar_(raw, estado, detalle, datos, sugeridoPorIA) {
  db_.actualizar('correos_raw', `id_correo=eq.${raw.id_correo}`, {
    estado: estado,
    detalle_error: detalle,
    datos_extraidos: datos || null,
    sugerido_por_ia: Boolean(sugeridoPorIA),   // se envía siempre: un reproceso sin IA no deja la etiqueta vieja
    procesado_en: new Date().toISOString(),
  });
  return estado;
}
