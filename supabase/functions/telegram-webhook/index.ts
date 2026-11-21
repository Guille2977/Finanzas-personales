/**
 * telegram-webhook — el bot de Telegram completo, como Edge Function de Supabase (Deno).
 *
 * Por qué aquí y no en Apps Script (medido el 16/11):
 *   · Apps Script responde al webhook con un 302 → Telegram reintenta y se traba.
 *   · Aun con un receptor intermedio, cada mensaje tardaba 2–3 s (arranque de
 *     Apps Script + cada llamada a Supabase/Telegram cruzando internet).
 *   · Aquí la función corre junto a la base: cada consulta tarda milisegundos.
 * Apps Script sigue haciendo lo programado: la captura de correos.
 *
 * Flujo: Telegram → POST aquí → se valida el secreto → se responde 200 AL
 * INSTANTE → el mensaje se procesa en segundo plano (EdgeRuntime.waitUntil).
 * Es lo que recomiendan Telegram, Stripe o Slack: si tardas, reintentan.
 *
 * Idempotencia: tabla telegram_updates (update_id PRIMARY KEY). Si Telegram
 * reenvía un update, el INSERT choca (23505) y se ignora. Segunda barrera:
 * numero_operacion = 'TG-<update_id>-<n>' con el UNIQUE (id_cuenta, numero_operacion).
 *
 * Secretos (Edge Functions → Secrets): TELEGRAM_TOKEN, TELEGRAM_CHAT_ID,
 * TELEGRAM_SECRETO, GEMINI_KEY (opcional), GEMINI_MODELO (opcional).
 * SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY los pone Supabase solo.
 * "Verify JWT" desactivado: Telegram no envía un JWT; la seguridad es el secreto.
 */
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  BOT, type Categoria, FRASES_RESPALDO, type FraseSentido, type Item, type Sentido, anonimizar, dataBoton, diaLima,
  escaparHtml as h, fechaDias, interpretarItem, interpretarMensaje, lunesLima, normalizar,
  palabraClave, pareceMonto, textoParaClasificar, validarInterpretacion, validarSugerencia,
} from "./logica.ts";

const env = (k: string) => Deno.env.get(k) ?? "";
const TOKEN = env("TELEGRAM_TOKEN");
const CHAT_ID = env("TELEGRAM_CHAT_ID");
const SECRETO = env("TELEGRAM_SECRETO");
const GEMINI_KEY = env("GEMINI_KEY");
const GEMINI_MODELO = env("GEMINI_MODELO") || "gemini-flash-lite-latest";

// service_role se salta RLS: solo vive en el servidor (nunca en Retool ni en un navegador).
const db = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false },
});

// ---------------------------------------------------------------------
// Entrada
// ---------------------------------------------------------------------

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  if (!SECRETO || req.headers.get("x-telegram-bot-api-secret-token") !== SECRETO) {
    return new Response("no autorizado", { status: 401 });
  }
  const update = await req.json().catch(() => null);
  if (update && typeof update.update_id === "number") {
    // @ts-ignore EdgeRuntime lo provee Supabase: sigue trabajando después de responder.
    EdgeRuntime.waitUntil(atender(update));
  }
  return new Response("ok");
});

interface Contadores { leidos: number; insertados: number; por_revisar: number; errores: number; llamadas_ia: number }

async function atender(update: any) {
  if (chatDe(update) !== CHAT_ID) return;                   // solo el dueño; a otros, silencio
  const t0 = Date.now();
  const inicio = new Date().toISOString();
  const cont: Contadores = { leidos: 1, insertados: 0, por_revisar: 0, errores: 0, llamadas_ia: 0 };
  const ia = { llamadas: 0, fallos: 0 };
  const mensajes: string[] = [];
  let repetido = false;
  try {
    const { error } = await db.from("telegram_updates").insert({ update_id: update.update_id });
    if (error) {
      if (error.code === "23505") { repetido = true; return; }   // reintento de Telegram: ya atendido
      throw new Error(`Supabase: ${error.message}`);
    }
    await manejarUpdate(update, cont, ia);
  } catch (e) {
    cont.errores++;
    mensajes.push(String((e as Error).message));
    await avisar(update, "❌ No pude procesarlo: " + String((e as Error).message).slice(0, 200));
  } finally {
    if (repetido) return;
    cont.llamadas_ia = ia.llamadas;
    if (ia.fallos) mensajes.push(`IA: ${ia.fallos} fallo(s)`);
    mensajes.push(`atendido en ${Date.now() - t0} ms`);
    const { error } = await db.from("ejecuciones").insert({ proceso: "bot", inicio, fin: new Date().toISOString(),
      detalle: mensajes.join("\n").slice(0, 2000), ...cont });
    if (error) console.error("No se pudo registrar la ejecución:", error.message);
  }
}

function chatDe(u: any): string | null {
  const m = u.message ?? u.callback_query?.message;
  return m?.chat ? String(m.chat.id) : null;
}

type Ia = { llamadas: number; fallos: number };

async function manejarUpdate(update: any, cont: Contadores, ia: Ia) {
  if (update.callback_query) return manejarBoton(update.callback_query, cont, ia);
  const msg = update.message;
  if (!msg) return;
  const chat = msg.chat.id;
  if (!msg.text) return enviar(chat, "Solo entiendo texto. Escribe /ayuda.");
  const texto = String(msg.text).trim();
  if (texto.startsWith("/")) return manejarComando(texto.split(/[\s@]/)[0].toLowerCase(), chat);
  if (normalizar(texto) === "deshacer") return deshacerUltimo(chat, msg.message_id);

  const items = interpretarMensaje(texto, (await contexto()).frases);
  for (let i = 0; i < items.length; i++) {
    await registrarItem(items[i], chat, msg.message_id, `TG-${update.update_id}-${i + 1}`, cont, ia);
  }
}

// ---------------------------------------------------------------------
// Registro
// ---------------------------------------------------------------------

interface Datos { monto: number; sentido: Sentido; id_cuenta: number; dias: number; id_categoria: number | null; palabra?: string }

async function registrarItem(it: Item, chat: number, idMsg: number, clave: string, cont: Contadores, ia: Ia) {
  const ctx = await contexto();

  if (!it.monto) {                                          // las reglas no entendieron → la IA propone
    const prop = pareceMonto(it.original) ? await iaInterpretar(it.original, ctx.categorias, ia) : null;
    if (!prop) {
      cont.por_revisar++;
      if (!it.ambiguo && it.concepto) {                     // hay palabra pero falta el monto
        return enviar(chat, `💬 ¿Cuánto costó? Escríbelo con el monto, por ejemplo: <code>${h(it.original)} 5</code>`, null, idMsg);
      }
      return enviar(chat, `🤔 No entendí «${h(it.original)}»` + (it.ambiguo ? " (hay más de un número)." : ".") +
        "\nEjemplo: <code>menú 12</code> · <code>yape 10 a Pedro cuota</code>", null, idMsg);
    }
    return proponer(chat, idMsg, { ...prop, id_cuenta: idCuenta(prop.medio, ctx) }, "🤖 La IA entendió esto. ¿Lo registro?", ctx);
  }

  const cuenta = idCuenta(it.medio, ctx);
  const datos: Datos = { monto: it.monto, sentido: it.sentido, id_cuenta: cuenta, dias: it.diasAtras ?? 0,
    id_categoria: await categoriaPorReglas(it), palabra: palabraClave(it.concepto) };

  if (it.monto > BOT.MONTO_CONFIRMAR) {
    return proponer(chat, idMsg, datos, `⚠️ S/ ${it.monto.toFixed(2)} es un monto alto. ¿Lo registro?`, ctx);
  }
  if (it.sentido === "ingreso" && it.medio === "yape") {  // los Yape recibidos ya llegan por correo
    const previo = await ingresoParecido(cuenta, it.monto, fechaDias(it.diasAtras));
    if (previo) {
      return proponer(chat, idMsg, datos, `🔁 Ya tengo un Yape recibido de S/ ${it.monto.toFixed(2)} ese día` +
        (previo.contraparte ? ` (${h(previo.contraparte)})` : "") + ". ¿Es otro distinto?", ctx, "Es otro: registrar", "Es el mismo");
    }
  }

  const mov = await insertarMov(datos, it.original, it.contraparte, clave);
  if (!mov) return;                                         // ya existía
  cont.insertados++;
  if (mov.id_categoria) return enviar(chat, textoMov(mov, ctx), tecladoMov(mov), idMsg);
  cont.por_revisar++;
  await preguntarCategoria(chat, idMsg, mov, it.concepto, ctx, ia);
}

/**
 * Misma regla que los correos: public.fn_clasificar (sql/09_fn_clasificar.sql).
 * p_sentido: un ingreso no cae en "Comida". Lee el diccionario en vivo, así
 * una palabra recién aprendida se usa desde el siguiente mensaje.
 * Respaldo: si la función falla, el gasto se registra "Sin categoría" y el bot
 * pregunta con botones (nunca se pierde el gasto).
 */
async function categoriaPorReglas(it: Item): Promise<number | null> {
  const { data, error } = await db.rpc("fn_clasificar", { p_texto: textoParaClasificar(it), p_sentido: it.sentido });
  if (error) {
    console.error(`fn_clasificar falló; queda Sin categoría: ${error.message}`);
    return null;
  }
  return typeof data === "number" ? data : null;
}

/** Botones al instante; la sugerencia de la IA se agrega después editando el mensaje. */
async function preguntarCategoria(chat: number, idMsg: number | null, mov: any, concepto: string, ctx: Ctx, ia: Ia, editarId?: number) {
  const palabra = palabraClave(concepto);
  const pintar = (sug: any, destino?: number) => {
    const pal = sug?.palabra || palabra;
    const teclado: any[] = [];
    if (sug) teclado.push([{ text: `✅ ${[sug.icono, sug.nombre].filter(Boolean).join(" ")} (sugerida por IA)`,
      callback_data: dataBoton(["k", mov.id_movimiento, sug.id_categoria], pal) }]);
    teclado.push(...tecladoCategorias(mov.id_movimiento, mov.sentido, pal, ctx));
    teclado.push([{ text: "↩️ Deshacer", callback_data: `u|${mov.id_movimiento}` }]);
    const html = `${textoMov(mov, ctx)}\n\n¿Qué categoría es${pal ? ` «${h(pal)}»` : ""}?` +
      (pal ? " La recordaré para la próxima." : "") + (sug === undefined && palabra && GEMINI_KEY ? "\n🤖 Consultando a la IA…" : "");
    return destino ? editar(chat, destino, html, teclado) : enviar(chat, html, teclado, idMsg);
  };
  const enviado = await pintar(undefined, editarId);
  if (!palabra || !GEMINI_KEY) return;
  const sug = await iaSugerirCategoria(concepto, ctx.categorias.filter((c) => c.tipo === mov.sentido), ia);
  await Promise.resolve(pintar(sug ?? null, editarId ?? enviado?.message_id)).catch(() => {});
}

// ---------------------------------------------------------------------
// Botones
// ---------------------------------------------------------------------

async function manejarBoton(cq: any, cont: Contadores, ia: Ia) {
  const chat = cq.message.chat.id;
  const idMsg = cq.message.message_id;
  const a = String(cq.data ?? "").split("|");
  tg("answerCallbackQuery", { callback_query_id: cq.id }).catch(() => {});   // quita el "cargando" ya
  const ctx = await contexto();

  switch (a[0]) {
    case "k": {                                             // fijar categoría + aprender
      const mov = await actualizarMov(a[1], { id_categoria: Number(a[2]) });
      if (!mov) return editar(chat, idMsg, "Ese movimiento ya no existe.");
      const palabra = a[3] ? await aprender(a[3], Number(a[2]), mov.sentido, ctx) : null;
      return editar(chat, idMsg, textoMov(mov, ctx) +
        (palabra ? `\n📚 Aprendí: «${h(palabra)}» → ${h(nombreCat(mov.id_categoria, ctx))}` : ""), tecladoMov(mov));
    }
    case "m": {                                             // menú para cambiar categoría
      const [mov] = await leer(db.from("movimientos").select("*").eq("id_movimiento", Number(a[1])).eq("origen", "telegram"));
      if (!mov) return editar(chat, idMsg, "Ese movimiento ya no existe.");
      const teclado = tecladoCategorias(mov.id_movimiento, mov.sentido, palabraClave(interpretarItem(mov.descripcion ?? "", ctx.frases).concepto), ctx);
      teclado.push([{ text: "↩️ Deshacer", callback_data: `u|${mov.id_movimiento}` }]);
      return editar(chat, idMsg, textoMov(mov, ctx) + "\n\nElige la nueva categoría:", teclado);
    }
    case "u": {                                             // deshacer (borrado lógico, nunca DELETE)
      const mov = await actualizarMov(a[1], { estado: "anulado" });
      return editar(chat, idMsg, mov ? `↩️ <s>${textoMov(mov, ctx)}</s>\nAnulado.` : "Ya no existe.");
    }
    case "p": {                                             // confirmar propuesta
      const datos: Datos = { monto: Number(a[1]) / 100, id_categoria: Number(a[2]) || null, id_cuenta: Number(a[3]),
        sentido: a[4] === "i" ? "ingreso" : "egreso", dias: Number(a[5]) || 0 };
      const original = cq.message.reply_to_message?.text ?? "Registro desde Telegram";
      const mov = await insertarMov(datos, original, null, `TG-B${idMsg}`);   // dos toques ≠ dos registros
      if (!mov) return editar(chat, idMsg, "Ya estaba registrado.");
      cont.insertados++;
      const palabra = a[6] && datos.id_categoria ? await aprender(a[6], datos.id_categoria, datos.sentido, ctx) : null;
      if (mov.id_categoria) {
        return editar(chat, idMsg, textoMov(mov, ctx) + (palabra ? `\n📚 Aprendí: «${h(palabra)}»` : ""), tecladoMov(mov));
      }
      return preguntarCategoria(chat, null, mov, interpretarItem(original, ctx.frases).concepto, ctx, ia, idMsg);
    }
    case "x":
      return editar(chat, idMsg, "Listo, no registré nada.");
  }
}

// ---------------------------------------------------------------------
// Comandos
// ---------------------------------------------------------------------

async function manejarComando(cmd: string, chat: number) {
  const hoy = diaLima();
  const totales = (filas: any[]) => {
    const suma = (s: string) => filas.filter((f) => f.sentido === s && !f.es_transferencia).reduce((t, f) => t + Number(f.monto), 0);
    return `Gastos: <b>S/ ${suma("egreso").toFixed(2)}</b> · Ingresos: S/ ${suma("ingreso").toFixed(2)}`;
  };
  switch (cmd) {
    case "/hoy": {
      const filas = await leer(db.from("v_movimientos_contables")
        .select("monto,sentido,categoria,descripcion,contraparte,es_transferencia").eq("dia", hoy).order("fecha_lima"));
      if (!filas.length) return enviar(chat, "Hoy no hay movimientos.");
      const lineas = filas.slice(-30).map((f: any) =>
        `${f.sentido === "ingreso" ? "➕" : "➖"} S/ ${Number(f.monto).toFixed(2)} · ${h(f.categoria)} · ${h((f.descripcion || f.contraparte || "").slice(0, 40))}`);
      return enviar(chat, `<b>Hoy</b>\n${lineas.join("\n")}\n\n${totales(filas)}`);
    }
    case "/semana": {
      const filas = await leer(db.from("v_movimientos_contables").select("monto,sentido,categoria,es_transferencia").eq("semana", lunesLima()));
      const t: Record<string, number> = {};
      filas.filter((f: any) => f.sentido === "egreso" && !f.es_transferencia)
        .forEach((f: any) => { t[f.categoria] = (t[f.categoria] ?? 0) + Number(f.monto); });
      const lista = Object.keys(t).sort((a, b) => t[b] - t[a]).map((c) => `• ${h(c)}: S/ ${t[c].toFixed(2)}`).join("\n");
      return enviar(chat, `<b>Esta semana</b>\n${lista || "Sin gastos aún."}\n\n${totales(filas)}`);
    }
    case "/mes": {
      const filas = await leer(db.from("v_gasto_categoria_mes").select("categoria,total")
        .eq("mes", hoy.slice(0, 8) + "01").eq("moneda", "PEN").eq("sentido", "egreso").order("total", { ascending: false }));
      const total = filas.reduce((s: number, f: any) => s + Number(f.total), 0);
      return enviar(chat, "<b>Gasto del mes</b>\n" +
        (filas.map((f: any) => `• ${h(f.categoria)}: S/ ${Number(f.total).toFixed(2)}`).join("\n") || "Sin gastos aún.") +
        `\n\nTotal: <b>S/ ${total.toFixed(2)}</b>`);
    }
    case "/presupuesto": {
      const filas = await leer(db.from("v_avance_presupuesto").select("categoria,limite,gastado,porcentaje,estado")
        .order("porcentaje", { ascending: false }));
      if (!filas.length) return enviar(chat, "No hay presupuestos definidos (tabla presupuestos).");
      const icono: Record<string, string> = { ok: "🟢", alerta: "🟡", excedido: "🔴" };
      return enviar(chat, "<b>Presupuestos del mes</b>\n" + filas.map((f: any) =>
        `${icono[f.estado] ?? "•"} ${h(f.categoria)}: ${f.porcentaje}% (S/ ${Number(f.gastado).toFixed(2)} de ${Number(f.limite).toFixed(2)})`).join("\n"));
    }
    default:
      return enviar(chat,
        "<b>Cómo registrar</b> (efectivo por defecto)\n" +
        "<code>pasaje 3</code> · <code>queque .2</code> · <code>3 soles de pasaje</code>\n" +
        "<code>yape 10 a Pedro cuota</code> → Yape enviado\n" +
        "<code>ayer menú 12</code> · <code>pasaje 3, golosina 1.5</code>\n" +
        "<code>me pagaron 50</code> · <code>me yapearon 5 de Ana</code> → ingreso\n" +
        "<code>deshacer</code> → anula el último\n\n/hoy · /semana · /mes · /presupuesto");
  }
}

async function deshacerUltimo(chat: number, idMsg: number) {
  const filas = await leer(db.from("movimientos").select("id_movimiento").eq("origen", "telegram").eq("estado", "activo")
    .order("creado_en", { ascending: false }).limit(1));          // .limit(1) ≈ TOP 1
  if (!filas.length) return enviar(chat, "No hay registros del bot para deshacer.", null, idMsg);
  const mov = await actualizarMov(filas[0].id_movimiento, { estado: "anulado" });
  return enviar(chat, `↩️ Anulado: ${textoMov(mov, await contexto())}`, null, idMsg);
}

// ---------------------------------------------------------------------
// Datos
// ---------------------------------------------------------------------

interface Ctx { cuentas: { id_cuenta: number; alias: string }[]; categorias: Categoria[]; frases: FraseSentido[] }
let CACHE: { t: number; ctx: Ctx } | null = null;

/**
 * Catálogos en memoria 60 s (la función sigue "caliente" entre mensajes seguidos). Las consultas van en paralelo.
 * El diccionario ya no se cachea aquí: lo lee fn_clasificar en la base.
 */
async function contexto(): Promise<Ctx> {
  if (CACHE && Date.now() - CACHE.t < 60_000) return CACHE.ctx;
  const [cuentas, categorias, frases] = await Promise.all([
    leer(db.from("cuentas").select("id_cuenta,alias").eq("activo", true)),
    leer(db.from("categorias").select("id_categoria,nombre,tipo,icono").eq("activo", true).order("nombre")),
    // Frases ingreso/egreso (sql/10). Si la tabla falla o está vacía, se usa la lista
    // de respaldo del código: mejor un bot un poco menos listo que un bot caído.
    leer(db.from("frases_sentido").select("frase,sentido").eq("activo", true))
      .then((f) => f.length ? f : FRASES_RESPALDO)
      .catch((e) => { console.error("frases_sentido:", e.message); return FRASES_RESPALDO; }),
  ]);
  CACHE = { t: Date.now(), ctx: { cuentas, categorias, frases } };
  return CACHE.ctx;
}

async function leer(consulta: PromiseLike<{ data: any; error: any }>): Promise<any[]> {
  const { data, error } = await consulta;
  if (error) throw new Error(`Supabase: ${error.message}`);
  return data ?? [];
}

function idCuenta(medio: string, ctx: Ctx): number {
  const alias = medio === "yape" ? BOT.CUENTA_YAPE : BOT.CUENTA_EFECTIVO;
  const c = ctx.cuentas.find((x) => x.alias === alias);
  if (!c) throw new Error(`No existe la cuenta activa "${alias}" (tabla cuentas).`);
  return c.id_cuenta;
}

async function insertarMov(d: Datos, original: string, contraparte: string | null, clave: string) {
  const { data, error } = await db.from("movimientos").insert({
    fecha: fechaDias(d.dias), monto: d.monto, moneda: "PEN", sentido: d.sentido, id_cuenta: d.id_cuenta,
    id_categoria: d.id_categoria || null, descripcion: String(original).slice(0, 200),
    contraparte: contraparte || null, numero_operacion: clave, origen: "telegram",
  }).select().single();
  if (error) {
    if (error.code === "23505") return null;               // UNIQUE (id_cuenta, numero_operacion)
    throw new Error(`Supabase: ${error.message}`);
  }
  return data;
}

/** Desde Telegram solo se tocan movimientos del bot, nunca los del banco. */
async function actualizarMov(id: string | number, cambios: Record<string, unknown>) {
  const filas = await leer(db.from("movimientos").update(cambios).eq("id_movimiento", Number(id)).eq("origen", "telegram").select());
  return filas[0] ?? null;
}

/** Aprendizaje: INSERT ... ON CONFLICT (palabra) DO UPDATE (upsert). Gana la elección del usuario. */
async function aprender(palabra: string, idCategoria: number, sentido: string, ctx: Ctx) {
  const p = normalizar(palabra);
  const cat = ctx.categorias.find((c) => c.id_categoria === idCategoria);
  if (p.length < 3 || !cat || cat.tipo !== sentido) return null;
  await leer(db.from("diccionario").upsert({ palabra: p, id_categoria: idCategoria, activo: true, origen: "bot" },
    { onConflict: "palabra" }).select());
  return p;                                                  // fn_clasificar la usa desde el próximo mensaje
}

async function ingresoParecido(idCuenta: number, monto: number, fechaIso: string) {
  const dia = diaLima(fechaIso);
  const filas = await leer(db.from("movimientos").select("id_movimiento,contraparte").eq("id_cuenta", idCuenta)
    .eq("sentido", "ingreso").eq("estado", "activo").eq("monto", monto)
    .gte("fecha", `${dia}T00:00:00-05:00`).lte("fecha", `${dia}T23:59:59.999-05:00`).limit(1));
  return filas[0] ?? null;
}

// ---------------------------------------------------------------------
// Presentación
// ---------------------------------------------------------------------

function nombreCat(id: number | null, ctx: Ctx) {
  const c = ctx.categorias.find((x) => x.id_categoria === id);
  return c ? [c.icono, c.nombre].filter(Boolean).join(" ") : "Sin categoría";
}

function textoMov(mov: any, ctx: Ctx) {
  const cuenta = ctx.cuentas.find((c) => c.id_cuenta === mov.id_cuenta);
  return `${mov.sentido === "ingreso" ? "➕" : "✅"} S/ ${Number(mov.monto).toFixed(2)} · ` +
    `${h(nombreCat(mov.id_categoria, ctx))} · ${h(cuenta?.alias ?? "")}` +
    (mov.contraparte ? ` · ${h(mov.contraparte)}` : "") +
    (diaLima(mov.fecha) !== diaLima() ? ` · ${diaLima(mov.fecha)}` : "");
}

function tecladoMov(mov: any) {
  return [[
    { text: "🏷️ Cambiar categoría", callback_data: `m|${mov.id_movimiento}` },
    { text: "↩️ Deshacer", callback_data: `u|${mov.id_movimiento}` },
  ]];
}

function tecladoCategorias(idMov: number, tipo: string, palabra: string, ctx: Ctx) {
  const botones = ctx.categorias.filter((c) => c.tipo === tipo).map((c) => ({
    text: [c.icono, c.nombre].filter(Boolean).join(" "),
    callback_data: dataBoton(["k", idMov, c.id_categoria], palabra),
  }));
  const filas: any[] = [];
  for (let i = 0; i < botones.length; i += 2) filas.push(botones.slice(i, i + 2));
  return filas;
}

function proponer(chat: number, idMsg: number, d: Datos, titulo: string, ctx: Ctx, si?: string, no?: string) {
  const cuenta = ctx.cuentas.find((c) => c.id_cuenta === d.id_cuenta);
  const html = `${titulo}\n\n${d.sentido === "ingreso" ? "➕ Ingreso" : "➖ Gasto"} <b>S/ ${d.monto.toFixed(2)}</b>` +
    ` · ${h(nombreCat(d.id_categoria, ctx))} · ${h(cuenta?.alias ?? "?")}` + (d.dias ? ` · hace ${d.dias} día(s)` : "");
  const data = dataBoton(["p", Math.round(d.monto * 100), d.id_categoria || 0, d.id_cuenta, d.sentido === "ingreso" ? "i" : "e", d.dias || 0], d.palabra);
  return enviar(chat, html, [[{ text: "✅ " + (si ?? "Confirmar"), callback_data: data }, { text: "❌ " + (no ?? "Cancelar"), callback_data: "x" }]], idMsg);
}

// ---------------------------------------------------------------------
// Telegram
// ---------------------------------------------------------------------

async function tg(metodo: string, datos: Record<string, unknown>) {
  const r = await fetch(`https://api.telegram.org/bot${TOKEN}/${metodo}`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(datos),
  });
  const j = await r.json().catch(() => ({}));
  if (!j.ok) throw new Error(`Telegram ${metodo}: ${j.description ?? r.status}`);   // el token nunca va en el error
  return j.result;
}

function enviar(chat: number, html: string, teclado?: any[] | null, responderA?: number | null) {
  const datos: Record<string, unknown> = { chat_id: chat, text: html, parse_mode: "HTML", link_preview_options: { is_disabled: true } };
  if (teclado) datos.reply_markup = { inline_keyboard: teclado };
  if (responderA) datos.reply_parameters = { message_id: responderA, allow_sending_without_reply: true };
  return tg("sendMessage", datos);
}

async function editar(chat: number, idMsg: number, html: string, teclado?: any[]) {
  try {
    return await tg("editMessageText", { chat_id: chat, message_id: idMsg, text: html, parse_mode: "HTML",
      reply_markup: { inline_keyboard: teclado ?? [] } });
  } catch (e) {
    if (!/not modified/i.test(String((e as Error).message))) throw e;   // mismo texto: no es error
  }
}

async function avisar(update: any, texto: string) {
  const chat = chatDe(update);
  if (chat) await enviar(Number(chat), h(texto)).catch((e) => console.error("No se pudo avisar:", e.message));
}

// ---------------------------------------------------------------------
// IA (Gemini): solo respaldo, nunca registra sola, con límite de tiempo real
// ---------------------------------------------------------------------

async function gemini(prompt: string, esquema: unknown, ia: Ia): Promise<any> {
  if (!GEMINI_KEY) return null;
  ia.llamadas++;
  try {
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODELO}:generateContent`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": GEMINI_KEY },
      body: JSON.stringify({ contents: [{ role: "user", parts: [{ text: prompt }] }],
        generationConfig: { temperature: 0, responseMimeType: "application/json", responseSchema: esquema } }),
      signal: AbortSignal.timeout(8000),                    // más de 8 s → se abandona (en Apps Script no se podía)
    });
    const j = await r.json();
    if (!r.ok) throw new Error(`HTTP ${r.status}: ${j.error?.message ?? ""}`);
    const texto = (j.candidates?.[0]?.content?.parts ?? []).map((p: any) => p.text ?? "").join("");
    return JSON.parse(texto);
  } catch (e) {
    ia.fallos++;
    console.warn("IA no disponible:", (e as Error).message);
    return null;
  }
}

async function iaSugerirCategoria(concepto: string, categorias: Categoria[], ia: Ia) {
  if (!categorias.length) return null;
  const nombres = categorias.map((c) => c.nombre);
  const r = await gemini(
    "Clasifica un gasto/ingreso personal de un estudiante en Perú.\n" +
    `Texto: "${anonimizar(concepto)}"\n` +
    `Elige UNA categoría de esta lista: ${nombres.join(", ")}. Si ninguna encaja con claridad, responde "ninguna".\n` +
    "palabra_clave: la palabra del texto que mejor identifica el gasto, copiada tal cual.",
    { type: "OBJECT", properties: { categoria: { type: "STRING", enum: [...nombres, "ninguna"] }, palabra_clave: { type: "STRING" } },
      required: ["categoria", "palabra_clave"] }, ia);
  return validarSugerencia(r, concepto, categorias);
}

async function iaInterpretar(texto: string, categorias: Categoria[], ia: Ia) {
  if (!GEMINI_KEY) return null;
  const nombres = categorias.filter((c) => c.tipo !== "transferencia").map((c) => c.nombre);
  const r = await gemini(
    "Eres el asistente de finanzas personales de un estudiante en Perú (moneda: soles).\n" +
    `Mensaje: "${anonimizar(texto)}"\n` +
    "Extrae UN movimiento. entendido=false si no hay un monto claro.\n" +
    '- sentido: "ingreso" si recibió dinero, si no "egreso".\n' +
    '- medio: "yape" si menciona Yape, si no "efectivo".\n' +
    `- categoria: una de [${nombres.join(", ")}] o "ninguna".\n` +
    "- dias_atras: 0 hoy, 1 ayer, etc.\n" +
    "- palabra_clave: la palabra del mensaje que identifica el gasto, copiada tal cual.",
    { type: "OBJECT", properties: {
      entendido: { type: "BOOLEAN" }, monto: { type: "NUMBER" },
      sentido: { type: "STRING", enum: ["egreso", "ingreso"] }, medio: { type: "STRING", enum: ["efectivo", "yape"] },
      categoria: { type: "STRING", enum: [...nombres, "ninguna"] }, dias_atras: { type: "INTEGER" }, palabra_clave: { type: "STRING" },
    }, required: ["entendido", "monto", "sentido", "medio", "categoria", "dias_atras", "palabra_clave"] }, ia);
  return validarInterpretacion(r, texto, categorias, BOT.MONTO_CONFIRMAR * 20, BOT.MAX_DIAS_ATRAS);
}
