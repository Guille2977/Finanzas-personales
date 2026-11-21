/**
 * Bot.gs — lógica del bot: interpretar mensajes, registrar, botones y comandos.
 *
 * Flujo de un mensaje como "pasaje 3, yape 10 menú":
 *   1. interpretarMensaje_ (REGLAS, función pura y probada): monto, medio,
 *      sentido, fecha y "concepto" de cada gasto.
 *   2. Categoría por diccionario (Categorias.gs).
 *        · La encuentra → registra y muestra [Cambiar categoría] [Deshacer].
 *        · No la encuentra → registra SIN categoría (el dinero nunca se pierde)
 *          y pregunta con botones; Gemini solo SUGIERE el primer botón.
 *          Al elegir, la palabra se guarda en el diccionario (aprende).
 *   3. Si las reglas no encuentran el monto → Gemini propone el movimiento
 *      completo y NO se registra hasta [Confirmar] (humano en el ciclo).
 *
 * Botones: callback_data (máx. 64 bytes) lleva todo lo necesario, así no hay
 * que guardar "propuestas pendientes" en ninguna tabla:
 *   k|idMov|idCat|palabra  fijar categoría y aprender la palabra
 *   m|idMov                mostrar menú de categorías
 *   u|idMov                deshacer (estado = 'anulado', nunca DELETE)
 *   p|centimos|idCat|idCuenta|e/i|díasAtrás|palabra   confirmar propuesta
 *   x                      cancelar propuesta
 */

const BOT = {
  // Alias de la tabla `cuentas` (configuración: si cambias el alias allá, cambia aquí).
  CUENTA_EFECTIVO: 'Efectivo',
  CUENTA_YAPE: 'BCP Yape',
  // Por encima de esto se pide confirmar (evita un "1500" por "15.00").
  MONTO_CONFIRMAR: 500,
  MAX_DIAS_ATRAS: 7,
  CACHE_SEG: 600,              // categorías/cuentas/diccionario en caché 10 min
  YAPE: ['yape', 'yapee', 'yapie', 'yapeo', 'yapeado', 'yapeaste', 'yapearon', 'yapeo'],
  EFECTIVO: ['efectivo', 'cash', 'sencillo'],
  INGRESO: ['me pagaron', 'me yapearon', 'me dieron', 'me depositaron', 'me devolvieron',
            'me transfirieron', 'recibi', 'cobre', 'gane', 'ingreso'],
  FECHAS: { hoy: 0, ayer: 1, anteayer: 2 },
  MONEDA: ['soles', 'sol', 'lucas', 'luca', 's'],
  RELLENO: ['de', 'del', 'la', 'el', 'los', 'las', 'lo', 'un', 'una', 'unos', 'unas', 'en', 'por',
            'para', 'pa', 'con', 'al', 'a', 'y', 'o', 'me', 'mi', 'mis', 'se', 'que', 'compre',
            'gaste', 'pague', 'gasto'],
};

let CTX_BOT_ = null;    // caché por ejecución

// ---------------------------------------------------------------------
// 1. Interpretación por reglas (PURA: sin red ni base → se prueba en Pruebas.gs)
// ---------------------------------------------------------------------

/** Separa por coma+espacio, punto y coma o salto de línea ("3,50" no se corta). */
function interpretarMensaje_(texto) {
  const items = String(texto || '').split(/\s*(?:;|\n|,\s+)\s*/).filter(s => s.trim())
    .map(interpretarItem_);
  // "ayer menú 12, pasaje 3": la fecha dicha vale para los siguientes.
  let dias = 0;
  items.forEach(it => { if (it.diasAtras === null) it.diasAtras = dias; else dias = it.diasAtras; });
  return items;
}

function interpretarItem_(original) {
  const texto = original.trim();
  // Separa "s/3", "S/.3" y "3soles" para tratarlos como palabras sueltas.
  const tokens = (' ' + texto.toLowerCase() + ' ')
    .replace(/s\/\.?/g, ' s/ ')
    .replace(/(\d)(soles|sol|lucas|luca)\b/g, '$1 $2')
    .split(/\s+/).filter(Boolean)
    .map(t => t.replace(/[!?¡¿:]+$/g, '').replace(/(\d)\.$/, '$1'));

  // Montos: 3 · 3.5 · 3,50 · .2 · S/ 3 · 3 soles
  const esMonto = t => /^(\d+([.,]\d{1,2})?|[.,]\d{1,2})$/.test(t);
  const candidatos = [];
  tokens.forEach((t, i) => {
    if (!esMonto(t)) return;
    const marcado = tokens[i - 1] === 's/' || BOT.MONEDA.includes(tokens[i + 1]);
    candidatos.push({ i, valor: Math.round(parseFloat(t.replace(',', '.')) * 100) / 100, marcado });
  });
  const marcados = candidatos.filter(c => c.marcado);
  const elegido = candidatos.length === 1 ? candidatos[0] : marcados.length === 1 ? marcados[0] : null;

  // El resto, normalizado (minúsculas, sin tildes), sin el monto ni "s/".
  let palabras = normalizar_(tokens.filter((t, i) => !(elegido && i === elegido.i) && t !== 's/').join(' '))
    .split(' ').filter(Boolean);

  let sentido = 'egreso';
  const unido = ' ' + palabras.join(' ') + ' ';
  const frase = BOT.INGRESO.find(f => unido.includes(` ${f} `));
  if (frase) {
    sentido = 'ingreso';
    const partes = frase.split(' ');
    const ini = palabras.findIndex((p, i) => partes.every((q, j) => palabras[i + j] === q));
    palabras.splice(ini, partes.length);
  }

  let medio = 'efectivo';
  if (palabras.some(p => BOT.YAPE.includes(p)) || frase === 'me yapearon') medio = 'yape';
  palabras = palabras.filter(p => !BOT.YAPE.includes(p) && !BOT.EFECTIVO.includes(p));

  let diasAtras = null;
  palabras = palabras.filter(p => {
    if (p in BOT.FECHAS) { diasAtras = BOT.FECHAS[p]; return false; }
    return true;
  });

  // Contraparte solo en Yape: "yape 10 a Pedro" (enviado) / "me yapearon 5 de Ana" (recibido).
  let contraparte = null;
  if (medio === 'yape') {
    const prep = sentido === 'ingreso' ? 'de' : 'a';
    const i = palabras.findIndex((p, k) => p === prep && palabras[k + 1] && !BOT.RELLENO.includes(palabras[k + 1]));
    if (i >= 0) {
      const nombre = palabras[i + 1];
      contraparte = nombre.charAt(0).toUpperCase() + nombre.slice(1);
      palabras.splice(i, 2);
    }
  }

  const concepto = palabras.filter(p => !BOT.RELLENO.includes(p) && !BOT.MONEDA.includes(p) && !esMonto(p)).join(' ');
  return {
    original: texto,
    monto: elegido ? elegido.valor : null,
    ambiguo: !elegido && candidatos.length > 1,
    sentido, medio, diasAtras, contraparte, concepto,
  };
}

/** Palabra que se aprende: la primera del concepto (la más significativa). */
function palabraClave_(concepto) {
  return String(concepto || '').split(' ').find(p => p.length >= 3 && !/^\d+$/.test(p)) || '';
}

/** callback_data acepta 64 BYTES (ñ = 2): se recorta la palabra si no entra. */
function dataBoton_(partes, palabra) {
  const bytes = s => unescape(encodeURIComponent(s)).length;
  const base = partes.join('|');
  let p = String(palabra || '');
  while (p && bytes(base + '|' + p) > 64) p = p.slice(0, -1);
  return base + '|' + (p.length >= 3 ? p : '');
}

// ---------------------------------------------------------------------
// 2. Despacho
// ---------------------------------------------------------------------

function manejarUpdate_(update, cont) {
  if (update.callback_query) return manejarBoton_(update.callback_query, cont);
  const msg = update.message;
  if (!msg) return;
  const chat = msg.chat.id;
  if (!msg.text) return enviar_(chat, 'Solo entiendo texto. Escribe /ayuda.');
  const texto = msg.text.trim();

  if (texto.startsWith('/')) return manejarComando_(texto.split(/[\s@]/)[0].toLowerCase(), chat);
  if (normalizar_(texto) === 'deshacer') return deshacerUltimo_(chat, msg.message_id);

  interpretarMensaje_(texto).forEach((it, i) =>
    registrarItem_(it, chat, msg.message_id, `TG-${update.update_id}-${i + 1}`, cont));
}

function registrarItem_(it, chat, idMsg, clave, cont) {
  const ctx = contextoBot_();

  // Sin monto claro → la IA propone; si no hay IA o falla, se explica el formato.
  if (!it.monto) {
    const prop = iaInterpretar_(it.original, ctx.categorias, BOT.MONTO_CONFIRMAR * 20, BOT.MAX_DIAS_ATRAS);
    if (!prop) {
      cont.por_revisar++;
      return enviar_(chat, `🤔 No entendí «${escaparHtml_(it.original)}»` +
        (it.ambiguo ? ' (hay más de un número).' : '.') + '\nEjemplo: <code>menú 12</code> · <code>yape 10 a Pedro cuota</code>', null, idMsg);
    }
    prop.id_cuenta = idCuentaBot_(prop.medio, ctx);
    return proponer_(chat, idMsg, prop, '🤖 La IA entendió esto. ¿Lo registro?', ctx);
  }

  const cuenta = idCuentaBot_(it.medio, ctx);
  const datos = {
    monto: it.monto, sentido: it.sentido, id_cuenta: cuenta, dias: it.diasAtras,
    id_categoria: categoriaPorDiccionario_(it, ctx), palabra: palabraClave_(it.concepto),
  };

  if (it.monto > BOT.MONTO_CONFIRMAR) {
    return proponer_(chat, idMsg, datos, `⚠️ S/ ${it.monto.toFixed(2)} es un monto alto. ¿Lo registro?`, ctx);
  }
  // Los Yape RECIBIDOS ya llegan por correo: si hay uno igual ese día, se pregunta.
  if (it.sentido === 'ingreso' && it.medio === 'yape') {
    const previo = buscarIngresoParecido_(cuenta, it.monto, fechaDias_(it.diasAtras));
    if (previo) {
      return proponer_(chat, idMsg, datos,
        `🔁 Ya tengo un Yape recibido de S/ ${it.monto.toFixed(2)} ese día` +
        (previo.contraparte ? ` (${escaparHtml_(previo.contraparte)})` : '') + '. ¿Es otro distinto?', ctx, 'Es otro: registrar', 'Es el mismo');
    }
  }

  const mov = insertarMovBot_(datos, it.original, it.contraparte, clave);
  if (!mov) return;                                        // ya existía (reintento)
  cont.insertados++;
  if (mov.id_categoria) return enviar_(chat, textoMov_(mov, ctx), tecladoMov_(mov), idMsg);
  cont.por_revisar++;
  preguntarCategoria_(chat, idMsg, mov, it.concepto, ctx);
}

/** Diccionario, pero solo si la categoría es del mismo tipo (un ingreso no cae en "Comida"). */
function categoriaPorDiccionario_(it, ctx) {
  const id = clasificar_({ descripcion: it.concepto, contraparte: it.contraparte }, null, ctx.diccionario);
  const cat = ctx.categorias.find(c => c.id_categoria === id);
  return cat && cat.tipo === it.sentido ? id : null;
}

/**
 * Pregunta la categoría en DOS tiempos para no hacer esperar al usuario:
 *   1. Envía YA los botones de categorías (sin IA).
 *   2. Luego consulta a Gemini y, si sugiere algo válido, EDITA el mensaje
 *      para agregar el botón "sugerida por IA" arriba.
 * Si Gemini tarda o falla, el usuario ya tiene sus botones.
 */
function preguntarCategoria_(chat, idMsg, mov, concepto, ctx, editarId) {
  const tipo = mov.sentido;
  const palabra = palabraClave_(concepto);
  const pintar = (sug, idDestino) => {
    const palabraFinal = sug && sug.palabra ? sug.palabra : palabra;
    const teclado = [];
    if (sug) teclado.push([{ text: `✅ ${[sug.icono, sug.nombre].filter(Boolean).join(' ')} (sugerida por IA)`, callback_data: dataBoton_(['k', mov.id_movimiento, sug.id_categoria], palabraFinal) }]);
    teclado.push(...tecladoCategorias_(mov.id_movimiento, tipo, palabraFinal, ctx));
    teclado.push([{ text: '↩️ Deshacer', callback_data: `u|${mov.id_movimiento}` }]);
    const html = `${textoMov_(mov, ctx)}\n\n¿Qué categoría es${palabraFinal ? ` «${escaparHtml_(palabraFinal)}»` : ''}?` +
      (palabraFinal ? ' La recordaré para la próxima.' : '') + (sug === undefined && palabra && iaActiva_() ? '\n🤖 Consultando a la IA…' : '');
    return idDestino ? editar_(chat, idDestino, html, teclado) : enviar_(chat, html, teclado, idMsg);
  };
  // 1. Respuesta inmediata.
  const enviado = pintar(undefined, editarId);
  if (!palabra || !iaActiva_()) return;
  // 2. Sugerencia de la IA (puede tardar unos segundos).
  const idDestino = editarId || (enviado && enviado.message_id);
  const sug = iaSugerirCategoria_(concepto, ctx.categorias.filter(c => c.tipo === tipo));
  try { pintar(sug || null, idDestino); } catch (e) { console.warn('No se pudo agregar la sugerencia: ' + e.message); }
}

// ---------------------------------------------------------------------
// 3. Botones
// ---------------------------------------------------------------------

function manejarBoton_(cq, cont) {
  const chat = cq.message.chat.id;
  const idMsg = cq.message.message_id;
  const a = String(cq.data || '').split('|');
  // Se responde al toque YA (quita el "cargando" del botón); el resultado se ve
  // en el mensaje editado. answerCallbackQuery solo puede usarse una vez.
  try { tg_('answerCallbackQuery', { callback_query_id: cq.id }); } catch (_) { /* vencido */ }
  const ctx = contextoBot_();
  let aviso = '';
  {
    switch (a[0]) {
      case 'k': {                                          // fijar categoría (+ aprender)
        const mov = actualizarMovBot_(a[1], { id_categoria: Number(a[2]) });
        if (!mov) { aviso = 'Ese movimiento ya no existe.'; break; }
        const palabra = a[3] ? aprenderPalabra_(a[3], Number(a[2]), mov.sentido, ctx) : null;
        editar_(chat, idMsg, textoMov_(mov, ctx) + (palabra ? `\n📚 Aprendí: «${escaparHtml_(palabra)}» → ${escaparHtml_(nombreCat_(mov.id_categoria, ctx))}` : ''), tecladoMov_(mov));
        aviso = 'Categoría guardada';
        break;
      }
      case 'm': {                                          // cambiar categoría
        const [mov] = db_.leer('movimientos', `select=*&id_movimiento=eq.${Number(a[1])}&origen=eq.telegram`);
        if (!mov) { aviso = 'Ese movimiento ya no existe.'; break; }
        const concepto = interpretarItem_(mov.descripcion || '').concepto;
        const teclado = tecladoCategorias_(mov.id_movimiento, mov.sentido, palabraClave_(concepto), ctx);
        teclado.push([{ text: '↩️ Deshacer', callback_data: `u|${mov.id_movimiento}` }]);
        editar_(chat, idMsg, textoMov_(mov, ctx) + '\n\nElige la nueva categoría:', teclado);
        break;
      }
      case 'u': {                                          // deshacer
        const mov = actualizarMovBot_(a[1], { estado: 'anulado' });
        editar_(chat, idMsg, mov ? `↩️ <s>${textoMov_(mov, ctx)}</s>\nAnulado.` : 'Ya no existe.');
        aviso = 'Anulado';
        break;
      }
      case 'p': {                                          // confirmar propuesta
        const datos = { monto: Number(a[1]) / 100, id_categoria: Number(a[2]) || null, id_cuenta: Number(a[3]),
                        sentido: a[4] === 'i' ? 'ingreso' : 'egreso', dias: Number(a[5]) || 0 };
        const original = (cq.message.reply_to_message && cq.message.reply_to_message.text) || 'Registro desde Telegram';
        // Clave de idempotencia = mensaje del bot: dos toques no registran dos veces.
        const mov = insertarMovBot_(datos, original.slice(0, 200), null, `TG-B${idMsg}`);
        if (!mov) { editar_(chat, idMsg, 'Ya estaba registrado.'); break; }
        cont.insertados++;
        const palabra = a[6] && datos.id_categoria ? aprenderPalabra_(a[6], datos.id_categoria, datos.sentido, ctx) : null;
        if (mov.id_categoria) {
          editar_(chat, idMsg, textoMov_(mov, ctx) + (palabra ? `\n📚 Aprendí: «${escaparHtml_(palabra)}»` : ''), tecladoMov_(mov));
        } else {
          preguntarCategoria_(chat, null, mov, interpretarItem_(original).concepto, ctx, idMsg);
        }
        aviso = 'Registrado';
        break;
      }
      case 'x':
        editar_(chat, idMsg, 'Listo, no registré nada.');
        break;
      default:
        aviso = 'Botón desconocido';
    }
  }
  if (aviso && /no existe|desconocido/.test(aviso)) editar_(chat, idMsg, escaparHtml_(aviso));
}

// ---------------------------------------------------------------------
// 4. Comandos
// ---------------------------------------------------------------------

function manejarComando_(cmd, chat) {
  const hoy = diaLima_(new Date());
  switch (cmd) {
    case '/hoy': {
      const filas = db_.leer('v_movimientos_contables',
        `select=monto,sentido,categoria,descripcion,contraparte,es_transferencia&dia=eq.${hoy}&order=fecha_lima.asc`);
      if (!filas.length) return enviar_(chat, 'Hoy no hay movimientos.');
      const lineas = filas.slice(-30).map(f =>
        `${f.sentido === 'ingreso' ? '➕' : '➖'} S/ ${Number(f.monto).toFixed(2)} · ${escaparHtml_(f.categoria)} · ${escaparHtml_((f.descripcion || f.contraparte || '').slice(0, 40))}`);
      return enviar_(chat, `<b>Hoy</b>\n${lineas.join('\n')}\n\n${totales_(filas)}`);
    }
    case '/semana': {
      const filas = db_.leer('v_movimientos_contables', `select=monto,sentido,categoria,es_transferencia&semana=eq.${lunesLima_()}`);
      return enviar_(chat, `<b>Esta semana</b>\n${porCategoria_(filas)}\n\n${totales_(filas)}`);
    }
    case '/mes': {
      const filas = db_.leer('v_gasto_categoria_mes', `select=categoria,sentido,total&mes=eq.${hoy.slice(0, 8)}01&moneda=eq.PEN&order=total.desc`);
      const egr = filas.filter(f => f.sentido === 'egreso');
      const total = egr.reduce((s, f) => s + Number(f.total), 0);
      return enviar_(chat, `<b>Gasto del mes</b>\n` +
        (egr.map(f => `• ${escaparHtml_(f.categoria)}: S/ ${Number(f.total).toFixed(2)}`).join('\n') || 'Sin gastos aún.') +
        `\n\nTotal: <b>S/ ${total.toFixed(2)}</b>`);
    }
    case '/presupuesto': {
      const filas = db_.leer('v_avance_presupuesto', 'select=categoria,limite,gastado,porcentaje,estado&order=porcentaje.desc');
      if (!filas.length) return enviar_(chat, 'No hay presupuestos definidos (tabla presupuestos).');
      const icono = { ok: '🟢', alerta: '🟡', excedido: '🔴' };
      return enviar_(chat, '<b>Presupuestos del mes</b>\n' + filas.map(f =>
        `${icono[f.estado] || '•'} ${escaparHtml_(f.categoria)}: ${f.porcentaje}% (S/ ${Number(f.gastado).toFixed(2)} de ${Number(f.limite).toFixed(2)})`).join('\n'));
    }
    default:
      return enviar_(chat,
        '<b>Cómo registrar</b> (efectivo por defecto)\n' +
        '<code>pasaje 3</code> · <code>queque .2</code> · <code>3 soles de pasaje</code>\n' +
        '<code>yape 10 a Pedro cuota</code> → Yape enviado\n' +
        '<code>ayer menú 12</code> · <code>pasaje 3, golosina 1.5</code>\n' +
        '<code>me pagaron 50</code> · <code>me yapearon 5 de Ana</code> → ingreso\n' +
        '<code>deshacer</code> → anula el último\n\n/hoy · /semana · /mes · /presupuesto');
  }
}

function deshacerUltimo_(chat, idMsg) {
  const [ultimo] = db_.leer('movimientos',
    'select=id_movimiento&origen=eq.telegram&estado=eq.activo&order=creado_en.desc&limit=1');   // LIMIT ≈ TOP 1
  if (!ultimo) return enviar_(chat, 'No hay registros del bot para deshacer.', null, idMsg);
  const mov = actualizarMovBot_(ultimo.id_movimiento, { estado: 'anulado' });
  return enviar_(chat, `↩️ Anulado: ${textoMov_(mov, contextoBot_())}`, null, idMsg);
}

// ---------------------------------------------------------------------
// 5. Acceso a datos del bot (siempre a través de db_)
// ---------------------------------------------------------------------

function contextoBot_() {
  if (CTX_BOT_) return CTX_BOT_;
  const cache = CacheService.getScriptCache();
  const leer = (clave, fn) => {
    const c = cache.get(clave);
    if (c) return JSON.parse(c);
    const v = fn();
    try { cache.put(clave, JSON.stringify(v), BOT.CACHE_SEG); } catch (_) { /* > 100 KB: sin caché */ }
    return v;
  };
  CTX_BOT_ = {
    cuentas: leer('bot_cuentas', () => db_.leer('cuentas', 'select=id_cuenta,alias&activo=is.true')),
    categorias: leer('bot_categorias', () =>
      db_.leer('categorias', 'select=id_categoria,nombre,tipo,icono&activo=is.true&order=nombre.asc')),
    diccionario: leer('bot_diccionario', cargarDiccionario_),
  };
  return CTX_BOT_;
}

function idCuentaBot_(medio, ctx) {
  const alias = medio === 'yape' ? BOT.CUENTA_YAPE : BOT.CUENTA_EFECTIVO;
  const c = ctx.cuentas.find(x => x.alias === alias);
  if (!c) throw new Error(`No existe la cuenta activa "${alias}" (tabla cuentas).`);
  return c.id_cuenta;
}

/** Devuelve la fila insertada, o null si ya existía (UNIQUE id_cuenta + numero_operacion). */
function insertarMovBot_(d, original, contraparte, clave) {
  try {
    const [mov] = db_.insertar('movimientos', [{
      fecha: fechaDias_(d.dias),
      monto: d.monto,
      moneda: 'PEN',
      sentido: d.sentido,
      id_cuenta: d.id_cuenta,
      id_categoria: d.id_categoria || null,
      descripcion: String(original).slice(0, 200),
      contraparte: contraparte || null,
      numero_operacion: clave,
      origen: 'telegram',
    }]);
    return mov;
  } catch (e) {
    if (esDuplicado_(e)) return null;
    throw e;
  }
}

/** Solo se tocan movimientos del bot: desde Telegram no se editan los del banco. */
function actualizarMovBot_(id, cambios) {
  const [mov] = db_.actualizar('movimientos', `id_movimiento=eq.${Number(id)}&origen=eq.telegram`, cambios);
  return mov || null;
}

/**
 * Aprendizaje: upsert en `diccionario` (ON CONFLICT (palabra) DO UPDATE).
 * Si la palabra ya existía con otra categoría, gana la elección del usuario.
 */
function aprenderPalabra_(palabra, idCategoria, sentido, ctx) {
  const p = normalizar_(palabra);
  const cat = ctx.categorias.find(c => c.id_categoria === idCategoria);
  if (p.length < 3 || !cat || cat.tipo !== sentido) return null;
  db_.upsert('diccionario', [{ palabra: p, id_categoria: idCategoria, activo: true, origen: 'bot' }], 'palabra');
  CacheService.getScriptCache().remove('bot_diccionario');
  return p;
}

function buscarIngresoParecido_(idCuenta, monto, fechaIso) {
  const dia = diaLima_(fechaIso);
  const desde = encodeURIComponent(`${dia}T00:00:00-05:00`);    // Perú: UTC-5 todo el año
  const hasta = encodeURIComponent(`${dia}T23:59:59.999-05:00`);
  const [fila] = db_.leer('movimientos',
    `select=id_movimiento,contraparte&id_cuenta=eq.${idCuenta}&sentido=eq.ingreso&estado=eq.activo` +
    `&monto=eq.${monto}&fecha=gte.${desde}&fecha=lte.${hasta}&limit=1`);
  return fila || null;
}

// ---------------------------------------------------------------------
// 6. Presentación
// ---------------------------------------------------------------------

function proponer_(chat, idMsg, d, titulo, ctx, textoSi, textoNo) {
  const cuenta = ctx.cuentas.find(c => c.id_cuenta === d.id_cuenta);
  const html = `${titulo}\n\n${d.sentido === 'ingreso' ? '➕ Ingreso' : '➖ Gasto'} <b>S/ ${d.monto.toFixed(2)}</b>` +
    ` · ${escaparHtml_(nombreCat_(d.id_categoria, ctx))} · ${escaparHtml_(cuenta ? cuenta.alias : '?')}` +
    (d.dias ? ` · hace ${d.dias} día(s)` : '');
  const data = dataBoton_(['p', Math.round(d.monto * 100), d.id_categoria || 0, d.id_cuenta,
                           d.sentido === 'ingreso' ? 'i' : 'e', d.dias || 0], d.palabra);
  return enviar_(chat, html, [[
    { text: '✅ ' + (textoSi || 'Confirmar'), callback_data: data },
    { text: '❌ ' + (textoNo || 'Cancelar'), callback_data: 'x' },
  ]], idMsg);
}

function textoMov_(mov, ctx) {
  const cuenta = ctx.cuentas.find(c => c.id_cuenta === mov.id_cuenta);
  return `${mov.sentido === 'ingreso' ? '➕' : '✅'} S/ ${Number(mov.monto).toFixed(2)} · ` +
    `${escaparHtml_(nombreCat_(mov.id_categoria, ctx))} · ${escaparHtml_(cuenta ? cuenta.alias : '')}` +
    (mov.contraparte ? ` · ${escaparHtml_(mov.contraparte)}` : '') +
    (diaLima_(mov.fecha) !== diaLima_(new Date()) ? ` · ${diaLima_(mov.fecha)}` : '');
}

function nombreCat_(id, ctx) {
  const c = ctx.categorias.find(x => x.id_categoria === id);
  return c ? `${c.icono || ''} ${c.nombre}`.trim() : 'Sin categoría';
}

function tecladoMov_(mov) {
  return [[
    { text: '🏷️ Cambiar categoría', callback_data: `m|${mov.id_movimiento}` },
    { text: '↩️ Deshacer', callback_data: `u|${mov.id_movimiento}` },
  ]];
}

/** Categorías del mismo tipo (egreso/ingreso), 2 por fila. */
function tecladoCategorias_(idMov, tipo, palabra, ctx) {
  const botones = ctx.categorias.filter(c => c.tipo === tipo).map(c => ({
    text: `${c.icono || ''} ${c.nombre}`.trim(),
    callback_data: dataBoton_(['k', idMov, c.id_categoria], palabra),
  }));
  const filas = [];
  for (let i = 0; i < botones.length; i += 2) filas.push(botones.slice(i, i + 2));
  return filas;
}

function totales_(filas) {
  const suma = s => filas.filter(f => f.sentido === s && !f.es_transferencia).reduce((t, f) => t + Number(f.monto), 0);
  return `Gastos: <b>S/ ${suma('egreso').toFixed(2)}</b> · Ingresos: S/ ${suma('ingreso').toFixed(2)}`;
}

function porCategoria_(filas) {
  const t = {};
  filas.filter(f => f.sentido === 'egreso' && !f.es_transferencia)
    .forEach(f => { t[f.categoria] = (t[f.categoria] || 0) + Number(f.monto); });
  return Object.keys(t).sort((a, b) => t[b] - t[a])
    .map(c => `• ${escaparHtml_(c)}: S/ ${t[c].toFixed(2)}`).join('\n') || 'Sin gastos aún.';
}

// ---------------------------------------------------------------------
// Fechas (Lima)
// ---------------------------------------------------------------------

function fechaDias_(dias) {
  return new Date(Date.now() - (Number(dias) || 0) * 86400000).toISOString();
}

/** Lunes de la semana actual en Lima ('u' = día ISO: 1 lunes … 7 domingo). */
function lunesLima_() {
  const ahora = new Date();
  const u = Number(Utilities.formatDate(ahora, CONFIG.ZONA, 'u'));
  return diaLima_(new Date(ahora.getTime() - (u - 1) * 86400000));
}
