/**
 * Categorias.gs — clasificación de cada correo.
 *
 * La regla vive en UN solo lugar: la función de PostgreSQL fn_clasificar
 * (sql/09_fn_clasificar.sql), que usa también el bot de Telegram. Así un
 * mismo texto cae en la misma categoría venga de un correo o del bot.
 * Orden de la regla:
 *   1. Categoría por defecto de la fuente (p. ej. Retiro → Retiro de efectivo).
 *   2. Diccionario: palabra completa en la contraparte/descripción
 *      (p. ej. "RAPPI PERU" → rappi → Comida); si hay varias, la más larga.
 *   3. Sin categoría (NULL): queda para corregir en Retool.
 * Reglas antes que IA: gratis, predecible y explicable.
 *
 * Respaldo: si la función falla (aún no se creó, error de red...), el
 * movimiento se guarda igual con la categoría de la fuente o "Sin
 * categoría". Nunca se pierde un gasto por no poder clasificarlo.
 *
 * `rpc` se puede reemplazar en las pruebas (inyección de dependencias):
 * así Pruebas.gs prueba el respaldo sin conectarse a Supabase.
 */
function clasificar_(datos, fuente, rpc) {
  const llamar = rpc || db_.rpc;
  const texto = [datos.contraparte, datos.descripcion].filter(Boolean).join(' ');
  try {
    const id = llamar('fn_clasificar', { p_texto: texto, p_id_fuente: fuente ? fuente.id_fuente : null });
    return id || null;
  } catch (e) {
    console.warn(`fn_clasificar falló; se usa el respaldo: ${e.message}`);
    return (fuente && fuente.id_categoria_defecto) || null;
  }
}
