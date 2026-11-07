# Levantar este repo en tu Mac

Guía para correr OpenDesign desde el código en una Mac. Si lo que querés es **usar** la app
en una Mac vieja con Catalina, eso es otro camino: [`macos-catalina-freellmapi.es.md`](macos-catalina-freellmapi.es.md).

---

## 0. Chequeo previo (30 segundos)

```bash
sw_vers -productVersion     # versión de macOS
uname -m                    # arm64 = Apple Silicon · x86_64 = Intel
node -v                     # si ya tenés Node
```

| Lo que ves | Qué hacer |
| --- | --- |
| macOS **13.5 o superior** | Seguí esta guía tal cual. |
| macOS 12 – 13.4 | Node 24 oficial pide 13.5: probá igual (§2) y si `node -v` falla, actualizá el sistema. |
| macOS **10.15 Catalina** | Node 24 y Electron 41 no arrancan ahí. Usá la [ruta servidor + cliente web](macos-catalina-freellmapi.es.md) o actualizá macOS (OpenCore Legacy Patcher si el Mac es 2012–2015). |

Memoria: con **4 GB** se puede, pero compilar Next tarda y conviene un solo entorno a la vez
(el repo trae un modo que evita el bundler pesado, ver §3). Con 8 GB o más, sin drama.

---

## 1. Requisitos

```bash
xcode-select --install        # Xcode Command Line Tools (compiladores para módulos nativos)
```

- **Node 24** (el repo lo fija en `.node-version`, `mise.toml` y `package.json#engines`).
- **pnpm 10.33.2** (lo resuelve corepack según `packageManager`).
- Git.

Una sola forma de instalar Node 24, a elección:

```bash
# A) nvm
nvm install 24 && nvm use 24

# B) Homebrew
brew install node@24 && brew link --overwrite node@24

# C) mise (el repo ya trae mise.toml con node=24 y pnpm=10.33.2)
mise install
```

Después, pnpm:

```bash
corepack enable
corepack pnpm --version      # tiene que imprimir 10.33.2
```

Si `corepack` no existe (algunas instalaciones de Homebrew no lo traen):

```bash
npm i -g pnpm@10.33.2
```

---

## 2. Instalación

```bash
git clone https://github.com/sebastisnzoth/open-design.git
cd open-design

node -v                      # v24.x
pnpm --version               # 10.33.2

pnpm install --frozen-lockfile
pnpm bootstrap               # compila packages/, daemon, web y tools
```

`pnpm bootstrap` es el `postinstall` del repo: compila los workspaces en orden de dependencias.
Tarda unos minutos la primera vez.

**Si `pnpm install` falla** por módulos opcionales (`onnxruntime-node`, `electron`,
`better-sqlite3`), son descargas de binarios desde GitHub: detrás de un proxy corporativo o sin
red fallan. Para desarrollo de daemon+web no hacen falta:

```bash
pnpm install --ignore-scripts
pnpm --filter @open-design/daemon rebuild better-sqlite3 --pending
```

`better-sqlite3` sí es obligatorio (es la base del daemon) y se compila con las CLT instaladas
en §1.

---

## 3. Levantarlo

### Opción A — todo incluido (app de escritorio Electron + daemon + web)

```bash
pnpm tools-dev
```

Abre la app. Necesita sesión gráfica (no sirve por SSH sin display). Es el modo "producto completo".

### Opción B — sólo web (recomendada para probar rápido o Macs con poca RAM)

```bash
pnpm tools-dev start web            # daemon + web en background
pnpm tools-dev status               # qué está corriendo y en qué URL
pnpm tools-dev logs web             # logs
pnpm tools-dev stop                 # apagar
```

**Ojo con los puertos:** sin flags, `tools-dev` toma puertos libres al azar y los imprime.
Para tenerlos fijos:

```bash
pnpm tools-dev start web --web-port 3000 --daemon-port 7456
#   - daemon: started · running · http://127.0.0.1:7456
#   - web:    started · running · http://127.0.0.1:3000
```

Abrí la URL que imprime (`➜ Web:` con `run`, o la línea `web: started …` con `start`).

En máquinas de 2 núcleos / 4 GB, el bundler por defecto (webpack) tarda minutos y puede quedarse
sin memoria. Forzá Turbopack:

```bash
OD_WEB_DEV_BUNDLER=turbopack pnpm tools-dev start web
```

Para quedarte en primer plano con logs en vivo:

```bash
pnpm tools-dev run web --daemon-port 17456 --web-port 17573
```

### Opción C — servirlo a otro equipo de la red (o a un Mac con Catalina)

```bash
./deploy/catalina/setup.sh              # detecta la IP, expone el web en la LAN y verifica
./deploy/catalina/status.sh             # checks + URL para el otro equipo
```

Detalle completo en [`../deploy/catalina/README.es.md`](../deploy/catalina/README.es.md).

> Los archivos de runtime (`node_modules/`, `.tmp/tools-dev/…`) están en `.gitignore`: no
> ensucian el repo.

---

## 4. Verificación rápida

```bash
pnpm tools-dev status            # muestra la URL del web y del daemon
curl -s <url-del-web>/api/health
# {"ok":true,"version":"0.22.1",...}

pnpm tools-dev check             # estado + últimas líneas de log
```

Si `/api/health` responde `ok:true`, el daemon está sano y la UI ya tiene con qué trabajar.

---

## 5. Conectar un modelo

Sin un CLI de agente local (Claude Code, Codex, etc.) la app arranca igual, pero no puede correr
diseños hasta que configures un proveedor.

**BYOK con FreeLLMAPI local** (free tiers agregados detrás de un único endpoint):

```bash
./deploy/catalina/freellmapi.sh start      # gateway en 127.0.0.1:3001
./deploy/catalina/freellmapi.sh key        # te manda al dashboard a copiar la unified key
```

En OpenDesign: **Ajustes → Ejecución → API → OpenAI**, con `http://127.0.0.1:3001/v1`,
la key `freellmapi-…` y modelo `auto`.

**BYOK directo**: mismo menú, elegí el proveedor (OpenAI, Anthropic, Google, DeepSeek, OpenRouter…)
y pegá tu API key.

**CLI local**: si tenés `claude` / `codex` / `opencode` instalados y en el `PATH`, aparecen en
**Modelos y proveedores → CLI local**; si no los detecta, usá *Rescan* (el GUI puede heredar un
`PATH` mínimo).

---

## 6. Tests (opcional)

```bash
pnpm typecheck                                   # TypeScript de todo el monorepo
pnpm --filter @open-design/daemon test           # daemon
pnpm --filter @open-design/web test              # web

pnpm -C e2e exec playwright install --with-deps chromium   # navegadores (una vez)
pnpm -C e2e test                                 # e2e headless (Vitest)
pnpm -C e2e test:ui                              # e2e de UI (Playwright)
```

El harness de e2e levanta su propio daemon + web aislados por worker sobre `tools-dev`
(`e2e/lib/tools-dev/`), así que no compite con la instancia que tengas abierta.

---

## 7. Actualizar y limpiar

```bash
git pull
pnpm install --frozen-lockfile
pnpm bootstrap

pnpm tools-dev stop                 # procesos
rm -rf .tmp/tools-dev               # datos/logs de desarrollo (se regeneran)
```

Los datos de usuario del producto quedan fuera del repo (en el directorio de datos de OpenDesign),
salvo que exportes `OD_DATA_DIR`.

---

## 8. Problemas típicos

| Síntoma | Causa y solución |
| --- | --- |
| `tools-dev must run with Node ~24` | Estás en otro Node: `nvm use 24` y `pnpm install --frozen-lockfile` |
| `NODE_MODULE_VERSION … requires NODE_MODULE_VERSION …` | Cambiaste de Node: `pnpm --filter @open-design/daemon rebuild better-sqlite3 --pending` |
| `tsx: not found` al bootstrapear | El `pnpm install` no terminó: repetilo y verificá `ls node_modules/.bin/tsx` |
| Compilación de minutos / se cuelga | `OD_WEB_DEV_BUNDLER=turbopack pnpm tools-dev start web` |
| UI en blanco al entrar desde otra máquina | Faltan `OD_ALLOWED_ORIGINS` / `OD_ALLOWED_DEV_ORIGINS` (el kit los pone solo) |
| `unable to verify the first certificate` al instalar | Proxy/TLS: `pnpm install --ignore-scripts` + rebuild de `better-sqlite3` |
| `electron` no abre / no descarga | `pnpm --filter @open-design/desktop exec electron --version`; si falla la descarga, usá la Opción B (sólo web) |
| Puerto ocupado | `--web-port 3100 --daemon-port 7460`, o `pnpm tools-dev stop` |
| El daemon muere con `TypeError: Invalid URL` en `origin-validation.ts` | `OD_ALLOWED_ORIGINS` sólo acepta URLs completas (`http://host:puerto`); los comodines (`*.dominio`) van **sólo** en `OD_ALLOWED_DEV_ORIGINS` |
| No sé en qué puerto quedó | `pnpm tools-dev status` (sin flags usa puertos libres al azar) |
| `xcode-select: error: tool requires command line developer tools` | `xcode-select --install` y reintentar el rebuild |
