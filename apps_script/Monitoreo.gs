/**
 * Monitoreo.gs — cada corrida deja una fila en `ejecuciones`
 * (leídos, insertados, por revisar, errores). La vista v_salud_sistema
 * y el panel de Retool se alimentan de aquí.
 *
 * La captura cada 15 min ya "toca" la base, así que también sirve de
 * latido: Supabase no pausa el proyecto por inactividad.
 */

function iniciarEjecucion_(proceso) {
  const [fila] = db_.insertar('ejecuciones', [{ proceso: proceso }]);
  return fila.id;
}

/** Nunca lanza: si falla el registro, no debe ocultar el resultado real. */
function finalizarEjecucion_(id, contadores, mensajes) {
  if (!id) return;
  try {
    db_.actualizar('ejecuciones', `id=eq.${id}`, Object.assign({
      fin: new Date().toISOString(),
      detalle: mensajes.length ? mensajes.join('\n').slice(0, 2000) : null,
    }, contadores));
  } catch (e) {
    console.error('No se pudo cerrar la ejecución ' + id + ': ' + e.message);
  }
}
