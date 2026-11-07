#!/usr/bin/env bash
# OpenDesign como servidor para un Mac con macOS Catalina.
#
# Levanta daemon + web escuchando en la LAN (para que el Mac viejo use la UI en
# Chrome 128 / Safari 15.6) y prepara FreeLLMAPI en modo local si se lo pedís.
#
# Uso:
#   ./setup.sh                      # arranca OpenDesign en la LAN (web 3000 / daemon 7456)
#   ./setup.sh --with-freellmapi    # además levanta el gateway local en 127.0.0.1:3001
#   ./setup.sh --restart            # reinicia aunque ya esté corriendo
#   OD_WEB_PORT=3100 ./setup.sh
#
# Variables:
#   OD_LAN_IP       IP a publicar (por defecto se autodetecta y se valida)
#   OD_WEB_PORT     puerto web, se expone en la LAN (default 3000)
#   OD_DAEMON_PORT  puerto del daemon, queda en loopback (default 7456)
#   OD_NAMESPACE    namespace de tools-dev (default default)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

WEB_PORT="${OD_WEB_PORT:-3000}"
DAEMON_PORT="${OD_DAEMON_PORT:-7456}"
NAMESPACE="${OD_NAMESPACE:-default}"
WITH_FREELLMAPI=0
FORCE_RESTART=0

for arg in "$@"; do
  case "$arg" in
    --with-freellmapi) WITH_FREELLMAPI=1 ;;
    --restart) FORCE_RESTART=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "argumento desconocido: $arg (usá --help)" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mAviso:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

case "$WEB_PORT$DAEMON_PORT" in
  *[!0-9]*) fail "Los puertos deben ser numéricos (web=$WEB_PORT daemon=$DAEMON_PORT)." ;;
esac
[ "$WEB_PORT" != "$DAEMON_PORT" ] || fail "OD_WEB_PORT y OD_DAEMON_PORT no pueden ser iguales ($WEB_PORT)."

# ------------------------------------------------------------------ preflight
say "Verificando Node.js"
command -v node >/dev/null 2>&1 || fail "Node.js no está instalado. Necesitás Node 24 (nvm install 24)."
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 24 ]; then
  fail "Necesitás Node 24 (tenés $(node -v)). tools-dev se niega a arrancar con menos.
  nvm install 24 && nvm use 24
  pnpm install --frozen-lockfile
  pnpm --filter @open-design/daemon rebuild better-sqlite3 --pending"
fi

say "Preparando pnpm"
# corepack elige pnpm 10.33.2 según packageManager; si no está, se usa el pnpm del PATH.
# (Sin arrays: macOS trae bash 3.2 y ahí '${arr[@]}' con 'set -u' es frágil.)
if command -v corepack >/dev/null 2>&1 && corepack pnpm --version >/dev/null 2>&1; then
  pnpm_run() { corepack pnpm "$@"; }
elif command -v pnpm >/dev/null 2>&1 && pnpm --version >/dev/null 2>&1; then
  pnpm_run() { pnpm "$@"; }
else
  fail "No hay corepack ni pnpm usable. Instalá Node 24 (trae corepack) o 'npm i -g pnpm@10.33.2'."
fi
say "pnpm $(pnpm_run --version)"

# ---------------------------------------------------------------- dependencias
if [ ! -d node_modules ] || [ ! -x node_modules/.bin/tsx ]; then
  say "Instalando dependencias (pnpm install --frozen-lockfile)"
  pnpm_run install --frozen-lockfile || fail "Falló 'pnpm install'. Si el problema es una descarga bloqueada, reintentá con red disponible."
fi

if [ ! -d tools/dev/dist ] || [ ! -d apps/daemon/dist ]; then
  say "Compilando packages/ y apps/ (pnpm bootstrap)"
  pnpm_run bootstrap || fail "Falló 'pnpm bootstrap' (arriba está el detalle)."
fi

# better-sqlite3 es nativo: si node_modules se instaló con otro Node, el ABI no
# coincide y el daemon no arranca. Sólo se resuelve desde apps/daemon (layout pnpm)
# y el binding se carga al instanciar, no al requerir.
abi_probe() {
  ( cd "$ROOT/apps/daemon" && node -e 'require("better-sqlite3")(":memory:").close()' 2>&1 )
}
probe="$(abi_probe || true)"
if printf '%s' "$probe" | grep -q "NODE_MODULE_VERSION"; then
  say "better-sqlite3 está compilado para otro Node: reconstruyendo (necesita red + Xcode CLT en macOS)"
  pnpm_run --filter @open-design/daemon rebuild better-sqlite3 --pending >/dev/null 2>&1 || true
  probe="$(abi_probe || true)"
  if printf '%s' "$probe" | grep -q "NODE_MODULE_VERSION"; then
    fail "better-sqlite3 sigue compilado para otro Node.
  En macOS necesitás Xcode Command Line Tools: xcode-select --install
  Después: pnpm install --frozen-lockfile && pnpm --filter @open-design/daemon rebuild better-sqlite3 --pending"
  fi
elif [ -n "$probe" ]; then
  # Otra cosa (p. ej. el módulo no está linkeado): no abortamos, tools-dev lo
  # reporta con su propio diagnóstico si realmente impide arrancar.
  warn "No pude validar better-sqlite3: $(printf '%s' "$probe" | head -1)"
fi

# --------------------------------------------------------------------- IP LAN
is_usable_ip() {
  case "$1" in
    ""|127.*|0.0.0.0|169.254.*) return 1 ;;
  esac
  return 0
}

detect_lan_ip() {
  local ip=""
  if command -v ipconfig >/dev/null 2>&1; then
    for iface in en0 en1 en2; do
      ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
      is_usable_ip "$ip" && { printf '%s' "$ip"; return; }
    done
  fi
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
    is_usable_ip "$ip" && { printf '%s' "$ip"; return; }
    ip="$(ip -4 -o addr show scope global 2>/dev/null | sed -n 's/.* inet \([0-9.]*\).*/\1/p' | head -1)"
  fi
  printf '%s' "$ip"
}

# Si el usuario pasa OD_LAN_IP, se respeta tal cual; sólo validamos lo autodetectado.
if [ -n "${OD_LAN_IP:-}" ]; then
  LAN_IP="$OD_LAN_IP"
else
  LAN_IP="$(detect_lan_ip)"
fi
if [ -z "${OD_LAN_IP:-}" ] && ! is_usable_ip "$LAN_IP"; then
  fail "No encontré una IP de LAN usable (detecté: '${LAN_IP:-ninguna}').
  - Si estás en Wi-Fi, revisá que no sea una red sin DHCP (169.254.x).
  - Forzala a mano: OD_LAN_IP=192.168.0.42 $0"
fi
say "IP de LAN: $LAN_IP"

# ----------------------------------------------------------------- FreeLLMAPI
if [ "$WITH_FREELLMAPI" = "1" ]; then
  say "Preparando FreeLLMAPI (modo local, 127.0.0.1:3001)"
  bash "$ROOT/deploy/catalina/freellmapi.sh" start \
    || fail "FreeLLMAPI no arrancó. Ver: ./deploy/catalina/freellmapi.sh logs"
fi

# -------------------------------------------------------------------- puertos
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

web_status() { curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$WEB_PORT/" 2>/dev/null || true; }
# Huella de OpenDesign: un simple 200 no alcanza, cualquier servidor puede darlo.
od_health() { curl -s -m 3 "http://$1:$WEB_PORT/api/health" 2>/dev/null | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; }

if [ "$FORCE_RESTART" = "0" ] && od_health "127.0.0.1"; then
  if od_health "$LAN_IP"; then
    say "OpenDesign ya está sirviendo en http://$LAN_IP:$WEB_PORT"
    bash "$ROOT/deploy/catalina/status.sh" || true
    exit 0
  fi
  warn "Hay un OpenDesign escuchando en 127.0.0.1:$WEB_PORT pero no en la LAN: lo reinicio con OD_HOST=0.0.0.0."
  FORCE_RESTART=1
fi

if [ "$FORCE_RESTART" = "1" ]; then
  pnpm_run tools-dev stop --namespace "$NAMESPACE" >/dev/null 2>&1 || true
  sleep 1
fi

if port_open "$WEB_PORT"; then
  fail "El puerto $WEB_PORT está ocupado por otro proceso. Elegí otro: OD_WEB_PORT=3100 $0"
fi
if port_open "$DAEMON_PORT"; then
  fail "El puerto $DAEMON_PORT está ocupado por otro proceso. Elegí otro: OD_DAEMON_PORT=7457 $0"
fi

# ------------------------------------------------------------------ arranque
say "Arrancando OpenDesign (web en 0.0.0.0:$WEB_PORT, daemon en 127.0.0.1:$DAEMON_PORT)"

# OD_HOST saca el listener del sidecar web de loopback (apps/web/sidecar/server.ts).
# OD_ALLOWED_ORIGINS/OD_ALLOWED_DEV_ORIGINS llenan allowedDevOrigins
# (apps/web/next.config.ts): sin esto Next bloquea los assets /_next/* pedidos
# desde otra máquina y la UI queda en blanco.
export OD_HOST=0.0.0.0
export OD_ALLOWED_ORIGINS="http://$LAN_IP:$WEB_PORT,http://$LAN_IP"
export OD_ALLOWED_DEV_ORIGINS="$LAN_IP,http://$LAN_IP:$WEB_PORT"
# Turbopack: el webpack por defecto tarda minutos y puede quedarse sin memoria
# en máquinas chicas (2 vCPU / 4 GB). Turbopack compila en ~25 s.
export OD_WEB_DEV_BUNDLER="${OD_WEB_DEV_BUNDLER:-turbopack}"

start_log="$(mktemp "${TMPDIR:-/tmp}/od-setup.XXXXXX")"
if ! pnpm_run tools-dev start web --namespace "$NAMESPACE" \
      --daemon-port "$DAEMON_PORT" --web-port "$WEB_PORT" >"$start_log" 2>&1; then
  echo "--- salida de tools-dev" >&2
  tail -n 20 "$start_log" >&2
  rm -f "$start_log"
  fail "tools-dev no pudo arrancar el web (detalle arriba)."
fi
rm -f "$start_log"

say "Esperando el primer 200 (compila la primera vez; ~25 s)"
code=""
deadline=$((SECONDS + 180))
while [ "$SECONDS" -lt "$deadline" ]; do
  code="$(web_status)"
  [ "$code" = "200" ] && break
  sleep 3
done
if [ "$code" != "200" ]; then
  echo "--- últimas líneas del log web" >&2
  tail -n 20 ".tmp/tools-dev/$NAMESPACE/logs/web/latest.log" >&2 2>/dev/null || true
  fail "El web no respondió en 180 s. Logs: pnpm tools-dev logs web --namespace $NAMESPACE"
fi

bash "$ROOT/deploy/catalina/status.sh" || true

cat <<EOF

────────────────────────────────────────────────────────────
  En el Mac con Catalina (Chrome 128 o Safari 15.6):

      http://$LAN_IP:$WEB_PORT

  En esta máquina:
      http://127.0.0.1:$WEB_PORT

  BYOK → FreeLLMAPI:
      Ajustes → Ejecución → API → OpenAI
      Base URL: http://127.0.0.1:3001/v1   (o la IP de esta máquina)
      Modelo:   auto

  Parar:  ./deploy/catalina/stop.sh
────────────────────────────────────────────────────────────
EOF
