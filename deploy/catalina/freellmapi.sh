#!/usr/bin/env bash
# FreeLLMAPI en modo local (127.0.0.1) — gateway OpenAI-compatible para OpenDesign.
#
#   ./freellmapi.sh start|stop|restart|status|logs|key
#
# Usa Docker si el daemon está disponible; si no, checkout + Node en $FREELLMAPI_DIR.
#
# Variables:
#   FREELLMAPI_DIR   carpeta del checkout/estado (default ~/freellmapi)
#   FREELLMAPI_PORT  puerto local (default 3001)
#   FREELLMAPI_IMAGE imagen Docker (default ghcr.io/tashfeenahmed/freellmapi:latest)
set -euo pipefail

DIR="${FREELLMAPI_DIR:-$HOME/freellmapi}"
PORT="${FREELLMAPI_PORT:-3001}"
IMAGE="${FREELLMAPI_IMAGE:-ghcr.io/tashfeenahmed/freellmapi:latest}"
REPO_URL="${FREELLMAPI_REPO:-https://github.com/tashfeenahmed/freellmapi.git}"
PID_FILE="$DIR/.freellmapi.pid"
LOG_FILE="$DIR/freellmapi.log"
ENV_FILE="$DIR/.env"
HEALTH_PATH="/v1/models"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mAviso:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# 200 con key válida, 401 sin ella: en ambos casos el gateway está vivo.
is_up() {
  local code
  code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$PORT$HEALTH_PATH" 2>/dev/null || true)"
  [ "$code" = "200" ] || [ "$code" = "401" ]
}

docker_ready() { have docker && docker info >/dev/null 2>&1; }

docker_container_exists() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx freellmapi
}

# HOST es el bind del server; HOST_BIND sólo aplica al publicar el puerto en Docker.
ensure_env() {
  mkdir -p "$DIR"
  if [ ! -f "$ENV_FILE" ] || ! grep -q '^ENCRYPTION_KEY=' "$ENV_FILE" 2>/dev/null; then
    local key
    key="$(have node && node -e 'console.log(require("crypto").randomBytes(32).toString("hex"))' || openssl rand -hex 32)"
    { [ -f "$ENV_FILE" ] && cat "$ENV_FILE" || true; printf 'ENCRYPTION_KEY=%s\n' "$key"; } > "$ENV_FILE.new"
    mv "$ENV_FILE.new" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    say "Generé $ENV_FILE con una ENCRYPTION_KEY nueva"
  fi
  # Completamos claves que falten sin pisar las que el usuario haya cambiado.
  grep -q '^PORT='       "$ENV_FILE" || printf 'PORT=%s\n' "$PORT"        >> "$ENV_FILE"
  grep -q '^HOST='       "$ENV_FILE" || printf 'HOST=127.0.0.1\n'         >> "$ENV_FILE"
  grep -q '^HOST_BIND='  "$ENV_FILE" || printf 'HOST_BIND=127.0.0.1\n'    >> "$ENV_FILE"
}

cmd_start() {
  if is_up; then say "FreeLLMAPI ya está escuchando en 127.0.0.1:$PORT"; return 0; fi
  if port_open "$PORT"; then
    fail "El puerto $PORT está ocupado por otro proceso (no es FreeLLMAPI).
  Elegí otro: FREELLMAPI_PORT=3010 $0 start"
  fi

  ensure_env
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a

  if docker_ready; then
    say "Arrancando FreeLLMAPI con Docker ($IMAGE)"
    mkdir -p "$DIR/data"
    docker rm -f freellmapi >/dev/null 2>&1 || true
    if ! docker run -d --name freellmapi --restart unless-stopped \
        -p "127.0.0.1:$PORT:$PORT" \
        -e "ENCRYPTION_KEY=${ENCRYPTION_KEY:?ENCRYPTION_KEY vacía en $ENV_FILE}" \
        -e "PORT=$PORT" \
        -e "HOST=0.0.0.0" \
        -e "HOST_BIND=0.0.0.0" \
        -v "$DIR/data:/data" \
        "$IMAGE" >/dev/null; then
      fail "No pude levantar el contenedor. Probá: docker pull $IMAGE
  O usá la ruta Node: FREELLMAPI_NO_DOCKER=1 $0 start"
    fi
  else
    have docker && warn "Docker está instalado pero el daemon no responde: uso la ruta Node."
    have node || fail "Sin Docker usable y sin Node: instalá uno de los dos."
    local major; major="$(node -p 'process.versions.node.split(".")[0]')"
    [ "$major" -ge 20 ] || fail "FreeLLMAPI necesita Node 20+ (tenés $(node -v))."

    if [ ! -d "$DIR/.git" ]; then
      say "Clonando FreeLLMAPI en $DIR"
      # Clonamos a un temporal y copiamos: $DIR ya puede existir con el .env.
      local tmp; tmp="$(mktemp -d)"
      git clone --depth 1 "$REPO_URL" "$tmp/repo" >/dev/null || { rm -rf "$tmp"; fail "No pude clonar $REPO_URL"; }
      mkdir -p "$DIR"
      cp -a "$tmp/repo/." "$DIR/"
      rm -rf "$tmp"
    fi
    if [ ! -d "$DIR/node_modules" ]; then
      say "npm install"
      ( cd "$DIR" && npm install --no-audit --no-fund ) || fail "Falló 'npm install' en $DIR"
    fi
    if [ ! -f "$DIR/server/dist/index.js" ]; then
      say "npm run build"
      ( cd "$DIR" && npm run build ) || fail "Falló 'npm run build' en $DIR"
    fi

    say "Arrancando FreeLLMAPI (Node) en 127.0.0.1:$PORT"
    # exec hace que $! sea el pid real de node (no el de un subshell intermedio).
    ( cd "$DIR" && exec node server/dist/index.js </dev/null >>"$LOG_FILE" 2>&1 ) &
    echo $! > "$PID_FILE"
  fi

  local deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    is_up && { say "FreeLLMAPI listo → http://127.0.0.1:$PORT"; return 0; }
    sleep 2
  done
  echo "--- últimas líneas de $LOG_FILE" >&2
  tail -n 15 "$LOG_FILE" >&2 2>/dev/null || true
  docker_container_exists && docker logs --tail 15 freellmapi >&2 2>/dev/null || true
  if grep -q "better-sqlite3 is not installed" "$LOG_FILE" 2>/dev/null; then
    fail "FreeLLMAPI no pudo cargar better-sqlite3 (dependencia nativa opcional).
  Suele pasar si npm no logró bajar el prebuilt (sin red, proxy corporativo, arquitectura rara).
  Probá: (cd $DIR && npm install --force)   — o usá Docker: $0 start con Docker corriendo."
  fi
  fail "FreeLLMAPI no respondió en 60 s. Logs: $0 logs"
}

cmd_stop() {
  if docker_ready && docker_container_exists; then
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
  if is_up; then
    say "FreeLLMAPI arriba en http://127.0.0.1:$PORT"
    say "Dashboard: http://127.0.0.1:$PORT"
  else
    say "FreeLLMAPI abajo (arrancalo: $0 start)"
  fi
}

cmd_logs() {
  local lines="${1:-80}"
  if docker_ready && docker_container_exists; then
    docker logs --tail "$lines" -f freellmapi
  elif [ -f "$LOG_FILE" ]; then
    tail -n "$lines" -f "$LOG_FILE"
  else
    fail "No hay logs todavía en $LOG_FILE"
  fi
}

cmd_key() {
  say "Abrí http://127.0.0.1:$PORT → pestaña Keys → copiá la unified key (freellmapi-…)"
  [ -f "$ENV_FILE" ] && say "ENCRYPTION_KEY (no es la key de cliente) está en $ENV_FILE"
}

case "${1:-start}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_stop; cmd_start ;;
  status)  cmd_status ;;
  logs)    shift || true; cmd_logs "${1:-80}" ;;
  key)     cmd_key ;;
  *) echo "uso: $0 start|stop|restart|status|logs|key" >&2; exit 2 ;;
esac
