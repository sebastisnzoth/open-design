#!/usr/bin/env bash
# Detiene el servidor OpenDesign (y opcionalmente FreeLLMAPI).
#
#   ./stop.sh              # sólo OpenDesign
#   ./stop.sh --all        # OpenDesign + FreeLLMAPI
#
# Es seguro correrlo cuando no hay nada levantado.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAMESPACE="${OD_NAMESPACE:-default}"
cd "$ROOT"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

if command -v corepack >/dev/null 2>&1 && corepack pnpm --version >/dev/null 2>&1; then
  pnpm_run() { corepack pnpm "$@"; }
elif command -v pnpm >/dev/null 2>&1 && pnpm --version >/dev/null 2>&1; then
  pnpm_run() { pnpm "$@"; }
else
  pnpm_run() { return 1; }
fi

if ! pnpm_run tools-dev stop --namespace "$NAMESPACE" 2>/dev/null; then
  # Sin tools-dev usable: al menos avisamos si quedó algo escuchando.
  for port in "${OD_WEB_PORT:-3000}" "${OD_DAEMON_PORT:-7456}"; do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      printf '\033[33mAviso:\033[0m el puerto %s sigue ocupado (no pude invocar tools-dev).\n' "$port" >&2
    fi
  done
fi

if [ "${1:-}" = "--all" ]; then
  bash "$ROOT/deploy/catalina/freellmapi.sh" stop || true
fi

say "OpenDesign detenido"
