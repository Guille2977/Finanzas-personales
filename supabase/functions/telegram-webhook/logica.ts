/**
 * logica.ts — reglas del bot, PURAS (sin red ni base). Se prueban en logica_test.ts.
 * Es la misma lógica que tenía Bot.gs/IA.gs en Apps Script, pasada a TypeScript
 * (TypeScript = JavaScript + tipos; Apps Script ya era JavaScript).
 */

export const BOT = {
  CUENTA_EFECTIVO: "Efectivo",   // alias en la tabla cuentas
  CUENTA_YAPE: "BCP Yape",
  MONTO_CONFIRMAR: 500,          // por encima, se pide confirmar
  MAX_DIAS_ATRAS: 7,
  YAPE: ["yape", "yapee", "yapie", "yapeo", "yapeado", "yapeaste", "yapearon", "yapear"],
  EFECTIVO: ["efectivo", "cash", "sencillo"],
  // RESPALDO: las frases viven en la tabla frases_sentido (sql/10). Esta lista solo
  // se usa si la base no responde, para que el bot no se caiga por eso.
  INGRESO: ["me pagaron", "me yapearon", "me han yapeado", "me yapeo", "me dieron", "me depositaron",
    "me devolvieron", "me transfirieron", "me pasaron", "me enviaron", "me mandaron",
    "recibi", "cobre", "gane", "ingreso"],
  FECHAS: { hoy: 0, ayer: 1, anteayer: 2 } as Record<string, number>,
  MONEDA: ["soles", "sol", "lucas", "luca", "s"],
  RELLENO: ["de", "del", "la", "el", "los", "las", "lo", "un", "una", "unos", "unas", "en", "por",
    "para", "pa", "con", "al", "a", "y", "o", "me", "mi", "mis", "se", "que", "compre",
    "gaste", "pague", "gasto"],
};

export type Sentido = "egreso" | "ingreso";
export type Medio = "efectivo" | "yape";
export interface Item {
  original: string; monto: number | null; ambiguo: boolean; sentido: Sentido; medio: Medio;
  diasAtras: number | null; contraparte: string | null; concepto: string;
}
/** Fila de la tabla frases_sentido: "me yapearon" → ingreso. */
export interface FraseSentido { frase: string; sentido: Sentido }
export const FRASES_RESPALDO: FraseSentido[] = BOT.INGRESO.map((frase) => ({ frase, sentido: "ingreso" }));

/**
 * Sentido del mensaje según las frases configuradas. Misma regla que fn_clasificar:
 * frase COMPLETA (palabra por palabra) y, si hay varias, gana la más larga
 * ("me devolvieron" le gana a "devolvi"); empate → orden alfabético. Sin frase → egreso.
 */
export function detectarSentido(palabras: string[], frases: FraseSentido[] = FRASES_RESPALDO) {
  const unido = " " + palabras.join(" ") + " ";
  const hallada = frases
    .map((f) => ({ frase: normalizar(f.frase), sentido: f.sentido }))
    .filter((f) => f.frase && unido.includes(` ${f.frase} `))
    .sort((a, b) => b.frase.length - a.frase.length || a.frase.localeCompare(b.frase))[0];
  return hallada ?? { frase: null, sentido: "egreso" as Sentido };
}

export interface Categoria { id_categoria: number; nombre: string; tipo: string; icono?: string | null }

/**
 * Minúsculas, sin tildes (conserva la ñ), solo letras/números. Igual que el CHECK de `diccionario`.
 * Aquí solo sirve para comparar comandos y palabras del mensaje; para CLASIFICAR
 * manda public.fn_normalizar/fn_clasificar en PostgreSQL (sql/09).
 */
export function normalizar(texto: unknown): string {
  return String(texto ?? "").toLowerCase()
    .replace(/ñ/g, "\u0001")
    .normalize("NFD").replace(/[̀-ͯ]/g, "")
    .replace(/\u0001/g, "ñ")
    .replace(/[^a-zñ0-9]+/g, " ")
    .trim();
}

/** Separa por coma+espacio, punto y coma o salto de línea ("3,50" no se corta). */
export function interpretarMensaje(texto: string, frases: FraseSentido[] = FRASES_RESPALDO): Item[] {
  const items = String(texto ?? "").split(/\s*(?:;|\n|,\s+)\s*/).filter((s) => s.trim())
    .map((s) => interpretarItem(s, frases));
  let dias = 0;   // "ayer menú 12, pasaje 3": la fecha vale para los siguientes
  for (const it of items) { if (it.diasAtras === null) it.diasAtras = dias; else dias = it.diasAtras; }
  return items;
}

const esMonto = (t: string) => /^(\d+([.,]\d{1,2})?|[.,]\d{1,2})$/.test(t);

export function interpretarItem(original: string, frases: FraseSentido[] = FRASES_RESPALDO): Item {
  const texto = original.trim();
  const tokens = (" " + texto.toLowerCase() + " ")
    .replace(/s\/\.?/g, " s/ ")
    .replace(/(\d)(soles|sol|lucas|luca)\b/g, "$1 $2")
    .split(/\s+/).filter(Boolean)
    .map((t) => t.replace(/[!?¡¿:]+$/g, "").replace(/(\d)\.$/, "$1"));

  const candidatos: { i: number; valor: number; marcado: boolean }[] = [];
  tokens.forEach((t, i) => {
    if (!esMonto(t)) return;
    const marcado = tokens[i - 1] === "s/" || BOT.MONEDA.includes(tokens[i + 1]);
    candidatos.push({ i, valor: Math.round(parseFloat(t.replace(",", ".")) * 100) / 100, marcado });
  });
  const marcados = candidatos.filter((c) => c.marcado);
  const elegido = candidatos.length === 1 ? candidatos[0] : marcados.length === 1 ? marcados[0] : null;

  let palabras = normalizar(tokens.filter((t, i) => !(elegido && i === elegido.i) && t !== "s/").join(" "))
    .split(" ").filter(Boolean);

  // El medio se mira ANTES de quitar la frase: "me han yapeado" es ingreso Y es Yape.
  const medio: Medio = palabras.some((p) => BOT.YAPE.includes(p)) ? "yape" : "efectivo";

  const { frase, sentido } = detectarSentido(palabras, frases);
  if (frase) {
    const partes = frase.split(" ");
    const ini = palabras.findIndex((_, i) => partes.every((q, j) => palabras[i + j] === q));
    palabras.splice(ini, partes.length);
  }

  palabras = palabras.filter((p) => !BOT.YAPE.includes(p) && !BOT.EFECTIVO.includes(p));

  let diasAtras: number | null = null;
  palabras = palabras.filter((p) => {
    if (p in BOT.FECHAS) { diasAtras = BOT.FECHAS[p]; return false; }
    return true;
  });

  let contraparte: string | null = null;
  if (medio === "yape") {
    const prep = sentido === "ingreso" ? "de" : "a";
    const i = palabras.findIndex((p, k) => p === prep && palabras[k + 1] && !BOT.RELLENO.includes(palabras[k + 1]));
    if (i >= 0) {
      const nombre = palabras[i + 1];
      contraparte = nombre.charAt(0).toUpperCase() + nombre.slice(1);
      palabras.splice(i, 2);
    }
  }

  const concepto = palabras.filter((p) => !BOT.RELLENO.includes(p) && !BOT.MONEDA.includes(p) && !esMonto(p)).join(" ");
  return { original: texto, monto: elegido ? elegido.valor : null, ambiguo: !elegido && candidatos.length > 1,
    sentido, medio, diasAtras, contraparte, concepto };
}

/**
 * ¿Vale la pena pedirle a la IA que busque un monto? Solo si hay dígitos o
 * números escritos en palabras ("cuatro cincuenta"). Si no, se pregunta
 * "¿cuánto costó?" al instante, sin esperar a la IA.
 */
export function pareceMonto(texto: string): boolean {
  return /\d|\b(uno|un|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|once|doce|quince|veinte|treinta|cuarenta|cincuenta|sesenta|setenta|ochenta|noventa|cien|ciento|mil|medio|sol|soles|luca|lucas)\b/
    .test(normalizar(texto));
}

/**
 * Texto que se manda a fn_clasificar (sql/09): contraparte + concepto.
 * La regla (diccionario, palabra completa, la más larga gana) vive en
 * PostgreSQL y es la misma que usan los correos.
 */
export function textoParaClasificar(it: Pick<Item, "contraparte" | "concepto">): string {
  return [it.contraparte, it.concepto].filter(Boolean).join(" ");
}

export function palabraClave(concepto: string): string {
  return String(concepto ?? "").split(" ").find((p) => p.length >= 3 && !/^\d+$/.test(p)) ?? "";
}

/** callback_data acepta 64 BYTES (ñ = 2): se recorta la palabra si no entra. */
export function dataBoton(partes: (string | number)[], palabra?: string): string {
  const bytes = (s: string) => new TextEncoder().encode(s).length;
  const base = partes.join("|");
  let p = String(palabra ?? "");
  while (p && bytes(base + "|" + p) > 64) p = p.slice(0, -1);
  return base + "|" + (p.length >= 3 ? p : "");
}

export function escaparHtml(t: unknown): string {
  return String(t ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// --- IA: validación de lo que responde Gemini (nunca se confía a ciegas) ---

export function palabraDelTexto(palabra: unknown, texto: string): string {
  const p = normalizar(palabra);
  return p.length >= 3 && !p.includes(" ") && ` ${normalizar(texto)} `.includes(` ${p} `) ? p : "";
}

export function validarSugerencia(r: any, concepto: string, categorias: Categoria[]) {
  if (!r || typeof r.categoria !== "string") return null;
  const cat = categorias.find((c) => c.nombre === r.categoria);
  if (!cat) return null;
  return { id_categoria: cat.id_categoria, nombre: cat.nombre, icono: cat.icono ?? null,
    palabra: palabraDelTexto(r.palabra_clave, concepto) };
}

export function validarInterpretacion(r: any, texto: string, categorias: Categoria[], montoMax: number, maxDias: number) {
  if (!r || r.entendido !== true) return null;
  const monto = Math.round(Number(r.monto) * 100) / 100;
  if (!(monto > 0) || monto > montoMax) return null;
  if (!["egreso", "ingreso"].includes(r.sentido) || !["efectivo", "yape"].includes(r.medio)) return null;
  const dias = Number(r.dias_atras);
  if (!Number.isInteger(dias) || dias < 0 || dias > maxDias) return null;
  const cat = categorias.find((c) => c.nombre === r.categoria && c.tipo === r.sentido);
  return { monto, sentido: r.sentido as Sentido, medio: r.medio as Medio, dias,
    id_categoria: cat ? cat.id_categoria : null, palabra: palabraDelTexto(r.palabra_clave, texto) };
}

/** Enmascara correos y números largos (celular, cuenta) antes de enviar a la IA. */
export function anonimizar(texto: string): string {
  return String(texto ?? "")
    .replace(/[\w.+-]+@[\w-]+\.[\w.]+/g, "[correo]")
    .replace(/\d[\d -]{5,}\d/g, "[número]")
    .slice(0, 300);
}

// --- Fechas en Lima (UTC-5 todo el año, sin horario de verano) ---

export function diaLima(fecha: Date | string = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Lima" }).format(new Date(fecha));
}

export function lunesLima(ahora = new Date()): string {
  const dia = diaLima(ahora);
  const dow = new Date(dia + "T12:00:00-05:00").getUTCDay();   // 0 domingo … 6 sábado
  const atras = (dow + 6) % 7;
  return diaLima(new Date(new Date(dia + "T12:00:00-05:00").getTime() - atras * 86400000));
}

export function fechaDias(dias: number | null | undefined): string {
  return new Date(Date.now() - (Number(dias) || 0) * 86400000).toISOString();
}
