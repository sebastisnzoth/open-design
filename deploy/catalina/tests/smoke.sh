#!/usr/bin/env bash
# Pruebas de robustez del kit deploy/catalina.
#
#   ./tests/smoke.sh                # casos rápidos (sin red, sin compilar)
#   ./tests/smoke.sh --integration  # además: arranque real en puertos alternos
#
# No toca la instancia que esté corriendo en los puertos por defecto, salvo el
# caso "ya está sirviendo", que sólo la consulta.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$KIT/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'cleanup' EXIT INT TERM

PASS=0; FAILED=0; SKIPPED=0
pass() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { FAILED=$((FAILED+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
skip() { SKIPPED=$((SKIPPED+1)); printf '  \033[33mSKIP\033[0m %s\n' "$*"; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

PIDS=""
cleanup() {
  # -9: si el test muere por timeout, el trap igual tiene que liberar los puertos.
  for p in $PIDS; do kill -9 "$p" 2>/dev/null || true; done
  PIDS=""
  rm -rf "$TMP"
}

# listener PORT -> levanta un HTTP server de python para ocupar el puerto
listener() {
  ( cd "$TMP" && python3 -m http.server "$1" --bind 127.0.0.1 >/dev/null 2>&1 ) &
  PIDS="$PIDS $!"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
    sleep 0.3
  done
  return 1
}

# run_case NAME EXPECTED_RC -- comando...
run_case() {
  local name="$1" expected="$2"; shift 2
  [ "$1" = "--" ] && shift
  local out="$TMP/out.txt" rc=0 start=$SECONDS
  "$@" >"$out" 2>&1 || rc=$?
  local elapsed=$((SECONDS-start))
  if [ "$rc" = "$expected" ]; then
    pass "$name (rc=$rc, ${elapsed}s)"
  else
    fail "$name → esperaba rc=$expected, fue rc=$rc"
    sed -n '1,12p' "$out" | sed 's/^/       /'
  fi
  LAST_OUT="$out"; LAST_ELAPSED=$elapsed
}

assert_contains() {
  local name="$1" needle="$2"
  if grep -q -- "$needle" "$LAST_OUT" 2>/dev/null; then pass "$name"; else
    fail "$name → no encontré '$needle'"
    sed -n '1,12p' "$LAST_OUT" | sed 's/^/       /'
  fi
}

# ---------------------------------------------------------------- sintaxis
section "1. Sintaxis"
for f in setup.sh status.sh stop.sh freellmapi.sh; do
  if bash -n "$KIT/$f" 2>"$TMP/err"; then pass "bash -n $f"; else
    fail "bash -n $f"; cat "$TMP/err" | sed 's/^/       /'
  fi
done

# ---------------------------------------------------------------- CLI
section "2. Argumentos"
run_case "setup --help" 0 -- bash "$KIT/setup.sh" --help
run_case "setup --bogus" 2 -- bash "$KIT/setup.sh" --bogus
run_case "freellmapi subcomando inválido" 2 -- bash "$KIT/freellmapi.sh" nope

# ---------------------------------------------------------------- Node viejo
section "3. Preflight de Node"
if [ -x /usr/local/bin/node ]; then
  OLD_MAJOR="$(/usr/local/bin/node -p 'process.versions.node.split(".")[0]')"
  if [ "$OLD_MAJOR" -lt 24 ]; then
    PATH=/usr/local/bin:/usr/bin:/bin run_case "Node $OLD_MAJOR rechazado" 1 -- bash "$KIT/setup.sh"
    assert_contains "el mensaje explica qué hacer" "Necesitás Node 24"
  else
    skip "no hay un Node <24 en el sandbox para probar el rechazo"
  fi
else
  skip "no hay segundo Node para probar"
fi

# ---------------------------------------------------------------- puertos
section "4. Validación de puertos"
OD_WEB_PORT=abc run_case "puerto no numérico" 1 -- bash "$KIT/setup.sh"
OD_WEB_PORT=3990 OD_DAEMON_PORT=3990 run_case "web y daemon iguales" 1 -- bash "$KIT/setup.sh"

# ---------------------------------------------------------------- IP de LAN
section "5. IP de LAN"
AUTO_IP="$( cd "$ROOT" && PATH=/home/user/node24/bin:$PATH command -v ip >/dev/null && ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1 )"
case "$AUTO_IP" in
  ""|127.*|169.254.*)
    run_case "IP autodetectada inusable se rechaza" 1 -- bash "$KIT/setup.sh"
    assert_contains "sugiere fijar OD_LAN_IP" "OD_LAN_IP="
    ;;
  *) skip "la IP autodetectada ($AUTO_IP) es usable: no aplica el rechazo" ;;
esac

# ---------------------------------------------------------------- puertos ocupados
section "6. Puertos ocupados"
if listener 3997; then
  OD_LAN_IP=127.0.0.1 OD_WEB_PORT=3997 OD_DAEMON_PORT=3996 \
    run_case "web ocupado falla rápido" 1 -- bash "$KIT/setup.sh"
  assert_contains "dice qué puerto está ocupado" "3997"
  if [ "$LAST_ELAPSED" -le 20 ]; then pass "falla sin quedarse esperando (${LAST_ELAPSED}s)"; else fail "tardó ${LAST_ELAPSED}s en detectar el conflicto"; fi
else skip "no pude levantar el listener de prueba"; fi

if listener 3996; then
  OD_LAN_IP=127.0.0.1 OD_WEB_PORT=3995 OD_DAEMON_PORT=3996 \
    run_case "daemon ocupado falla rápido" 1 -- bash "$KIT/setup.sh"
  assert_contains "dice qué puerto está ocupado" "3996"
else skip "no pude levantar el listener de prueba"; fi

# ---------------------------------------------------------------- ya corriendo
section "7. Instancia ya corriendo"
if curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:3000/ 2>/dev/null | grep -q 200; then
  OD_LAN_IP=169.254.0.21 OD_WEB_PORT=3000 OD_DAEMON_PORT=7456 \
    run_case "setup idempotente sobre instancia viva" 0 -- bash "$KIT/setup.sh"
  assert_contains "avisa que ya está sirviendo" "ya está sirviendo"
  if [ "$LAST_ELAPSED" -le 20 ]; then pass "no reinicia ni recompila (${LAST_ELAPSED}s)"; else fail "tardó ${LAST_ELAPSED}s"; fi
else
  skip "no hay instancia en :3000 para probar la idempotencia"
fi

# ---------------------------------------------------------------- freellmapi: pid viejo
section "8. FreeLLMAPI: seguridad del pid"
DIR8="$TMP/fl8"; mkdir -p "$DIR8"
sleep 60 & VICTIM=$!; PIDS="$PIDS $VICTIM"
echo "$VICTIM" > "$DIR8/.freellmapi.pid"
FREELLMAPI_DIR="$DIR8" FREELLMAPI_PORT=3994 run_case "stop con pid ajeno" 0 -- bash "$KIT/freellmapi.sh" stop
if kill -0 "$VICTIM" 2>/dev/null; then pass "no mató el proceso ajeno"; else fail "mató un proceso que no era suyo"; fi
if [ -f "$DIR8/.freellmapi.pid" ]; then fail "dejó el pid file"; else pass "limpió el pid file"; fi

section "9. FreeLLMAPI: stop en frío"
run_case "stop sin nada corriendo" 0 -- bash "$KIT/freellmapi.sh" stop

section "10. FreeLLMAPI: puerto ocupado"
if listener 3012; then
  FREELLMAPI_DIR="$TMP/fl10" FREELLMAPI_PORT=3012 \
    run_case "start con puerto tomado" 1 -- bash "$KIT/freellmapi.sh" start
  assert_contains "explica que el puerto está ocupado" "3012"
else skip "no pude levantar el listener de prueba"; fi

# ---------------------------------------------------------------- integración
if [ "${1:-}" = "--integration" ]; then
  section "11. Arranque real en puertos alternos"
  # Dos instancias de Next en 4 GB se arrastran: exigimos que no haya otra viva.
  if curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:3000/ 2>/dev/null | grep -q 200; then
    skip "hay una instancia en :3000; corré ./stop.sh antes de --integration"
    section "Resumen"
    printf '  %d OK · %d fallas · %d omitidas\n' "$PASS" "$FAILED" "$SKIPPED"
    [ "$FAILED" -eq 0 ]
    exit $?
  fi
  OD_LAN_IP=127.0.0.1 OD_WEB_PORT=3993 OD_DAEMON_PORT=3992 OD_NAMESPACE=catalina-smoke \
    run_case "setup arranca y responde" 0 -- bash "$KIT/setup.sh"
  assert_contains "imprime la URL del cliente" "http://127.0.0.1:3993"
  OD_LAN_IP=127.0.0.1 OD_WEB_PORT=3993 OD_DAEMON_PORT=3992 OD_NAMESPACE=catalina-smoke \
    run_case "segunda corrida es idempotente" 0 -- bash "$KIT/setup.sh"
  assert_contains "avisa que ya está sirviendo" "ya está sirviendo"
  if [ "$LAST_ELAPSED" -le 20 ]; then pass "no recompila ni reinicia (${LAST_ELAPSED}s)"; else fail "tardó ${LAST_ELAPSED}s"; fi
  OD_NAMESPACE=catalina-smoke run_case "stop del namespace de prueba" 0 -- bash "$KIT/stop.sh"
  if (exec 3<>"/dev/tcp/127.0.0.1/3993") 2>/dev/null; then fail "el puerto 3993 sigue abierto"; else pass "liberó el puerto"; fi
fi

section "Resumen"
printf '  %d OK · %d fallas · %d omitidas\n' "$PASS" "$FAILED" "$SKIPPED"
[ "$FAILED" -eq 0 ]
