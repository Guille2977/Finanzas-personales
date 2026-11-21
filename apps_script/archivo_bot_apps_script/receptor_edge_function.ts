// Versión anterior de supabase/functions/telegram-webhook/index.ts (solo receptor que
// reenviaba a Apps Script). Se guarda para poder volver atrás. Secretos que usaba:
// TELEGRAM_SECRETO y APPS_SCRIPT_URL (los da datosWebhook() en Telegram.gs).
const SECRETO = Deno.env.get("TELEGRAM_SECRETO") ?? "";
const DESTINO = Deno.env.get("APPS_SCRIPT_URL") ?? "";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  if (!SECRETO || req.headers.get("x-telegram-bot-api-secret-token") !== SECRETO) {
    return new Response("no autorizado", { status: 401 });
  }
  const cuerpo = await req.text();
  const reenvio = fetch(DESTINO, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: cuerpo, redirect: "manual",
  })
    .then((r) => { if (r.status !== 200 && r.status !== 302) console.error("Apps Script respondió", r.status); })
    .catch((e) => console.error("No se pudo reenviar a Apps Script:", e.message));
  // @ts-ignore EdgeRuntime lo provee Supabase
  EdgeRuntime.waitUntil(reenvio);
  return new Response("ok");
});
