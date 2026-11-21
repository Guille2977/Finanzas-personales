/**
 * BaseDatos.gs — ÚNICA capa que habla con Supabase (API REST de PostgREST).
 *
 * Por qué una sola capa: si mañana cambio de base o de forma de conexión,
 * solo cambia este archivo. El resto del código llama a db_.insertar(...),
 * db_.leer(...), etc., sin saber nada de HTTP.
 *
 * Cómo funciona la API REST de Supabase (PostgREST):
 *   GET    /rest/v1/tabla?columna=eq.valor        → SELECT ... WHERE columna = valor
 *   POST   /rest/v1/tabla                         → INSERT
 *   POST   /rest/v1/tabla?on_conflict=col  + Prefer: resolution=merge-duplicates
 *                                                 → INSERT ... ON CONFLICT (col) DO UPDATE (upsert)
 *   PATCH  /rest/v1/tabla?id=eq.5                 → UPDATE ... WHERE id = 5
 *   POST   /rest/v1/rpc/funcion  {"p_x": 1}      → SELECT funcion(p_x => 1)
 */

const db_ = (() => {
  const REINTENTOS = 3;

  function base_() {
    return propiedad_('SUPABASE_URL').replace(/\/+$/, '') + '/rest/v1/';
  }

  function cabeceras_(prefer) {
    const clave = propiedad_('SUPABASE_KEY');
    const h = { apikey: clave, 'Content-Type': 'application/json' };
    // Las claves antiguas (service_role) son JWT ("eyJ...") y van también en
    // Authorization. Las nuevas (sb_secret_...) van solo en "apikey".
    if (clave.startsWith('eyJ')) h.Authorization = 'Bearer ' + clave;
    if (prefer) h.Prefer = prefer;
    return h;
  }

  /**
   * Hace la petición. Reintenta solo errores TRANSITORIOS (red, 429, 5xx),
   * con espera creciente (1 s, 2 s, 4 s). Un 4xx (dato inválido, duplicado)
   * no se reintenta: repetirlo daría el mismo error.
   */
  function pedir_(metodo, ruta, cuerpo, prefer) {
    const opciones = {
      method: metodo,
      headers: cabeceras_(prefer),
      muteHttpExceptions: true,   // leemos el código nosotros en vez de que lance
    };
    if (cuerpo !== undefined) opciones.payload = JSON.stringify(cuerpo);

    let ultimoError;
    for (let intento = 1; intento <= REINTENTOS; intento++) {
      try {
        const r = UrlFetchApp.fetch(base_() + ruta, opciones);
        const codigo = r.getResponseCode();
        const texto = r.getContentText();
        if (codigo >= 200 && codigo < 300) return texto ? JSON.parse(texto) : null;
        const err = errorBd_(codigo, texto);
        if (codigo !== 429 && codigo < 500) throw err;          // definitivo
        ultimoError = err;                                       // transitorio
      } catch (e) {
        if (e.esErrorBd && !e.transitorio) throw e;
        e.transitorio = true;                                    // red caída, timeout, DNS...
        ultimoError = e;
      }
      if (intento < REINTENTOS) Utilities.sleep(1000 * Math.pow(2, intento - 1));
    }
    throw ultimoError;
  }

  function errorBd_(codigo, texto) {
    let detalle = {};
    try { detalle = JSON.parse(texto); } catch (_) { /* respuesta no JSON */ }
    const e = new Error(`Supabase ${codigo}: ${detalle.message || texto}`.slice(0, 500));
    e.esErrorBd = true;
    e.http = codigo;
    e.codigoPg = detalle.code;            // p. ej. 23505 = UNIQUE violado
    e.transitorio = codigo === 429 || codigo >= 500;
    return e;
  }

  return {
    leer: (tabla, filtros) => pedir_('get', `${tabla}?${filtros || 'select=*'}`),
    insertar: (tabla, filas) => pedir_('post', tabla, filas, 'return=representation'),
    /** Upsert: si choca con la clave única "columna", actualiza los campos enviados. */
    upsert: (tabla, filas, columna) =>
      pedir_('post', `${tabla}?on_conflict=${columna}`, filas, 'resolution=merge-duplicates,return=representation'),
    actualizar: (tabla, filtros, cambios) => pedir_('patch', `${tabla}?${filtros}`, cambios, 'return=representation'),
    /** Llama a una función de PostgreSQL. Los argumentos van por nombre (p_texto, p_id_fuente...). */
    rpc: (funcion, argumentos) => pedir_('post', `rpc/${funcion}`, argumentos || {}),
  };
})();

/** true si el error es de UNIQUE violado (fila duplicada). */
function esDuplicado_(e) {
  return e && e.esErrorBd && e.codigoPg === '23505';
}
