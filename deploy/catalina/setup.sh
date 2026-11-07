#!/usr/bin/env bash
# OpenDesign como servidor para un Mac con macOS Catalina.
#
# Levanta daemon + web escuchando en la LAN (para que el Mac viejo use la UI en
# Chrome 128 / Safari 15.6) y prepara FreeLLMAPI en modo local si se lo pedís.
#
# Uso:
#   ./setup.sh                 # arranca OpenDesign en la LAN (puertos 7456/3000)
#   ./setup.sh --with-freellmapi
#   OD_WEB_PORT=3100 ./setup.sh
#
# Variables:
#   OD_LAN_IP    IP a publicar (por defecto se autodetecta)
#   OD_WEB_PORT  puerto web (default 3000)
#   OD_DAEMON_PORT puerto daemon, queda en loopback (default 7456)
#   OD_NAMESPACE namespace de tools-dev (default default)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

WEB_PORT="${OD_WEB_PORT:-3000}"
DAEMON_PORT="${OD_DAEMON_PORT:-7456}"
NAMESPACE="${OD_NAMESPACE:-default}"
WITH_FREELLMAPI=0

for arg in "$@"; do
  case "$arg" in
    --with-freellmapi) WITH_FREELLMAPI=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "argumento desconocido: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- prerequisitos
say "Verificando Node.js"
command -v node >/dev/null 2>&1 || fail "Node.js no está instalado. Necesitás Node 24 (nvm install 24)."
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 24 ]; then
  fail "Necesitás Node 24 (tenés $(node -v)). tools-dev se niega a arrancar con menos.
  nvm install 24 && nvm use 24
  "${PNPM[@]}" install --frozen-lockfile
  corepack pnpm --filter @open-design/daemon rebuild better-sqlite3 --pending"
fi

say "Preparando pnpm"
# corepack elige pnpm 10.33.2 por packageManager; si no está, se usa el pnpm del PATH.
if command -v corepack >/dev/null 2>&1 && corepack pnpm --version >/dev/null 2>&1; then
  PNPM=(corepack pnpm)
elif command -v pnpm >/dev/null 2>&1; then
  PNPM=(pnpm)
else
  fail "No hay corepack ni pnpm. Instalá Node 24 (que trae corepack) o 'npm i -g pnpm@10.33.2'."
fi
say "pnpm: $("${PNPM[@]}" --version)"

# ------------------------------------------------------------------- dependencias
if [ ! -d node_modules ] || [ ! -x node_modules/.bin/tsx ]; then
  say "Instalando dependencias (pnpm install)"
  "${PNPM[@]}" install --frozen-lockfile
fi

if [ ! -d tools/dev/dist ] || [ ! -d apps/daemon/dist ]; then
  say "Compilando packages/ y apps/ (pnpm bootstrap)"
  "${PNPM[@]}" bootstrap
fi

# --------------------------------------------------------------------- IP de LAN
detect_lan_ip() {
  if [ -n "${OD_LAN_IP:-}" ]; then printf '%s' "$OD_LAN_IP"; return; fi
  local ip=""
  if command -v ipconfig >/dev/null 2>&1; then
    for iface in en0 en1 en2; do
      ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
      [ -n "$ip" ] && { printf '%s' "$ip"; return; }
    done
  fi
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
  fi
  printf '%s' "$ip"
}

LAN_IP="$(detect_lan_ip)"
[ -n "$LAN_IP" ] || fail "No pude detectar la IP de LAN. Exportá OD_LAN_IP=192.168.x.x y reintentá."

WEB_URL="http://$LAN_IP:$WEB_PORT"
say "IP de LAN detectada: $LAN_IP"

# ------------------------------------------------------------------- FreeLLMAPI
if [ "$WITH_FREELLMAPI" = "1" ]; then
  say "Preparando FreeLLMAPI (modo local, 127.0.0.1:3001)"
  bash "$ROOT/deploy/catalina/freellmapi.sh" start || fail "FreeLLMAPI no arrancó (ver deploy/catalina/freellmapi.sh logs)."
fi

# ------------------------------------------------------------------ OpenDesign
say "Arrancando OpenDesign (web en 0.0.0.0:$WEB_PORT, daemon en 127.0.0.1:$DAEMON_PORT)"

# OD_HOST mueve el listener del sidecar web fuera de loopback
# (apps/web/sidecar/server.ts). OD_ALLOWED_ORIGINS/OD_ALLOWED_DEV_ORIGINS llenan
# allowedDevOrigins en apps/web/next.config.ts: sin esto Next bloquea los
# assets /_next/* pedidos desde otra máquina y la UI queda en blanco.
export OD_HOST=0.0.0.0
# Turbopack: el bundler webpack por defecto tarda minutos y puede quedarse sin
# memoria en máquinas chicas (2 vCPU / 4 GB). Turbopack compila en ~25 s.
export OD_WEB_DEV_BUNDLER="${OD_WEB_DEV_BUNDLER:-turbopack}"
export OD_ALLOWED_ORIGINS="http://$LAN_IP:$WEB_PORT,http://$LAN_IP"
export OD_ALLOWED_DEV_ORIGINS="$LAN_IP,http://$LAN_IP:$WEB_PORT"

"${PNPM[@]}" tools-dev start web \
  --namespace "$NAMESPACE" \
  --daemon-port "$DAEMON_PORT" \
  --web-port "$WEB_PORT" >/dev/null

say "Esperando a que el web responda (primer arranque compila; puede tardar ~1 min)"
code=""
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$WEB_PORT/" || true)"
  [ "$code" = "200" ] && break
  sleep 3
done
[ "$code" = "200" ] || fail "El web no respondió en 180s. Revisá: corepack pnpm tools-dev logs web"

bash "$ROOT/deploy/catalina/status.sh" || true

cat <<EOF

────────────────────────────────────────────────────────────
  En el Mac con Catalina (Chrome 128 o Safari 15.6):

      $WEB_URL

  En esta máquina:
      http://127.0.0.1:$WEB_PORT

  BYOK → FreeLLMAPI:
      Ajustes → Ejecución → API → OpenAI
      Base URL: http://127.0.0.1:3001/v1   (o la IP de esta máquina)
      Modelo:   auto

  Parar:  ./deploy/catalina/stop.sh
────────────────────────────────────────────────────────────
EOF
