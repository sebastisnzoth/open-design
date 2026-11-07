#!/usr/bin/env bash
# Estado del servidor OpenDesign expuesto a la LAN + FreeLLMAPI.
#
#   ./status.sh                 # usa OD_WEB_PORT / OD_DAEMON_PORT / FREELLMAPI_PORT
#   OD_WEB_PORT=3100 ./status.sh
#
# Sale con código 0 si web (local y LAN) y daemon responden; 1 si algo falta.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WEB_PORT="${OD_WEB_PORT:-3000}"
DAEMON_PORT="${OD_DAEMON_PORT:-7456}"
FREELM_PORT="${FREELLMAPI_PORT:-3001}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }

is_usable_ip() {
  case "$1" in ""|127.*|0.0.0.0|169.254.*) return 1 ;; esac
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

code_of() { curl -s -o /dev/null -m 8 -w '%{http_code}' "$1" 2>/dev/null || true; }

echo
echo "OpenDesign — estado"
if [ -n "${OD_LAN_IP:-}" ]; then LAN_IP="$OD_LAN_IP"; else LAN_IP="$(detect_lan_ip)"; fi
rc=0

web_local="$(code_of "http://127.0.0.1:$WEB_PORT/")"
if [ "$web_local" = "200" ]; then ok "web 127.0.0.1:$WEB_PORT (200)"; else bad "web 127.0.0.1:$WEB_PORT (${web_local:-sin respuesta})"; rc=1; fi

web_lan=""
if [ -n "${OD_LAN_IP:-}" ] || is_usable_ip "$LAN_IP"; then
  web_lan="$(code_of "http://$LAN_IP:$WEB_PORT/")"
  if [ "$web_lan" = "200" ]; then ok "web $LAN_IP:$WEB_PORT (LAN, 200)"; else bad "web $LAN_IP:$WEB_PORT (${web_lan:-sin respuesta})"; rc=1; fi
else
  info "sin IP de LAN usable (${LAN_IP:-ninguna}); exportá OD_LAN_IP para chequearla"
  rc=1
fi

api="$(code_of "http://127.0.0.1:$WEB_PORT/api/health")"
if [ "$api" = "200" ]; then ok "daemon vía web /api/health (200)"; else bad "daemon vía web /api/health (${api:-sin respuesta})"; rc=1; fi

daemon_direct="$(code_of "http://127.0.0.1:$DAEMON_PORT/api/health")"
if [ "$daemon_direct" = "200" ]; then ok "daemon directo 127.0.0.1:$DAEMON_PORT (sólo loopback)"; else info "daemon directo 127.0.0.1:$DAEMON_PORT: ${daemon_direct:-sin respuesta}"; fi

freellm="$(code_of "http://127.0.0.1:$FREELM_PORT/v1/models")"
case "$freellm" in
  200) ok "FreeLLMAPI /v1/models (200)";;
  401) ok "FreeLLMAPI escuchando (401 sin key: esperado)";;
  "")  info "FreeLLMAPI no está corriendo en 127.0.0.1:$FREELM_PORT (opcional)";;
  *)   info "FreeLLMAPI en 127.0.0.1:$FREELM_PORT: HTTP $freellm (opcional)";;
esac

echo
if [ "$web_lan" = "200" ]; then
  printf '  Cliente (Mac Catalina): \033[1mhttp://%s:%s\033[0m\n' "$LAN_IP" "$WEB_PORT"
elif [ "$web_local" = "200" ]; then
  printf '  Cliente: http://127.0.0.1:%s (sólo esta máquina)\n' "$WEB_PORT"
else
  printf '  Servidor abajo. Arrancalo: ./deploy/catalina/setup.sh\n'
fi
echo

[ "$rc" = "0" ]
