#!/usr/bin/env bash
# desplegar_bot.sh — prueba, despliega y verifica la Edge Function del bot de Telegram.
#
# Uso (desde la raíz del repo, p. ej. en GitHub Codespaces):
#   scripts/desplegar_bot.sh             → pruebas + despliegue + verificación
#   scripts/desplegar_bot.sh --pruebas   → solo pruebas (no toca Supabase)
#   scripts/desplegar_bot.sh --verificar → solo verificación (no despliega)
#
# Variables de entorno (en Codespaces: GitHub → Settings → Codespaces → Secrets):
#   SUPABASE_ACCESS_TOKEN  token personal de Supabase (la CLI lo lee sola; nunca en el código)
#   SUPABASE_PROJECT_REF   el "ref" del proyecto: https://<ref>.supabase.co
#   TELEGRAM_TOKEN         opcional: si está, se consulta getWebhookInfo al final
#
# Por qué un script: el orden importa (si una prueba falla, no se despliega) y así
# el despliegue es el mismo cada vez, sin depender de la memoria.
set -euo pipefail

FUNCION="telegram-webhook"
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RAIZ"
# Versión mayor fijada: la v3 cambió flags (--project-ref → --remote). Subirla a propósito, no por sorpresa.
SUPABASE="${SUPABASE_CLI:-npx --yes supabase@3}"

rojo()  { printf '\033[31m%s\033[0m\n' "$*"; }
verde() { printf '\033[32m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------
# 1. Pruebas de logica.ts (45 casos). Si fallan, se detiene aquí.
# ---------------------------------------------------------------------
pruebas() {
  local test="supabase/functions/$FUNCION/logica_test.ts"
  echo "▶ Pruebas: $test"
  if command -v deno >/dev/null 2>&1; then
    deno run "$test" 2>&1 | grep -v "^✅"
  else
    local mayor menor
    mayor="$(node -p 'process.versions.node.split(".")[0]')"
    menor="$(node -p 'process.versions.node.split(".")[1]')"
    if (( mayor > 22 || (mayor == 22 && menor >= 6) )); then
      node --experimental-strip-types --no-warnings "$test" 2>&1 | grep -v "^✅"
    else
      # Node < 22.6 no entiende TypeScript: tsx lo traduce al vuelo.
      npx --yes tsx "$test" 2>&1 | grep -v "^✅"
    fi
  fi
  verde "✔ Pruebas OK"
}

# ---------------------------------------------------------------------
# 2. Despliegue
# ---------------------------------------------------------------------
desplegar() {
  : "${SUPABASE_ACCESS_TOKEN:?Falta SUPABASE_ACCESS_TOKEN (ver docs/despliegue_bot.md, paso 1)}"
  : "${SUPABASE_PROJECT_REF:?Falta SUPABASE_PROJECT_REF (ver docs/despliegue_bot.md, paso 1)}"
  echo "▶ Desplegando $FUNCION en $SUPABASE_PROJECT_REF"
  # --no-verify-jwt: Telegram no envía JWT (también está en supabase/config.toml; doble seguro).
  # --use-api: Supabase empaqueta el código en su servidor; no hace falta Docker.
  # En tu terminal la CLI pide confirmar (cambia producción). En GitHub Actions (CI=true)
  # no hay quien confirme: ahí el permiso es haber pulsado "Run workflow".
  local confirmar=()
  [[ "${CI:-}" == "true" ]] && confirmar=(--yes)
  $SUPABASE functions deploy "$FUNCION" \
    --remote="$SUPABASE_PROJECT_REF" \
    --no-verify-jwt \
    --use-api "${confirmar[@]}"
  verde "✔ Desplegado"
}

# ---------------------------------------------------------------------
# 3. Verificación: la función responde y sigue protegida.
# ---------------------------------------------------------------------
verificar() {
  : "${SUPABASE_PROJECT_REF:?Falta SUPABASE_PROJECT_REF}"
  local url="https://$SUPABASE_PROJECT_REF.supabase.co/functions/v1/$FUNCION"
  local fallo=0 cuerpo

  # GET sin nada → nuestro código responde "ok". Si "Verify JWT" quedara activado,
  # el gateway respondería 401 antes de llegar al código: así lo detectamos.
  cuerpo="$(curl -s -w ' %{http_code}' "$url" || true)"
  if [[ "$cuerpo" == "ok 200" ]]; then verde "✔ GET → 200 ok (Verify JWT desactivado)"
  else rojo "✘ GET → $cuerpo  (¿Verify JWT activado? ¿error al arrancar? Revisa los Logs)"; fallo=1; fi

  # POST sin el secreto → 401 "no autorizado" de NUESTRO código (no del gateway).
  cuerpo="$(curl -s -w ' %{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "$url" || true)"
  if [[ "$cuerpo" == "no autorizado 401" ]]; then verde "✔ POST sin secreto → 401 (el secreto se sigue validando)"
  else rojo "✘ POST sin secreto → $cuerpo"; fallo=1; fi

  # Estado del webhook en Telegram (opcional). El token no se imprime.
  if [[ -n "${TELEGRAM_TOKEN:-}" ]]; then
    curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getWebhookInfo" | node -e '
      let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
        const r = JSON.parse(s).result ?? {};
        console.log("▶ Webhook:", (r.url ?? "").replace(/^https:\/\/[^.]+/, "https://<ref>"));
        console.log("  pendientes:", r.pending_update_count ?? "?");
        if (r.last_error_message) {
          const hace = Math.round(Date.now() / 1000 - r.last_error_date);
          console.log(`  último error (hace ${hace} s): ${r.last_error_message}`);
        } else console.log("  sin errores recientes");
      });'
  else
    echo "ℹ Sin TELEGRAM_TOKEN: omito getWebhookInfo. Prueba final: escribe /hoy al bot (no registra nada)."
  fi

  (( fallo == 0 )) && verde "✔ Verificación OK" || { rojo "✘ Verificación con fallos"; exit 1; }
}

case "${1:-}" in
  --pruebas)   pruebas ;;
  --verificar) verificar ;;
  "")          pruebas; desplegar; verificar ;;
  *)           echo "Uso: $0 [--pruebas | --verificar]"; exit 2 ;;
esac
