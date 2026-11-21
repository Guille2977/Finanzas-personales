/**
 * Migracion.gs — pasa la hoja "Movimientos bancarios" a Supabase.
 * Se ejecuta UNA vez, pero es idempotente: si la corres de nuevo, no duplica
 * (correos_raw.gmail_message_id y movimientos.id_correo son UNIQUE).
 *
 * Por qué crear también la fila en correos_raw: así el activador, al ver
 * esos mismos correos en Gmail, los reconoce como ya procesados y no los
 * vuelve a insertar. La hoja no guardó el cuerpo, por eso va vacío.
 *
 * Requiere la propiedad HOJA_ID (el ID está en la URL de la hoja:
 * docs.google.com/spreadsheets/d/<HOJA_ID>/edit).
 */

function migrarHoja() {
  const hoja = SpreadsheetApp.openById(propiedad_('HOJA_ID')).getSheetByName(CONFIG.PESTANA_MIGRACION);
  if (!hoja) throw new Error(`No existe la pestaña "${CONFIG.PESTANA_MIGRACION}"`);
  const filas = hoja.getDataRange().getValues();
  const col = {};
  filas.shift().forEach((nombre, i) => { col[String(nombre).trim()] = i; });

  const fuentes = cargarFuentes_();
  const bcpDebito = idCuenta_('BCP Débito');
  const remitenteBcp = 'notificaciones@notificacionesbcp.com.pe';
  const r = { insertados: 0, ya_existian: 0, omitidos: 0, errores: 0 };

  filas.forEach((f, i) => {
    const nFila = i + 2;
    try {
      if (!f[col.monto]) return;                                  // fila vacía
      const asunto = String(f[col.asunto] || '');
      const gmailId = String(f[col.id_correo] || '').trim();
      const fecha = fechaLimaAIso_(f[col.fecha]);
      const fuente = identificarFuente_(fuentes, remitenteBcp, asunto);
      if (fuente && fuente.accion === 'ignorar') { r.omitidos++; return; }

      let idCorreo = null;
      if (gmailId) {
        const [existe] = db_.leer('correos_raw', `select=id_correo&gmail_message_id=eq.${gmailId}`);
        idCorreo = existe ? existe.id_correo : db_.insertar('correos_raw', [{
          gmail_message_id: gmailId,
          remitente: '(migrado desde Google Sheets)',
          asunto: asunto,
          fecha_correo: fecha,
          id_fuente: fuente ? fuente.id_fuente : null,
          estado: 'procesado',
          procesado_en: new Date().toISOString(),
        }])[0].id_correo;
      }

      const monto = typeof f[col.monto] === 'number' ? f[col.monto] : aNumero_(String(f[col.monto]));
      const datos = { contraparte: String(f[col.contraparte] || ''), descripcion: String(f[col.tipo] || '') };
      db_.insertar('movimientos', [{
        fecha: fecha,
        monto: monto,
        moneda: String(f[col.moneda] || 'PEN'),
        sentido: (fuente && fuente.sentido_defecto) || String(f[col.sentido]).toLowerCase(),
        id_cuenta: (fuente && fuente.id_cuenta_defecto) || bcpDebito,
        id_categoria: clasificar_(datos, fuente),
        descripcion: datos.descripcion || null,
        contraparte: datos.contraparte || null,
        numero_operacion: String(f[col.operacion] || '').trim() || null,
        origen: idCorreo ? 'correo' : 'manual',
        id_correo: idCorreo,
      }]);
      r.insertados++;
    } catch (e) {
      if (esDuplicado_(e)) { r.ya_existian++; return; }
      r.errores++;
      console.error(`Fila ${nFila}: ${e.message}`);
    }
  });
  console.log(`Migración: ${JSON.stringify(r)}`);
}

function idCuenta_(alias) {
  const [c] = db_.leer('cuentas', `select=id_cuenta&alias=eq.${encodeURIComponent(alias)}`);
  if (!c) throw new Error(`No existe la cuenta "${alias}" (¿ejecutaste 02_datos_iniciales.sql?)`);
  return c.id_cuenta;
}

/**
 * La hoja guardó la fecha como texto "yyyy-MM-dd HH:mm:ss" en hora de Lima.
 * Perú es UTC-5 todo el año (sin horario de verano), así que basta con
 * agregar "-05:00" para que PostgreSQL sepa exactamente qué instante es.
 */
function fechaLimaAIso_(valor) {
  if (valor instanceof Date) return valor.toISOString();
  const m = String(valor).trim().match(/^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2})(:\d{2})?/);
  if (!m) throw new Error(`Fecha con formato inesperado: "${valor}"`);
  return `${m[1]}T${m[2]}${m[3] || ':00'}-05:00`;
}
