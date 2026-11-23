/**
 * PruebasResumen.gs — casos de Alertas.gs para la conciliación y el resumen
 * mensual (sql/13). Se suman a probarTodo() (Pruebas.gs).
 *
 * QUÉ se concilia y QUÉ dice el resumen se prueba en SQL (21 pruebas al
 * final de sql/13_conciliacion_resumen.sql). Aquí solo lo que hace Apps
 * Script: llamar a las tareas en orden y seguir si una falla (rpc simulado,
 * sin red).
 */
function casosResumen_() {
  return [
    ['tareas: corren todas, en orden', () => {
      const llamadas = [];
      const r = ejecutarTareas_(['a', 'b', 'c'], (fn) => { llamadas.push(fn); return fn.toUpperCase(); });
      return [llamadas, r.resultados, r.errores];
    }, [['a', 'b', 'c'], { a: 'A', b: 'B', c: 'C' }, []]],
    ['tareas: si una falla, las demás siguen', () => {
      const llamadas = [];
      const r = ejecutarTareas_(['fn_conciliar_movimientos', 'fn_generar_resumen_mensual', 'fn_generar_alertas'], (fn) => {
        llamadas.push(fn);
        if (fn === 'fn_conciliar_movimientos') throw new Error('Supabase 404: Could not find the function');
        return 1;
      });
      return [llamadas.length, r.resultados.fn_generar_alertas, r.errores];
    }, [3, 1, ['fn_conciliar_movimientos: Supabase 404: Could not find the function']]],
    ['tareas: el orden concilia antes de alertar', () =>
      TAREAS_ALERTAS_.indexOf('fn_conciliar_movimientos') < TAREAS_ALERTAS_.indexOf('fn_generar_alertas'), true],
  ];
}
