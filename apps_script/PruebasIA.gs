/**
 * PruebasIA.gs — pruebas de IA.gs SIN llamar a Gemini ni a Supabase.
 * Se ejecutan dentro de probarTodo() (Pruebas.gs).
 *
 * Truco: completarConIA_ y llamarGemini_ reciben sus dependencias
 * (clave, fetch, categorías). Aquí se les pasa un "fetch" falso que
 * devuelve la respuesta que queremos probar: 200, 429, red caída, JSON roto…
 */

function casosIA_() {
  const DEPS = (fetch) => ({ clave: 'CLAVE_FALSA', modelo: 'modelo-x', fetch: fetch, categorias: CATEGORIAS_IA });
  const conIA = (respuesta, ctx) => completarConIA_(CORREO_RARO, decidirRaro_(), ctx || {}, DEPS(() => respuesta));

  return [
    // --- Cuándo se llama ---
    ['IA: correo desconocido sin monto → sí', () => necesitaIA_(decidirRaro_()), true],
    ['IA: fuente conocida y datos válidos → no', () =>
      necesitaIA_({ estado: 'por_revisar', fuente: { nombre: 'x' }, datos: { monto: 5, moneda: 'PEN', tipo: 'Otro' } }), false],
    ['IA: genérico con tipo y contraparte claros → no', () =>
      necesitaIA_({ estado: 'por_revisar', fuente: null, datos: { monto: 5, moneda: 'PEN', tipo: 'Consumo', contraparte: 'RAPPI' } }), false],
    ['IA: procesado o ignorado → nunca', () => [necesitaIA_({ estado: 'procesado' }), necesitaIA_({ estado: 'ignorado' })], [false, false]],
    ['IA: sin clave → no llama y no cambia nada', () => {
      let llamadas = 0;
      const d = decidirRaro_();
      const r = completarConIA_(CORREO_RARO, d, {}, { clave: '', fetch: () => { llamadas++; } , categorias: CATEGORIAS_IA });
      return [llamadas, r === d];
    }, [0, true]],

    // --- Respuesta buena ---
    ['IA: respuesta válida → datos sugeridos para Retool', () => {
      const r = conIA(RESP_GEMINI(200, SUGERENCIA_OK));
      return [r.estado, r.sugeridoPorIA, r.datos.monto, r.datos.moneda, r.datos.sentido, r.datos.contraparte, r.datos.categoria, r.datos.origen];
    }, ['por_revisar', true, 89.9, 'PEN', 'egreso', 'Tienda Ficticia', 'Compras online', 'ia']],
    ['IA: el motivo lleva la etiqueta', () => /🤖 sugerido por IA$/.test(conIA(RESP_GEMINI(200, SUGERENCIA_OK)).detalle), true],
    ['IA: nunca registra sola (sin movimiento)', () => conIA(RESP_GEMINI(200, SUGERENCIA_OK)).movimiento, undefined],

    // --- La IA no puede inventar ---
    ['IA: monto que no está en el correo → descartada', () => {
      const r = conIA(RESP_GEMINI(200, Object.assign({}, SUGERENCIA_OK, { monto: 999 })));
      return [r.sugeridoPorIA, /el monto 999 no aparece/.test(r.detalle)];
    }, [undefined, true]],
    ['IA: categoría inventada → sin categoría', () =>
      conIA(RESP_GEMINI(200, Object.assign({}, SUGERENCIA_OK, { categoria: 'Lujos' }))).datos.categoria, undefined],
    ['IA: categoría de ingreso en un egreso → sin categoría', () =>
      conIA(RESP_GEMINI(200, Object.assign({}, SUGERENCIA_OK, { categoria: 'Sueldo' }))).datos.categoria, undefined],
    ['IA: contraparte que no está en el correo → vacía', () =>
      conIA(RESP_GEMINI(200, Object.assign({}, SUGERENCIA_OK, { contraparte: 'Amazon' }))).datos.contraparte, ''],
    ['IA: "no es movimiento" → por revisar sin sugerencia', () => {
      const r = conIA(RESP_GEMINI(200, Object.assign({}, SUGERENCIA_OK, { es_movimiento: false })));
      return [r.estado, r.sugeridoPorIA, /no parece un movimiento/.test(r.detalle)];
    }, ['por_revisar', undefined, true]],

    // --- Tolerancia a fallos ---
    ['IA: JSON roto → por revisar sin sugerencia', () => {
      const r = conIA({ getResponseCode: () => 200, getContentText: () => '{"candidates":[{"content":{"parts":[{"text":"no json"}]}}]}' });
      return [r.estado, r.sugeridoPorIA, /sin sugerencia/.test(r.detalle)];
    }, ['por_revisar', undefined, true]],
    ['IA: 429 → "no disponible" y deja de llamar en la corrida', () => {
      const ctx = {};
      let llamadas = 0;
      const fetch = () => { llamadas++; return RESP_GEMINI(429, null); };
      const r1 = completarConIA_(CORREO_RARO, decidirRaro_(), ctx, DEPS(fetch));
      const r2 = completarConIA_(CORREO_RARO, decidirRaro_(), ctx, DEPS(fetch));
      return [llamadas, /IA: no disponible \(HTTP 429/.test(r1.detalle), /cuota agotada/.test(r2.detalle), ctx.ia.fallos];
    }, [1, true, true, 1]],
    ['IA: red caída 2 veces → cortacircuitos', () => {
      const ctx = {};
      let llamadas = 0;
      const fetch = () => { llamadas++; throw new Error('Timeout'); };
      for (let i = 0; i < 4; i++) completarConIA_(CORREO_RARO, decidirRaro_(), ctx, DEPS(fetch));
      return [llamadas, ctx.ia.cortada];
    }, [2, '2 fallos seguidos']],
    ['IA: límite por corrida', () => {
      const ctx = { ia: { llamadas: IA.MAX_POR_CORRIDA, fallos: 0, seguidos: 0, cortada: null } };
      return /límite por corrida/.test(conIA(RESP_GEMINI(200, SUGERENCIA_OK), ctx).detalle);
    }, true],
    ['IA: la clave no está en la URL ni en el error', () => {
      let url, cab, msg;
      try { llamarGemini_('p', {}, { clave: 'CLAVE_FALSA', modelo: 'm', fetch: (u, p) => { url = u; cab = p.headers; throw new Error('fallo en ' + u + '?key=CLAVE_FALSA'); } }); }
      catch (e) { msg = e.message; }
      return [url.includes('CLAVE_FALSA'), cab['x-goog-api-key'], msg.includes('CLAVE_FALSA')];
    }, [false, 'CLAVE_FALSA', false]],

    // --- Privacidad ---
    ['IA: anonimiza correo, tarjeta y números largos; conserva el monto', () => {
      const t = anonimizarCorreo_({ asunto: 'Compra', cuerpo: 'Hola ana.p@mail.com, tarjeta ****4321, cel 987 654 321, total S/ 89.90' });
      return [t.includes('ana.p@'), t.includes('4321'), t.includes('987'), t.includes('89.90')];
    }, [false, false, false, true]],
    ['IA: monto en texto con formato peruano', () =>
      [montoEnTexto_(1250, 'Total: S/ 1.250,00'), montoEnTexto_(1250, 'Total 125,00')], [true, false]],
  ];
}

// Correo de un remitente conocido pero con un formato que las reglas no conocen.
const CORREO_RARO = {
  id: 'abc',
  fecha: '2026-11-20T15:00:00.000Z',
  remitente: 'Tienda <ventas@tienda-ficticia.example>',
  asunto: 'Gracias por tu pedido',
  cuerpo: 'Tu pedido en Tienda Ficticia fue confirmado. Importe cobrado: 89,90 soles. Pedido 12345678.',
};
// Lo que decidir_ devuelve para ese correo cuando ninguna fuente coincide.
const decidirRaro_ = () => ({ fuente: null, estado: 'por_revisar', detalle: 'Fuente desconocida (extractor genérico)', datos: extractorBase_(CORREO_RARO) });
const CATEGORIAS_IA = [
  { nombre: 'Comida', tipo: 'egreso' },
  { nombre: 'Compras online', tipo: 'egreso' },
  { nombre: 'Sueldo', tipo: 'ingreso' },
];
const SUGERENCIA_OK = {
  es_movimiento: true, monto: 89.9, moneda: 'PEN', sentido: 'egreso',
  contraparte: 'Tienda Ficticia', descripcion: 'Compra en tienda online', categoria: 'Compras online',
};
/** Imita la respuesta de UrlFetchApp para generateContent. */
const RESP_GEMINI = (codigo, objeto) => ({
  getResponseCode: () => codigo,
  getContentText: () => codigo === 200
    ? JSON.stringify({ candidates: [{ content: { parts: [{ text: JSON.stringify(objeto) }] } }] })
    : JSON.stringify({ error: { status: codigo === 429 ? 'RESOURCE_EXHAUSTED' : 'UNAVAILABLE' } }),
});
