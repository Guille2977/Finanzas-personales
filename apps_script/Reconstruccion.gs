/**
 * Reconstruccion.gs — vuelve a registrar TODO desde los correos de Gmail.
 *
 *   reconstruirPrueba()      → modo prueba (dry run): NO escribe nada,
 *                              solo muestra qué haría. Ejecútalo primero.
 *   reconstruirAplicar()     → aplica los cambios.
 *   cancelarReconstruccion() → detiene una reconstrucción a medias.
 *
 * Reglas (los datos del correo mandan sobre los de la hoja):
 *   · Si el movimiento ya existe → se REEMPLAZA con lo detectado (UPDATE).
 *     Se busca por: 1) el mismo correo, 2) misma cuenta + número de
 *     operación, 3) un registro manual sin correo del mismo día, monto y
 *     sentido (filas de la hoja sin id o registros manuales).
 *   · Si no existe → se inserta.
 *   · Si ahora la regla dice "ignorar" (rechazo, pendiente) y había un
 *     movimiento → se ANULA (estado = 'anulado'). Nada se borra.
 *   · Si la extracción nueva falla ("por revisar") pero ya había un
 *     movimiento → se CONSERVA el existente: mejor un dato conocido que nada.
 *   · La categoría nueva reemplaza a la anterior; si la nueva queda vacía,
 *     se conserva la que tenía.
 *   · Huérfanos (movimientos que no aparecen en ningún correo de la
 *     ventana): NO se tocan, solo se listan. Puede ser un correo borrado o
 *     más antiguo que la ventana; el dinero sí se movió, así que borrarlo
 *     sería perder información. Si alguno sobra, se anula a mano en Retool.
 *
 * Límite de 6 min: procesa por lotes. Si se acaba el tiempo, guarda su
 * avance en las propiedades del script y programa una continuación
 * automática en 1 min (continuarReconstruccion). Usa el mismo lock que la
 * captura, así nunca corren las dos a la vez.
 */

const RECONSTRUIR = {
  DIAS_DEFECTO: 90,       // ventana hacia atrás; cámbiala con la propiedad RECONSTRUIR_DIAS
  MAX_CORREOS: 1500,
  CLAVE_ESTADO: 'RECONSTRUCCION_ESTADO',
};

function reconstruirPrueba() { iniciarReconstruccion_(true); }
function reconstruirAplicar() { iniciarReconstruccion_(false); }

/** La llama el activador de continuación (no la ejecutes a mano). */
function continuarReconstruccion() {
  borrarContinuaciones_();
  const est = leerEstado_();
  if (est) pasoReconstruccion_(est);
}

function cancelarReconstruccion() {
  borrarContinuaciones_();
  PropertiesService.getScriptProperties().deleteProperty(RECONSTRUIR.CLAVE_ESTADO);
  console.log('Reconstrucción cancelada. Lo ya aplicado se queda (todo es idempotente: puedes volver a empezar).');
}

// ---------------------------------------------------------------------

function iniciarReconstruccion_(prueba) {
  if (leerEstado_()) {
    throw new Error('Ya hay una reconstrucción en curso. Espera a que termine o ejecuta cancelarReconstruccion().');
  }
  const est = {
    prueba: prueba,
    dias: Number(propiedad_('RECONSTRUIR_DIAS', true)) || RECONSTRUIR.DIAS_DEFECTO,
    offset: 0,          // cuántos correos de la lista ya se recorrieron
    c: { leidos: 0, nuevos: 0, reemplazados: 0, con_cambios: 0, conservados: 0,
         anulados: 0, por_revisar: 0, ignorados: 0, duplicados: 0, errores: 0 },
    vistos: [],         // id_movimiento tocados (para calcular huérfanos)
    muestras: [],       // ejemplos para el reporte
    motivos: {},        // remitente | asunto | motivo → cantidad (para crear fuentes nuevas)
    errores: [],
  };
  console.log(`${prueba ? '🔎 MODO PRUEBA (no escribe nada)' : '✍️ APLICANDO cambios'} · ventana ${est.dias} días`);
  guardarEstado_(est);
  pasoReconstruccion_(est);
}

function pasoReconstruccion_(est) {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) { programarContinuacion_(); console.log('Lock ocupado; continúa en 1 min.'); return; }
  const t0 = Date.now();
  const leidosAntes = est.c.leidos;
  const erroresAntes = est.c.errores;
  let idEjecucion = null;
  try {
    if (!est.prueba) idEjecucion = iniciarEjecucion_('captura');
    const ctx = { fuentes: cargarFuentes_() };
    // Se cargan una vez por lote (las tablas son pequeñas): así cada correo
    // se compara en memoria en vez de hacer varias consultas.
    const movs = db_.leer('movimientos',
      'select=id_movimiento,id_correo,id_cuenta,numero_operacion,origen,fecha,monto,sentido,estado,id_categoria,contraparte,descripcion&order=id_movimiento&limit=10000');
    const correosBd = {};
    db_.leer('correos_raw', 'select=id_correo,gmail_message_id&limit=10000')
      .forEach(r => { correosBd[r.gmail_message_id] = r.id_correo; });

    // Gmail devuelve del más nuevo al más antiguo. Si llega un correo nuevo
    // entre lotes, la lista se corre 1 posición: a lo más se revisa uno dos
    // veces (inofensivo, todo es idempotente), nunca se salta uno.
    const ids = buscarIds_(consultaReconstruccion_(est.dias), RECONSTRUIR.MAX_CORREOS);

    while (est.offset < ids.length) {
      if (Date.now() - t0 > CONFIG.LIMITE_MS) {
        guardarEstado_(est);
        programarContinuacion_();
        console.log(`⏸️ Avance ${est.offset}/${ids.length}. Continúa sola en 1 min.`);
        return;
      }
      const id = ids[est.offset];
      try {
        reconstruirCorreo_(leerCorreo_(id), ctx, movs, correosBd, est);
      } catch (e) {
        if (e.transitorio) {            // Supabase no responde: reintentar este mismo correo luego
          guardarEstado_(est);
          programarContinuacion_();
          console.log('Supabase no responde; se reintenta en 1 min.');
          return;
        }
        est.c.errores++;
        if (est.errores.length < 10) est.errores.push(`${id}: ${e.message}`);
      }
      est.offset++;
    }

    reportar_(est, movs, ids.length);
    PropertiesService.getScriptProperties().deleteProperty(RECONSTRUIR.CLAVE_ESTADO);
  } catch (e) {
    // Falla general (p. ej. Supabase caído al cargar): si es pasajera, se
    // reintenta sola; si no, el avance queda guardado y se ve el error.
    if (e.transitorio) programarContinuacion_();
    throw e;
  } finally {
    finalizarEjecucion_(idEjecucion, { leidos: est.c.leidos - leidosAntes, errores: est.c.errores - erroresAntes },
      [`Reconstrucción desde correos (lote). Acumulado: ${JSON.stringify(est.c)}`]);
    lock.releaseLock();
  }
}

/** Aplica (o simula) la reconstrucción de UN correo. */
function reconstruirCorreo_(correo, ctx, movs, correosBd, est) {
  est.c.leidos++;
  const d = decidir_(correo, ctx);
  let idCorreo = correosBd[correo.id] || null;
  if (!est.prueba) {
    // Reemplaza también las filas "(migrado desde Google Sheets)" con los datos reales del correo.
    idCorreo = guardarCorreo_(correo, d.fuente).id_correo;
    correosBd[correo.id] = idCorreo;
  }
  const existente = buscarExistente_(movs, idCorreo, d.movimiento);
  const etiqueta = `${correo.fecha.slice(0, 10)} · ${correo.asunto.slice(0, 45)}`;

  // --- El correo NO genera movimiento ---
  if (d.estado !== 'procesado') {
    if (existente && existente.estado === 'activo' && d.estado === 'ignorado') {
      if (!est.prueba) db_.actualizar('movimientos', `id_movimiento=eq.${existente.id_movimiento}`, { estado: 'anulado' });
      existente.estado = 'anulado';
      marcarVisto_(est, existente);
      est.c.anulados++;
      muestra_(est, `anula #${existente.id_movimiento} (${d.detalle}) · ${etiqueta}`);
      if (!est.prueba) marcar_({ id_correo: idCorreo }, 'ignorado', `${d.detalle}; se anuló el movimiento #${existente.id_movimiento}`);
      return;
    }
    if (existente && d.estado === 'por_revisar') {
      marcarVisto_(est, existente);
      est.c.conservados++;
      contarMotivo_(est, correo, d.detalle);
      muestra_(est, `conserva #${existente.id_movimiento}: la extracción nueva falló (${d.detalle})`);
      if (!est.prueba) marcar_({ id_correo: idCorreo }, 'procesado', `Se conservó el movimiento existente; extracción nueva: ${d.detalle}`, d.datos);
      return;
    }
    est.c[d.estado === 'ignorado' ? 'ignorados' : 'por_revisar']++;
    if (d.estado === 'por_revisar') contarMotivo_(est, correo, d.detalle);
    if (!est.prueba) marcar_({ id_correo: idCorreo }, d.estado, d.detalle, d.datos);
    return;
  }

  // --- El correo SÍ genera movimiento ---
  const fila = Object.assign({}, d.movimiento, { id_correo: idCorreo, estado: 'activo' });

  if (existente && existente.id_correo && existente.id_correo !== idCorreo) {
    // Esa operación ya pertenece a OTRO correo: este es un duplicado.
    est.c.duplicados++;
    if (!est.prueba) marcar_({ id_correo: idCorreo }, 'ignorado',
      `Duplicado: la operación ${fila.numero_operacion} ya es del movimiento #${existente.id_movimiento}`);
    return;
  }

  if (existente) {
    fila.id_categoria = fila.id_categoria || existente.id_categoria;   // no perder una categoría
    const cambios = diferencias_(existente, fila);
    if (!est.prueba) db_.actualizar('movimientos', `id_movimiento=eq.${existente.id_movimiento}`, fila);
    Object.assign(existente, fila);
    marcarVisto_(est, existente);
    est.c.reemplazados++;
    if (cambios.length) {
      est.c.con_cambios++;
      muestra_(est, `reemplaza #${existente.id_movimiento}: ${cambios.join(', ')}`);
    }
    if (!est.prueba) marcar_({ id_correo: idCorreo }, 'procesado', 'Reemplazado por reconstrucción');
  } else {
    let nuevo = Object.assign({ id_movimiento: null }, fila);
    if (!est.prueba) nuevo = db_.insertar('movimientos', [fila])[0];
    movs.push(nuevo);          // para detectar duplicados dentro de la misma corrida
    marcarVisto_(est, nuevo);
    est.c.nuevos++;
    muestra_(est, `nuevo: S/ ${fila.monto} · ${etiqueta}`);
    if (!est.prueba) marcar_({ id_correo: idCorreo }, 'procesado', null);
  }
}

/** Busca el movimiento que corresponde a este correo (ver reglas arriba). */
function buscarExistente_(movs, idCorreo, m) {
  if (idCorreo) {
    const porCorreo = movs.find(x => x.id_correo === idCorreo);
    if (porCorreo) return porCorreo;
  }
  if (!m) return null;
  if (m.numero_operacion) {
    const porOperacion = movs.find(x => x.id_cuenta === m.id_cuenta && x.numero_operacion === m.numero_operacion);
    if (porOperacion) return porOperacion;
  }
  return movs.find(x => !x.id_correo && x.origen === 'manual' && x.estado === 'activo'
    && x.sentido === m.sentido && Number(x.monto) === Number(m.monto)
    && diaLima_(x.fecha) === diaLima_(m.fecha)) || null;
}

function diferencias_(antes, despues) {
  const cambios = [];
  if (Number(antes.monto) !== Number(despues.monto)) cambios.push(`monto ${antes.monto}→${despues.monto}`);
  if (antes.sentido !== despues.sentido) cambios.push(`sentido ${antes.sentido}→${despues.sentido}`);
  if (antes.id_cuenta !== despues.id_cuenta) cambios.push(`cuenta ${antes.id_cuenta}→${despues.id_cuenta}`);
  if (Math.floor(new Date(antes.fecha) / 1000) !== Math.floor(new Date(despues.fecha) / 1000)) cambios.push('fecha');
  if ((antes.contraparte || '') !== (despues.contraparte || '')) cambios.push('contraparte');
  if (antes.id_categoria !== despues.id_categoria) cambios.push('categoría');
  if (antes.estado !== 'activo') cambios.push('reactivado');
  return cambios;
}

function reportar_(est, movs, totalCorreos) {
  const vistos = new Set(est.vistos);
  const huerfanos = movs.filter(m => m.id_movimiento && m.estado === 'activo' && !vistos.has(m.id_movimiento));
  const c = est.c;
  const p = est.prueba;
  const lineas = [
    `${est.prueba ? '🔎 RESULTADO DE LA PRUEBA (no se escribió nada)' : '✅ RECONSTRUCCIÓN APLICADA'} · ${totalCorreos} correos en ${est.dias} días`,
    `  ${p ? 'Se insertarían' : 'Insertados'}: ${c.nuevos}`,
    `  ${p ? 'Se reemplazarían' : 'Reemplazados'}: ${c.reemplazados} (con cambios reales: ${c.con_cambios})`,
    `  ${p ? 'Se anularían' : 'Anulados'} (ahora la regla los ignora): ${c.anulados}`,
    `  ${p ? 'Se conservarían' : 'Conservados'} (la extracción nueva falló): ${c.conservados}`,
    `  Por revisar: ${c.por_revisar} · Ignorados: ${c.ignorados} · Duplicados: ${c.duplicados} · Errores: ${c.errores}`,
    `  Huérfanos (no están en ningún correo; NO se tocan): ${huerfanos.length}`,
  ];
  huerfanos.slice(0, 15).forEach(h =>
    lineas.push(`    #${h.id_movimiento} · ${diaLima_(h.fecha)} · ${h.sentido} ${h.monto} · ${h.descripcion || ''} · origen ${h.origen}`));
  const motivos = Object.entries(est.motivos || {}).sort((a, b) => b[1] - a[1]).slice(0, 20);
  if (motivos.length) lineas.push('  Por revisar, agrupados (remitente | asunto | motivo):',
    ...motivos.map(([k, n]) => `    ${n} × ${k}`));
  if (est.muestras.length) lineas.push('  Ejemplos:', ...est.muestras.map(m => '    ' + m));
  if (est.errores.length) lineas.push('  Errores:', ...est.errores.map(e => '    ' + e));
  console.log(lineas.join('\n'));
}

// --- Utilidades --------------------------------------------------------

function consultaReconstruccion_(dias) {
  const base = consultaGmail_();
  return /newer_than:\S+/.test(base) ? base.replace(/newer_than:\S+/, `newer_than:${dias}d`) : `${base} newer_than:${dias}d`;
}

function diaLima_(fecha) {
  return Utilities.formatDate(new Date(fecha), CONFIG.ZONA, 'yyyy-MM-dd');
}

function marcarVisto_(est, mov) {
  if (mov.id_movimiento && !est.vistos.includes(mov.id_movimiento)) est.vistos.push(mov.id_movimiento);
}

/** Agrupa los "por revisar" para saber qué fuentes faltan configurar. */
function contarMotivo_(est, correo, motivo) {
  est.motivos = est.motivos || {};
  const remitente = (correo.remitente.match(/<([^>]+)>/) || [, correo.remitente])[1];
  const clave = `${remitente} | ${correo.asunto.slice(0, 50)} | ${motivo}`.slice(0, 160);
  if (est.motivos[clave] || Object.keys(est.motivos).length < 30) est.motivos[clave] = (est.motivos[clave] || 0) + 1;
}

function muestra_(est, texto) {
  if (est.muestras.length < 25) est.muestras.push(texto);
}

// El avance se guarda como JSON en las propiedades del script (límite ~9 KB por valor).
function guardarEstado_(est) {
  PropertiesService.getScriptProperties().setProperty(RECONSTRUIR.CLAVE_ESTADO, JSON.stringify(est));
}
function leerEstado_() {
  const t = PropertiesService.getScriptProperties().getProperty(RECONSTRUIR.CLAVE_ESTADO);
  return t ? JSON.parse(t) : null;
}

function programarContinuacion_() {
  borrarContinuaciones_();
  ScriptApp.newTrigger('continuarReconstruccion').timeBased().after(60 * 1000).create();
}
function borrarContinuaciones_() {
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === 'continuarReconstruccion')
    .forEach(t => ScriptApp.deleteTrigger(t));
}
