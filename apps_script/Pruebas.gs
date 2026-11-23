/**
 * Pruebas.gs — pruebas de la lógica pura (sin Gmail ni Supabase).
 * Ejecuta probarTodo() después de cualquier cambio en Extractores.gs.
 * Si el banco cambia el formato de un correo, aquí falla primero.
 *
 * Los textos son de ejemplo. Reemplázalos por correos REALES ANONIMIZADOS
 * (cambia nombres, últimos dígitos y números de operación).
 */

function probarTodo() {
  const casos = [
    ['aNumero 1.250,00', () => aNumero_('1.250,00'), 1250],
    ['aNumero 1,250.00', () => aNumero_('1,250.00'), 1250],
    ['aNumero 45,90', () => aNumero_('45,90'), 45.9],
    ['aNumero 1,250', () => aNumero_('1,250'), 1250],
    ['consumo: monto', () => extractorBase_(EJEMPLO_CONSUMO).monto, 25.5],
    ['consumo: moneda', () => extractorBase_(EJEMPLO_CONSUMO).moneda, 'PEN'],
    ['consumo: contraparte', () => extractorBase_(EJEMPLO_CONSUMO).contraparte, 'RAPPI PERU'],
    ['consumo: operación', () => extractorBase_(EJEMPLO_CONSUMO).numeroOperacion, '123456'],
    ['yape: sentido', () => extractorBase_(EJEMPLO_YAPE).sentido, 'ingreso'],
    ['yape: monto', () => extractorBase_(EJEMPLO_YAPE).monto, 10],
    ['sin monto → null', () => extractorBase_({ asunto: 'Hola', cuerpo: 'sin montos', fecha: '' }), null],
    ['validar monto 0', () => validarExtraccion_({ monto: 0, moneda: 'PEN' }) !== null, true],
    // La regla en sí (diccionario, normalizar) se prueba en sql/09_fn_clasificar.sql.
    // Aquí: qué se le envía a la base y qué pasa si falla (rpc simulado).
    ['clasificar: envía texto y fuente', () => {
      let enviado;
      clasificar_({ contraparte: 'RAPPI PERU', descripcion: 'Consumo' }, { id_fuente: 3 },
        (fn, args) => { enviado = [fn, args]; return 2; });
      return enviado;
    }, ['fn_clasificar', { p_texto: 'RAPPI PERU Consumo', p_id_fuente: 3 }]],
    ['clasificar: si la base falla, manda la fuente', () =>
      clasificar_({ contraparte: 'RAPPI' }, { id_fuente: 3, id_categoria_defecto: 11 }, RPC_CAIDO), 11],
    ['clasificar: si la base falla → Sin categoría', () =>
      clasificar_({ contraparte: 'RAPPI' }, null, RPC_CAIDO), null],
    ['fecha Lima → ISO', () => fechaLimaAIso_('2026-11-07 21:15:00'), '2026-11-07T21:15:00-05:00'],
    ['fuente: ignora rechazos primero', () => identificarFuente_(FUENTES_PRUEBA,
      'BCP <notificaciones@notificacionesbcp.com.pe>', 'Tu consumo fue rechazado').nombre, 'rechazo'],
    ['fuente: consumo', () => identificarFuente_(FUENTES_PRUEBA,
      'BCP <notificaciones@notificacionesbcp.com.pe>', 'Realizaste un consumo con tu Tarjeta de Débito BCP').nombre, 'consumo'],
    ['CIP: tienda', () => extractorPagoEfectivo_(EJEMPLO_CIP).contraparte, 'Betsson'],
    ['CIP: código', () => extractorPagoEfectivo_(EJEMPLO_CIP).numeroOperacion, 'CIP-12345678'],
    ['CIP: monto', () => extractorPagoEfectivo_(EJEMPLO_CIP).monto, 120],
    ['fuente: desconocida → null', () => identificarFuente_(FUENTES_PRUEBA, 'otro@x.com', 'Hola'), null],
    // Alertas.gs: qué decide avisar lo prueba sql/11; aquí, el envío y la cola (sin red).
    ['alerta: envía a la URL y chat correctos', () => {
      let url, cuerpo;
      enviarTelegram_('hola', { token: 'T0K', chat: '99', fetch: (u, p) => { url = u; cuerpo = JSON.parse(p.payload); return RESPUESTA_TG(200, '{"ok":true}'); } });
      return [url, cuerpo.chat_id, cuerpo.text];
    }, ['https://api.telegram.org/botT0K/sendMessage', '99', 'hola']],
    ['alerta: Telegram 403 → error con el motivo', () => {
      try { enviarTelegram_('x', { token: 'T0K', chat: '99', fetch: () => RESPUESTA_TG(403, '{"description":"Forbidden: bot was blocked by the user"}') }); }
      catch (e) { return e.message; }
    }, 'Telegram 403: Forbidden: bot was blocked by the user'],
    ['alerta: el token nunca queda en el error', () => {
      try { enviarTelegram_('x', { token: 'T0K', chat: '99', fetch: () => { throw new Error('Address unavailable: https://api.telegram.org/botT0K/sendMessage'); } }); }
      catch (e) { return e.message.includes('T0K'); }
    }, false],
    ['alerta: envía y marca todas', () => {
      const marcas = [];
      const r = enviarPendientes_([{ id: 1, mensaje: 'a', intentos: 0 }, { id: 2, mensaje: 'b', intentos: 2 }],
        () => {}, (id, c) => marcas.push([id, !!c.enviada_en, c.intentos]));
      return [r.enviadas, r.fallidas, marcas];
    }, [2, 0, [[1, true, 1], [2, true, 3]]]],
    ['alerta: si falla, suma intento y se detiene', () => {
      const marcas = [];
      const r = enviarPendientes_([{ id: 1, mensaje: 'a', intentos: 0 }, { id: 2, mensaje: 'b', intentos: 0 }],
        () => { throw new Error('Telegram 502: Bad Gateway'); }, (id, c) => marcas.push([id, !!c.enviada_en, c.intentos, c.ultimo_error]));
      return [r.enviadas, r.fallidas, marcas];
    }, [0, 1, [[1, false, 1, 'Telegram 502: Bad Gateway']]]],
    ['alerta: la primera sale aunque falle la segunda', () => {
      const marcas = [];
      enviarPendientes_([{ id: 1, mensaje: 'a', intentos: 0 }, { id: 2, mensaje: 'b', intentos: 0 }],
        (t) => { if (t === 'b') throw new Error('Telegram 429: Too Many Requests'); }, (id, c) => marcas.push([id, !!c.enviada_en]));
      return marcas;
    }, [[1, true], [2, false]]],
  ];

  casos.push(...casosIA_());   // IA para correos desconocidos (PruebasIA.gs)
  casos.push(...casosResumen_());   // conciliación y resumen mensual (PruebasResumen.gs)

  let fallos = 0;
  casos.forEach(([nombre, fn, esperado]) => {
    let obtenido;
    try { obtenido = fn(); } catch (e) { obtenido = 'ERROR: ' + e.message; }
    const ok = JSON.stringify(obtenido) === JSON.stringify(esperado);
    if (!ok) fallos++;
    console.log(`${ok ? '✅' : '❌'} ${nombre}${ok ? '' : ` → esperado ${JSON.stringify(esperado)}, obtenido ${JSON.stringify(obtenido)}`}`);
  });
  console.log(`${casos.length - fallos}/${casos.length} pruebas OK`);
  if (fallos) throw new Error(`${fallos} prueba(s) fallaron`);
}

const EJEMPLO_CONSUMO = {
  fecha: '2026-11-07T15:00:00.000Z',
  asunto: 'Realizaste un consumo con tu Tarjeta de Débito BCP',
  cuerpo: 'Hola, realizaste un consumo de S/ 25.50 en RAPPI PERU. Número de operación: 123456',
};
const EJEMPLO_YAPE = {
  fecha: '2026-11-07T15:00:00.000Z',
  asunto: 'Constancia de recepción de Yapeo a celular',
  cuerpo: 'Te yapearon S/ 10.00. Ordenante: Juan P.',
};
const EJEMPLO_CIP = {
  fecha: '2026-11-08T15:00:00.000Z',
  asunto: 'Tu código CIP ha sido pagado.',
  cuerpo: '¡Pago realizado con éxito! Empresa: PagoEfectivo\n\nServicio: PagoEfectivo Soles\n\n' +
          'Código de pago 12345678 Monto a pagar S/. 120.00\n\n¡Hola! Gracias por realizar el pago, ' +
          'ahora procederemos a informar a Betsson QR para continuar con los siguientes pasos de tu orden.',
};
const RESPUESTA_TG = (codigo, texto) => ({ getResponseCode: () => codigo, getContentText: () => texto });
const RPC_CAIDO = () => { throw new Error('Supabase 404: fn_clasificar no existe'); };
const FUENTES_PRUEBA = [
  { nombre: 'rechazo', reRemitente: /notificacionesbcp\.com\.pe/i, reAsunto: /rechaz/i },
  { nombre: 'consumo', reRemitente: /notificacionesbcp\.com\.pe/i, reAsunto: /^Realizaste un consumo con tu Tarjeta de D[eé]bito/i },
];

// Las pruebas del bot están en supabase/functions/telegram-webhook/logica_test.ts
