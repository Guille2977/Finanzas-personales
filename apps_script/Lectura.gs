/**
 * Lectura.gs — busca y lee correos en Gmail. Permiso SOLO DE LECTURA
 * (gmail.readonly): el sistema nunca borra, mueve ni modifica correos.
 *
 * Por qué no etiquetas (por ahora): mover etiquetas exige el permiso
 * gmail.modify. La tabla correos_raw ya guarda qué correo se procesó
 * (gmail_message_id UNIQUE), así que la base hace de "cola": si Supabase
 * falla, el correo no queda registrado y se reintenta en la siguiente
 * corrida. Mínimo privilegio + misma garantía.
 *
 * buscarIds_, partes_, decodificar_ y htmlATexto_ vienen de tu Código.gs.
 */

function buscarIds_(consulta, maximo) {
  const ids = [];
  let pagina;
  do {
    const r = Gmail.Users.Messages.list('me', { q: consulta, maxResults: 100, pageToken: pagina });
    (r.messages || []).forEach(m => ids.push(m.id));
    pagina = r.nextPageToken;
  } while (pagina && ids.length < maximo);
  return ids.slice(0, maximo);
}

/**
 * Gmail limita cuántas lecturas por minuto hace un usuario. Pausa breve
 * entre lecturas y, si igual responde "Quota exceeded" / "Rate Limit",
 * el error se marca como TRANSITORIO: el lote se detiene y se reintenta
 * luego, en vez de contar el correo como error.
 */
function leerCorreo_(id) {
  Utilities.sleep(250);
  let m;
  try {
    m = Gmail.Users.Messages.get('me', id, { format: 'full' });
  } catch (e) {
    if (/quota|rate limit|too many/i.test(e.message)) e.transitorio = true;
    throw e;
  }
  const cab = {};
  (m.payload.headers || []).forEach(c => { cab[c.name.toLowerCase()] = c.value; });
  const textos = partes_(m.payload, 'text/plain');
  const cuerpo = textos.length ? textos.join('\n') : htmlATexto_(partes_(m.payload, 'text/html').join('\n'));
  return {
    id: id,
    // toISOString() da la hora en UTC con "Z": PostgreSQL (TIMESTAMPTZ) la
    // guarda sin ambigüedad. Antes se guardaba texto en hora local.
    fecha: new Date(Number(m.internalDate)).toISOString(),
    remitente: cab.from || '',
    asunto: cab.subject || '',
    cuerpo: cuerpo,
  };
}

function decodificar_(data) {
  let bytes;
  if (Array.isArray(data)) {
    bytes = data;  // el servicio avanzado de Gmail ya entrega bytes
  } else {
    const texto = String(data).replace(/-/g, '+').replace(/_/g, '/');
    bytes = Utilities.base64Decode(texto + '='.repeat((4 - texto.length % 4) % 4));
  }
  return Utilities.newBlob(bytes).getDataAsString('UTF-8');
}

function partes_(parte, tipo) {
  if (parte.mimeType === tipo && parte.body && parte.body.data) return [decodificar_(parte.body.data)];
  return (parte.parts || []).reduce((acc, sub) => acc.concat(partes_(sub, tipo)), []);
}

function htmlATexto_(contenido) {
  return contenido
    .replace(/<(script|style)[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<br\s*\/?>|<\/p>|<\/tr>|<\/div>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)))
    .replace(/[ \t ]+/g, ' ')
    .trim();
}
