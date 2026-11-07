#!/usr/bin/env bash
# Estado del servidor OpenDesign expuesto a la LAN + FreeLLMAPI.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WEB_PORT="${OD_WEB_PORT:-3000}"
DAEMON_PORT="${OD_DAEMON_PORT:-7456}"
FREELM_PORT="${FREELLMAPI_PORT:-3001}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }

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

code_of() { curl -s -o /dev/null -m 8 -w '%{http_code}' "$1" 2>/dev/null || true; }

echo
echo "OpenDesign — estado"
LAN_IP="$(detect_lan_ip)"

web_local="$(code_of "http://127.0.0.1:$WEB_PORT/")"
if [ "$web_local" = "200" ]; then ok "web 127.0.0.1:$WEB_PORT (200)"; else bad "web 127.0.0.1:$WEB_PORT (${web_local:-sin respuesta})"; fi

web_lan=""
if [ -n "$LAN_IP" ]; then
  web_lan="$(code_of "http://$LAN_IP:$WEB_PORT/")"
  if [ "$web_lan" = "200" ]; then ok "web $LAN_IP:$WEB_PORT (LAN, 200)"; else bad "web $LAN_IP:$WEB_PORT (${web_lan:-sin respuesta})"; fi
else
  info "IP de LAN no detectada (exportá OD_LAN_IP para chequearla)"
fi

api="$(code_of "http://127.0.0.1:$WEB_PORT/api/health")"
body="$(curl -s -m 8 "http://127.0.0.1:$WEB_PORT/api/health" 2>/dev/null || true)"
if [ "$api" = "200" ]; then ok "daemon vía web /api/health (200)"; else bad "daemon vía web /api/health (${api:-sin respuesta})"; fi

daemon_direct="$(code_of "http://127.0.0.1:$DAEMON_PORT/api/health")"
if [ "$daemon_direct" = "200" ]; then ok "daemon directo 127.0.0.1:$DAEMON_PORT (sólo loopback)"; else info "daemon directo 127.0.0.1:$DAEMON_PORT: ${daemon_direct:-sin respuesta}"; fi

freellm="$(code_of "http://127.0.0.1:$FREELM_PORT/v1/models")"
case "$freellm" in
  200) ok "FreeLLMAPI /v1/models (200)";;
  401) ok "FreeLLMAPI escuchando (401: endpoint protegido, normal sin key)";;
  *)   info "FreeLLMAPI en 127.0.0.1:$FREELM_PORT: ${freellm:-sin respuesta} (opcional)";;
esac

echo
if [ -n "$LAN_IP" ] && [ "$web_lan" = "200" ]; then
  printf '  Cliente (Mac Catalina): \033[1mhttp://%s:%s\033[0m\n' "$LAN_IP" "$WEB_PORT"
else
  printf '  Cliente: http://127.0.0.1:%s (sólo esta máquina)\n' "$WEB_PORT"
fi
echo
