#!/usr/bin/env bash
# Detiene el servidor OpenDesign (y opcionalmente FreeLLMAPI).
#
#   ./stop.sh              # sólo OpenDesign
#   ./stop.sh --all        # OpenDesign + FreeLLMAPI
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAMESPACE="${OD_NAMESPACE:-default}"

cd "$ROOT"
corepack pnpm tools-dev stop --namespace "$NAMESPACE" || true

if [ "${1:-}" = "--all" ]; then
  bash "$ROOT/deploy/catalina/freellmapi.sh" stop || true
fi

printf '\033[1m==>\033[0m OpenDesign detenido\n'
