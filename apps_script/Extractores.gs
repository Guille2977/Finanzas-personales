/**
 * Extractores.gs — convierte un correo en datos de movimiento.
 *
 * Interfaz común: extractor(correo) → { fecha, monto, moneda, sentido,
 *   contraparte, numeroOperacion, descripcion, tipo }  o  null si no pudo.
 * Agregar un formato = agregar una función y su nombre en EXTRACTORES;
 * la tabla `fuentes` dice qué extractor usa cada remitente/asunto.
 *
 * Las regex y aNumero_ son las de tu Código.gs (ya probadas con tus
 * correos). Por ahora todos los extractores usan esa misma base; cuando
 * tengamos ejemplos reales de PagoEfectivo y Betsafe se especializan.
 */

const PATRON_MONTO = /(S\/\.?|US\$|USD|PEN|\$)\s*(\d[\d.,]*\d|\d)/;
const MONEDAS = { 'S/': 'PEN', 'S/.': 'PEN', 'PEN': 'PEN', 'US$': 'USD', 'USD': 'USD', '$': 'USD' };
const TIPOS = [
  ['Devolución', /devoluci[oó]n|extorno/i],
  ['Retiro', /retiro|disposici[oó]n de efectivo/i],
  ['Depósito', /dep[oó]sito|abono|recibiste|te yapearon|transferencia recibida|recepci[oó]n de yapeo/i],
  ['Transferencia enviada', /transferencia|yapeaste|enviaste/i],
  ['Pago de servicio', /pago de servicio|pago de recibo|cip/i],
  ['Consumo', /consumo|compra|cargo|pagaste|pago con tu tarjeta/i],
];
const NO_MOVIMIENTO = /rechaz|no se pudo|fondos insuficientes|pronto|recordatorio|programad/i;
const INGRESOS = ['Devolución', 'Depósito'];
const PATRON_ETIQUETA = /(?:comercio|establecimiento|empresa|beneficiario|destinatario|ordenante|origen)\s*:\s*([^\n.]+)/i;
const PATRON_MAYUSCULAS = /(?:^|\s)(?:[Ee]n|[Dd]e|a)\s+([A-Z][A-Z0-9&'*-]{2,}(?=[\s.,;]|$)(?:\s+[A-Z0-9&'*-]+(?=[\s.,;]|$))*)/;
const PATRON_OPERACION = /(?:n[uú]mero de operaci[oó]n|nro\.? de operaci[oó]n|c[oó]digo de operaci[oó]n)\s*:?\s*(\d{4,})/i;

/** "1.250,00" / "1,250.00" / "45,90" / "3" → número. (Tu función original.) */
function aNumero_(texto) {
  if (texto.includes(',') && texto.includes('.')) {
    texto = texto.lastIndexOf(',') > texto.lastIndexOf('.')
      ? texto.replace(/\./g, '').replace(',', '.')
      : texto.replace(/,/g, '');
  } else if (texto.includes(',')) {
    const decimales = texto.split(',').pop();
    texto = (texto.split(',').length === 2 && decimales.length === 2)
      ? texto.replace(',', '.')
      : texto.replace(/,/g, '');
  }
  return parseFloat(texto);
}

function detectarTipo_(asunto, cuerpo) {
  for (const texto of [asunto, cuerpo]) {
    for (const [tipo, patron] of TIPOS) if (patron.test(texto)) return tipo;
  }
  return 'Otro';
}

function detectarContraparte_(cuerpo) {
  const m = cuerpo.match(PATRON_ETIQUETA) || cuerpo.match(PATRON_MAYUSCULAS);
  return m ? m[1].trim().replace(/^[ .,;]+|[ .,;]+$/g, '').slice(0, 60) : '';
}

/** Base común (tu función extraer, adaptada a la interfaz estándar). */
// Montos con la moneda DESPUÉS del número ("120.00 PEN", "50 soles").
const PATRON_MONTO_SUFIJO = /(\d[\d.,]*\d|\d)\s*(PEN|USD|soles)\b/i;

function extractorBase_(correo) {
  let monto = correo.cuerpo.match(PATRON_MONTO) || correo.asunto.match(PATRON_MONTO);
  if (!monto) {
    const s = correo.cuerpo.match(PATRON_MONTO_SUFIJO);
    if (s) monto = [s[0], /usd/i.test(s[2]) ? 'USD' : 'PEN', s[1]];
  }
  if (!monto) return null;
  const tipo = detectarTipo_(correo.asunto, correo.cuerpo);
  const operacion = correo.cuerpo.match(PATRON_OPERACION);
  return {
    fecha: correo.fecha,
    monto: aNumero_(monto[2]),
    moneda: MONEDAS[monto[1]],
    sentido: INGRESOS.includes(tipo) ? 'ingreso' : 'egreso',
    contraparte: detectarContraparte_(correo.cuerpo),
    numeroOperacion: operacion ? operacion[1] : null,
    descripcion: tipo === 'Otro' ? correo.asunto.slice(0, 120) : tipo,
    tipo: tipo,
  };
}

/**
 * PagoEfectivo: el correo dice "Empresa: PagoEfectivo" (el intermediario),
 * pero la tienda real aparece en "procederemos a informar a <TIENDA> para
 * continuar". Se usa:
 *   · contraparte = la tienda (Betsson, PagSeguro…), para clasificar con el diccionario.
 *   · numeroOperacion = "CIP-<código de pago>": si llegan dos correos del
 *     MISMO pago, el UNIQUE (cuenta, numero_operacion) evita contarlo dos veces.
 */
function extractorPagoEfectivo_(correo) {
  const d = extractorBase_(correo);
  if (!d) return null;
  const texto = correo.cuerpo + ' ' + correo.asunto;
  const cip = texto.match(/(?:c[oó]digo de pago|CIP)\D{0,25}(\d{6,})/i);
  if (cip) d.numeroOperacion = 'CIP-' + cip[1];
  const tienda = correo.cuerpo.match(/informar a\s+(.+?)\s+para continuar/i);
  d.contraparte = tienda ? tienda[1].replace(/\s+QR$/i, '').trim().slice(0, 60) : '';
  d.descripcion = 'Pago con código CIP';
  return d;
}

// Nombre en la tabla `fuentes`.extractor → función.
const EXTRACTORES = {
  bcp_consumo_debito: extractorBase_,
  bcp_yape_recibido: extractorBase_,
  bcp_transferencia_terceros: extractorBase_,
  bcp_pago_servicio: extractorBase_,
  bcp_devolucion: extractorBase_,
  bcp_retiro_agente: extractorBase_,
  pagoefectivo_cip_pagado: extractorPagoEfectivo_,
  betsafe_retiro_aprobado: extractorBase_,
  generico: extractorBase_,
};

/** Valida lo extraído antes de tocar la base. Devuelve el motivo si falla, o null. */
function validarExtraccion_(d) {
  if (!d) return 'No se encontró un monto en el correo';
  if (!(d.monto > 0) || !isFinite(d.monto)) return `Monto inválido: ${d.monto}`;
  if (!['PEN', 'USD'].includes(d.moneda)) return `Moneda desconocida: ${d.moneda}`;
  return null;
}
