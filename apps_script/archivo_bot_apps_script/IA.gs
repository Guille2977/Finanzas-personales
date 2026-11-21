/**
 * IA.gs — respaldo con Gemini API. Solo actúa cuando las REGLAS no alcanzan.
 *
 * Principios (sección 8.1 del documento):
 *   · Nunca registra sola: propone y el usuario confirma con un botón.
 *   · Degradación controlada: sin clave, sin cuota o sin respuesta → devuelve
 *     null y el bot sigue con sus botones normales. Nunca lanza.
 *   · Anonimiza antes de enviar (en el plan gratuito Google puede usar los datos).
 *   · Salida estructurada (JSON con esquema y lista cerrada de categorías) y
 *     VALIDADA aquí: si no pasa, se trata como "no entendido".
 *   · Se cuenta cada llamada y cada fallo → ejecuciones.llamadas_ia.
 *
 * Propiedades: GEMINI_KEY (Google AI Studio → Get API key).
 *              GEMINI_MODELO opcional (por defecto el alias del Flash más reciente).
 */

const IA = {
  URL: 'https://generativelanguage.googleapis.com/v1beta/models/',
  // Flash-Lite: el más rápido (sin "razonamiento"); basta para elegir una categoría.
  MODELO_DEFECTO: 'gemini-flash-lite-latest',
  MAX_CARACTERES: 300,
};
const IA_USO = { llamadas: 0, fallos: 0 };   // se reinicia en cada ejecución

function iaActiva_() { return Boolean(propiedad_('GEMINI_KEY', true)); }

/**
 * Sugiere una categoría (de la lista) para un concepto que el diccionario no conoce.
 * Devuelve { id_categoria, nombre, icono, palabra } o null.
 */
function iaSugerirCategoria_(concepto, categorias) {
  if (!categorias.length) return null;
  const nombres = categorias.map(c => c.nombre);
  const r = llamarGemini_(
    'Clasifica un gasto/ingreso personal de un estudiante en Perú.\n' +
    `Texto: "${anonimizar_(concepto)}"\n` +
    `Elige UNA categoría de esta lista: ${nombres.join(', ')}. Si ninguna encaja con claridad, responde "ninguna".\n` +
    'palabra_clave: la palabra del texto que mejor identifica el gasto, copiada tal cual.',
    {
      type: 'OBJECT',
      properties: {
        categoria: { type: 'STRING', enum: nombres.concat('ninguna') },
        palabra_clave: { type: 'STRING' },
      },
      required: ['categoria', 'palabra_clave'],
    });
  return validarSugerencia_(r, concepto, categorias);
}

/**
 * Interpreta un mensaje que las reglas no entendieron ("me compré unas
 * galletas por cuatro cincuenta"). Devuelve
 * { monto, sentido, medio, id_categoria, dias, palabra } o null.
 */
function iaInterpretar_(texto, categorias, montoMax, maxDias) {
  const nombres = categorias.filter(c => c.tipo !== 'transferencia').map(c => c.nombre);
  const r = llamarGemini_(
    'Eres el asistente de finanzas personales de un estudiante en Perú (moneda: soles).\n' +
    `Mensaje: "${anonimizar_(texto)}"\n` +
    'Extrae UN movimiento. entendido=false si no hay un monto claro.\n' +
    '- sentido: "ingreso" si recibió dinero, si no "egreso".\n' +
    '- medio: "yape" si menciona Yape, si no "efectivo".\n' +
    `- categoria: una de [${nombres.join(', ')}] o "ninguna".\n` +
    '- dias_atras: 0 hoy, 1 ayer, etc.\n' +
    '- palabra_clave: la palabra del mensaje que identifica el gasto, copiada tal cual.',
    {
      type: 'OBJECT',
      properties: {
        entendido: { type: 'BOOLEAN' },
        monto: { type: 'NUMBER' },
        sentido: { type: 'STRING', enum: ['egreso', 'ingreso'] },
        medio: { type: 'STRING', enum: ['efectivo', 'yape'] },
        categoria: { type: 'STRING', enum: nombres.concat('ninguna') },
        dias_atras: { type: 'INTEGER' },
        palabra_clave: { type: 'STRING' },
      },
      required: ['entendido', 'monto', 'sentido', 'medio', 'categoria', 'dias_atras', 'palabra_clave'],
    });
  return validarInterpretacion_(r, texto, categorias, montoMax, maxDias);
}

// ---------------------------------------------------------------------
// Validación (PURA → se prueba en Pruebas.gs)
// ---------------------------------------------------------------------

function validarSugerencia_(r, concepto, categorias) {
  if (!r || typeof r.categoria !== 'string') return null;
  const cat = categorias.find(c => c.nombre === r.categoria);
  if (!cat) return null;                                   // "ninguna" o inventada
  return { id_categoria: cat.id_categoria, nombre: cat.nombre, icono: cat.icono,
           palabra: palabraDelTexto_(r.palabra_clave, concepto) };
}

function validarInterpretacion_(r, texto, categorias, montoMax, maxDias) {
  if (!r || r.entendido !== true) return null;
  const monto = Math.round(Number(r.monto) * 100) / 100;
  if (!(monto > 0) || monto > montoMax) return null;
  if (!['egreso', 'ingreso'].includes(r.sentido) || !['efectivo', 'yape'].includes(r.medio)) return null;
  const dias = Number(r.dias_atras);
  if (!Number.isInteger(dias) || dias < 0 || dias > maxDias) return null;
  const cat = categorias.find(c => c.nombre === r.categoria && c.tipo === r.sentido);   // tipo coherente
  return {
    monto, sentido: r.sentido, medio: r.medio, dias,
    id_categoria: cat ? cat.id_categoria : null,
    palabra: palabraDelTexto_(r.palabra_clave, texto),
  };
}

/** La palabra aprendida debe EXISTIR en el texto del usuario (la IA no inventa vocabulario). */
function palabraDelTexto_(palabra, texto) {
  const p = normalizar_(palabra);
  return p.length >= 3 && !p.includes(' ') && ` ${normalizar_(texto)} `.includes(` ${p} `) ? p : '';
}

/** Enmascara correos y números largos (celular, cuenta, operación) y recorta. */
function anonimizar_(texto) {
  return String(texto || '')
    .replace(/[\w.+-]+@[\w-]+\.[\w.]+/g, '[correo]')
    .replace(/\d[\d -]{5,}\d/g, '[número]')
    .slice(0, IA.MAX_CARACTERES);
}

// ---------------------------------------------------------------------
// Llamada HTTP
// ---------------------------------------------------------------------

/**
 * POST .../models/<modelo>:generateContent con salida JSON y esquema.
 * La clave va en la cabecera x-goog-api-key (no en la URL, así no aparece
 * en logs). temperature 0 = respuestas estables. Sin reintentos: el usuario
 * está esperando en Telegram; si falla, se usan los botones.
 */
function llamarGemini_(prompt, esquema) {
  const clave = propiedad_('GEMINI_KEY', true);
  if (!clave) return null;                                 // IA apagada: el bot funciona igual
  IA_USO.llamadas++;
  const t0 = Date.now();
  try {
    const modelo = propiedad_('GEMINI_MODELO', true) || IA.MODELO_DEFECTO;
    const r = UrlFetchApp.fetch(`${IA.URL}${modelo}:generateContent`, {
      method: 'post',
      contentType: 'application/json',
      headers: { 'x-goog-api-key': clave },
      muteHttpExceptions: true,
      payload: JSON.stringify({
        contents: [{ role: 'user', parts: [{ text: prompt }] }],
        generationConfig: { temperature: 0, responseMimeType: 'application/json', responseSchema: esquema },
      }),
    });
    const j = JSON.parse(r.getContentText() || '{}');
    if (r.getResponseCode() !== 200) throw new Error(`HTTP ${r.getResponseCode()}: ${(j.error && j.error.message) || ''}`.slice(0, 200));
    const partes = (((j.candidates || [])[0] || {}).content || {}).parts || [];
    console.log(`IA respondió en ${Date.now() - t0} ms`);
    return JSON.parse(partes.map(p => p.text || '').join(''));
  } catch (e) {
    IA_USO.fallos++;
    console.warn('IA (Gemini) no disponible: ' + e.message);
    return null;
  }
}
