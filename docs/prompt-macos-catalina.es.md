# Prompt: instalar OpenDesign en una Mac (incluye Catalina)

Prompt listo para pegar en un agente de terminal (Claude Code, Codex, etc.) que corra **en la
Mac del usuario**. Importa el repo como primer paso y después elige la ruta según el macOS.

**Cómo usarlo:** copiá el bloque completo y pegálo como primer mensaje del agente. Reemplazá
nada más; las rutas y el remoto ya están fijados.

> Contexto técnico que el prompt ya asume (ver [`levantar-en-mac.es.md`](levantar-en-mac.es.md)
> y [`macos-catalina-freellmapi.es.md`](macos-catalina-freellmapi.es.md)): Electron 41 exige
> macOS 12+, Node 24 exige macOS 13.5+, y en Catalina el único navegador viable es Chrome 128.

---

```text
Rol: sos un agente de terminal en una Mac. Objetivo: importar el repo OpenDesign
y dejar la app funcionando en esta máquina o accesible desde ella.
Trabajá por fases. En cada una: mostrá el comando, mostrá la salida, y recién
entonces seguí. No inventes rutas ni versiones: verificalas en la máquina.

════════ FASE 0 — RADIOGRAFÍA (no cambia nada) ════════
  sw_vers -productVersion
  uname -m
  xcode-select -p 2>/dev/null || echo "sin CLT"
  node -v 2>/dev/null || echo "sin node"
  git --version 2>/dev/null || echo "sin git"
  df -h "$HOME" | tail -1          # espacio libre: el build necesita ~3 GB

  Reglas duras del proyecto (no las discutas, están en el repo):
  - Electron 41 (app de escritorio) exige macOS 12+.
  - Node 24 (daemon/web/build) exige macOS 13.5+ en binarios oficiales.
  - Chrome 128 es el último navegador que corre en Catalina (10.15).

  Decisión, según sw_vers:
  - >= 13.5        -> FASE 3 (nativo, preferida)
  - 11 .. 13.4     -> FASE 2 (actualizar) o FASE 1 (servidor remoto)
  - 10.15 Catalina -> FASE 1 (cliente web con servidor en otra máquina)
                      o FASE 2 (actualizar / OpenCore Legacy Patcher).
                      En Catalina NO se compila ni se ejecuta el stack.

════════ FASE 1 — IMPORTAR EL REPO (siempre, en la máquina que vaya a servirlo) ════════
  DESTINO="$HOME/Developer/open-design"
  URL="https://github.com/sebastisnzoth/open-design.git"

  # ¿git disponible? En macOS viene con las Command Line Tools:
  #   xcode-select --install    (si falta git)
  mkdir -p "$(dirname "$DESTINO")"

  # Import idempotente: clonar si no existe, actualizar si existe.
  if [ -d "$DESTINO/.git" ]; then
    git -C "$DESTINO" fetch --all --prune
    git -C "$DESTINO" checkout main
    git -C "$DESTINO" pull --ff-only
  else
    git clone "$URL" "$DESTINO"
  fi

  # Verificación obligatoria del import:
  git -C "$DESTINO" remote -v                     # origin -> github.com/sebastisnzoth/open-design
  git -C "$DESTINO" rev-parse --abbrev-ref HEAD   # debe decir: main
  git -C "$DESTINO" log -1 --oneline              # mostrá el hash al usuario
  ls "$DESTINO"/docs/levantar-en-mac.es.md \
     "$DESTINO"/deploy/catalina/setup.sh          # tienen que existir

  Si el clone falla: probá con GIT_TERMINAL_PROMPT=0, revisá proxy/TLS y, si el
  usuario no tiene git, instalá las CLT antes de seguir.
  No pases a la fase siguiente sin esas verificaciones.

  Leé, antes de improvisar:
    docs/levantar-en-mac.es.md            (levantar en Mac, macOS 13.5+)
    docs/macos-catalina-freellmapi.es.md  (Catalina + FreeLLMAPI)
    deploy/catalina/README.es.md          (kit servidor LAN)

════════ FASE 2 — Catalina: servidor en otra máquina (o actualizar) ════════
  Opción 2A (servidor remoto, en una máquina Linux/macOS 13.5+ de la red):
    cd "$DESTINO"
    corepack enable && corepack pnpm --version       # 10.33.2
    pnpm install --frozen-lockfile
    pnpm bootstrap
    ./deploy/catalina/setup.sh                       # detecta IP y expone el web en LAN
    ./deploy/catalina/status.sh                      # imprime la URL para el Mac
    En el Mac con Catalina: instalar Chrome 128 y abrir esa URL.
  Opción 2B (actualizar): Ajustes > Actualización de software; si el Mac es
    2012-2015, OpenCore Legacy Patcher (https://dortania.github.io/OpenCore-Legacy-Patcher/).
    Después, FASE 3.

════════ FASE 3 — nativo en macOS 13.5+ ════════
    cd "$DESTINO"
    xcode-select --install                # si ya está, lo informa y no hace nada
    nvm install 24 || brew install node@24 || mise install
    node -v                               # v24.x
    corepack enable && corepack pnpm --version       # 10.33.2
    pnpm install --frozen-lockfile
    pnpm bootstrap
    pnpm tools-dev start web --web-port 3000 --daemon-port 7456
  Abrí la URL que imprime. Sin flags, tools-dev elige puertos libres al azar:
  consultá "pnpm tools-dev status".
  Macs de 4 GB: anteponer OD_WEB_DEV_BUNDLER=turbopack.

════════ FASE 4 — modelo (BYOK), necesario para correr diseños ════════
    ./deploy/catalina/freellmapi.sh start     # gateway local 127.0.0.1:3001
    ./deploy/catalina/freellmapi.sh key       # dashboard: copiar la unified key
  En la app: Ajustes > Ejecución > API > OpenAI
    Base URL: http://127.0.0.1:3001/v1
    API key:  freellmapi-...
    Modelo:   auto

════════ ERRORES CONOCIDOS ════════
  - "tools-dev must run with Node ~24" -> nvm use 24 && pnpm install --frozen-lockfile
  - "NODE_MODULE_VERSION ... requires ..." -> pnpm --filter @open-design/daemon rebuild better-sqlite3 --pending
  - "TypeError: Invalid URL" (origin-validation.ts) -> OD_ALLOWED_ORIGINS sólo acepta
    URLs completas; los comodines van en OD_ALLOWED_DEV_ORIGINS
  - "xcode-select: error" -> xcode-select --install y reintentar
  - "unable to verify the first certificate" -> proxy/TLS: pnpm install --ignore-scripts
    y después reconstruir better-sqlite3

════════ CRITERIOS DE ACEPTACIÓN ════════
  1. Mostrá sw_vers + uname -m y decí qué fase elegiste y por qué.
  2. El import está verificado: origin correcto, rama main, hash mostrado, docs presentes.
  3. curl <url>/api/health devuelve {"ok":true,...}.
  4. La UI abre y muestra la pantalla inicial (no en blanco).
  5. Si configuraste modelo: "Probar conexión" en Ajustes da OK.

════════ PROHIBICIONES ════════
  - No expongas el puerto web ni el gateway a internet (no tienen auth multiusuario).
  - No instales Node 24 ni Electron en Catalina, ni parchees builds para forzarlo.
  - No clones dentro de carpetas del sistema; usá $HOME/Developer/open-design.
  - No borres datos del usuario, no uses sudo ni reescribas ramas sin pedir permiso.
  - Si algo es ambiguo, preguntá antes de ejecutar algo destructivo.
```
