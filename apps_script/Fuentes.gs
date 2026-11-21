/**
 * Fuentes.gs — decide qué es cada correo usando la tabla `fuentes`.
 *
 * Configuración en lugar de código: para agregar un banco o ignorar un
 * tipo de correo se inserta una fila en `fuentes` (desde Retool o SQL);
 * este archivo no cambia.
 */

/** Carga las fuentes activas una vez por corrida (no una vez por correo). */
function cargarFuentes_() {
  const filas = db_.leer('fuentes', 'select=*&activo=is.true&order=prioridad.asc,id_fuente.asc');
  return filas.map(f => {
    try {
      return Object.assign({}, f, {
        reRemitente: new RegExp(f.remitente_patron, 'i'),
        reAsunto: f.asunto_patron ? new RegExp(f.asunto_patron, 'i') : null,
      });
    } catch (e) {
      // Un patrón mal escrito en la tabla no debe tumbar toda la captura.
      console.warn(`Fuente "${f.nombre}" tiene una regex inválida: ${e.message}`);
      return null;
    }
  }).filter(Boolean);
}

/** Primera fuente (por prioridad) cuyo remitente y asunto coinciden, o null. */
function identificarFuente_(fuentes, remitente, asunto) {
  return fuentes.find(f => f.reRemitente.test(remitente) && (!f.reAsunto || f.reAsunto.test(asunto))) || null;
}
