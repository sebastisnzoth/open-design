#!/usr/bin/env bash
# FreeLLMAPI en modo local (127.0.0.1) — gateway OpenAI-compatible para OpenDesign.
#
#   ./freellmapi.sh start|stop|status|logs|key
#
# Preferencias: Docker si está disponible; si no, checkout en ~/freellmapi con Node.
#
# Variables:
#   FREELLMAPI_DIR  carpeta del checkout/estado (default ~/freellmapi)
#   FREELLMAPI_PORT puerto local (default 3001)
#   FREELLMAPI_IMAGE imagen Docker (default ghcr.io/tashfeenahmed/freellmapi:latest)
set -euo pipefail

DIR="${FREELLMAPI_DIR:-$HOME/freellmapi}"
PORT="${FREELLMAPI_PORT:-3001}"
IMAGE="${FREELLMAPI_IMAGE:-ghcr.io/tashfeenahmed/freellmapi:latest}"
REPO_URL="${FREELLMAPI_REPO:-https://github.com/tashfeenahmed/freellmapi.git}"
PID_FILE="$DIR/.freellmapi.pid"
LOG_FILE="$DIR/freellmapi.log"
ENV_FILE="$DIR/.env"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

has_docker() { have docker && docker info >/dev/null 2>&1; }

ensure_encryption_key() {
  mkdir -p "$DIR"
  # HOST es el bind del servidor; HOST_BIND sólo aplica al publicar el puerto Docker.
  if [ ! -f "$ENV_FILE" ] || ! grep -q '^ENCRYPTION_KEY=' "$ENV_FILE" 2>/dev/null; then
    local key
    key="$(have node && node -e 'console.log(require("crypto").randomBytes(32).toString("hex"))' || openssl rand -hex 32)"
    {
      [ -f "$ENV_FILE" ] && cat "$ENV_FILE"
      printf 'ENCRYPTION_KEY=%s\nPORT=%s\nHOST=127.0.0.1\nHOST_BIND=127.0.0.1\n' "$key" "$PORT"
    } > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    say "Generé $ENV_FILE (ENCRYPTION_KEY nueva; bind local 127.0.0.1)"
  fi
}

is_up() {
  local code
  code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$PORT/v1/models" 2>/dev/null || true)"
  [ "$code" = "200" ] || [ "$code" = "401" ]
}

cmd_start() {
  if is_up; then say "FreeLLMAPI ya está escuchando en 127.0.0.1:$PORT"; return 0; fi
  ensure_encryption_key
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a

  if has_docker; then
    say "Arrancando FreeLLMAPI con Docker ($IMAGE)"
    docker rm -f freellmapi >/dev/null 2>&1 || true
    docker run -d --name freellmapi --restart unless-stopped \
      -p "127.0.0.1:$PORT:$PORT" \
      -e "ENCRYPTION_KEY=$ENCRYPTION_KEY" \
      -e "PORT=$PORT" \
      -e "HOST=0.0.0.0" \
      -e "HOST_BIND=0.0.0.0" \
      -v "$DIR/data:/data" \
      "$IMAGE" >/dev/null
  else
    have node || fail "Sin Docker y sin Node: instalá uno de los dos."
    local major; major="$(node -p 'process.versions.node.split(".")[0]')"
    [ "$major" -ge 20 ] || fail "FreeLLMAPI necesita Node 20+ (tenés $(node -v))."
    if [ ! -d "$DIR/.git" ]; then
      say "Clonando FreeLLMAPI en $DIR"
      # Clonamos a un temporal y copiamos: así no rompe si $DIR ya existe
      # (por ejemplo porque ensure_encryption_key dejó el .env ahí).
      tmp="$(mktemp -d)"
      git clone --depth 1 "$REPO_URL" "$tmp/repo" >/dev/null
      mkdir -p "$DIR"
      cp -a "$tmp/repo/." "$DIR/"
      rm -rf "$tmp"
    fi
    if [ ! -d "$DIR/node_modules" ]; then
      say "npm install"
      ( cd "$DIR" && npm install --no-audit --no-fund )
    fi
    if [ ! -f "$DIR/server/dist/index.js" ]; then
      say "npm run build"
      ( cd "$DIR" && npm run build )
    fi
    say "Arrancando FreeLLMAPI (Node) en 127.0.0.1:$PORT"
    # exec hace que $! sea el pid real de node (no el de un subshell intermedio).
    ( cd "$DIR" && exec node server/dist/index.js </dev/null >>"$LOG_FILE" 2>&1 ) &
    echo $! >"$PID_FILE"
  fi

  local deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    is_up && { say "FreeLLMAPI listo → http://127.0.0.1:$PORT"; return 0; }
    sleep 2
  done
  echo "--- últimas líneas de $LOG_FILE" >&2
  tail -n 15 "$LOG_FILE" >&2 2>/dev/null || true
  fail "FreeLLMAPI no respondió en 60s. Logs: ./deploy/catalina/freellmapi.sh logs"
}

cmd_stop() {
  if has_docker && docker ps -a --format '{{.Names}}' | grep -qx freellmapi; then
    say "Deteniendo contenedor freellmapi"
    docker rm -f freellmapi >/dev/null 2>&1 || true
  fi
  if [ -f "$PID_FILE" ]; then
    local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    # Nunca matamos un pid reciclado: verificamos que siga siendo nuestro node.
    if [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -q "server/dist/index.js"; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
  # El patrón con [.] evita que pkill se matchee a sí mismo.
  if is_up; then
    pkill -f "server/dist/index[.]js" 2>/dev/null || true
  fi
  say "FreeLLMAPI detenido"
}

cmd_status() {
  if is_up; then say "FreeLLMAPI arriba en http://127.0.0.1:$PORT"; else say "FreeLLMAPI abajo"; fi
  say "Dashboard: http://127.0.0.1:$PORT"
}

cmd_logs() {
  if has_docker && docker ps -a --format '{{.Names}}' | grep -qx freellmapi; then
    docker logs --tail "${2:-80}" -f freellmapi
  else
    tail -n "${2:-80}" -f "$LOG_FILE" 2>/dev/null || fail "No hay logs en $LOG_FILE"
  fi
}

cmd_key() {
  # La unified key la emite el dashboard; el .env sólo guarda la ENCRYPTION_KEY.
  say "Abrí http://127.0.0.1:$PORT → pestaña Keys → copiá la unified key (freellmapi-…)"
  [ -f "$ENV_FILE" ] && say "ENCRYPTION_KEY guardada en $ENV_FILE (no es la key de cliente)"
}

case "${1:-start}" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  logs)   cmd_logs "$@" ;;
  key)    cmd_key ;;
  *) echo "uso: $0 start|stop|status|logs|key" >&2; exit 2 ;;
esac
