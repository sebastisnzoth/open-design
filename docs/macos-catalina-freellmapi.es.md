# OpenDesign en macOS Catalina + FreeLLMAPI en modo local

Guía para instalar OpenDesign 0.22.1 en un Mac con macOS 10.15 Catalina y apuntarlo a
[FreeLLMAPI](https://github.com/tashfeenahmed/freellmapi) corriendo en `127.0.0.1:3001`.

> Si tu Mac puede correr macOS 13.5+, lo que buscás es levantar el repo desde el código:
> [`levantar-en-mac.es.md`](levantar-en-mac.es.md).

---

## 0. Resumen: qué es posible y qué no

**Catalina no puede ejecutar OpenDesign 0.22.1 de forma nativa.** No es un tema de
configuración: son tres mínimos de sistema duros, y el repo está muy por encima de ellos.

| Componente | Versión en el repo | Mínimo real | Detalle |
| --- | --- | --- | --- |
| Electron (app de escritorio) | `41.3.0` (`apps/desktop/package.json`) | **macOS 12 Monterey** | Electron 33 quitó 10.15 ([blog](https://www.electronjs.org/blog/electron-33-0)); Electron 38 quitó 11 ([breaking changes](https://www.electronjs.org/docs/latest/breaking-changes)) |
| Node.js (daemon, web y build) | `~24` (`package.json#engines`) | **macOS 13.5** para binarios oficiales | Node 24 compila con `-mmacosx-version-min=13.5` |
| Navegador para la UI | Next 15 + React moderno | **Chrome 128 / Safari 15.6** en Catalina | Chrome 129 dejó de soportar 10.15; 128 es la última |

Traducción: en el propio Mac con Catalina **no se puede compilar ni ejecutar** el stack
(no hay Node 24 ni Electron 41 arrancables). Quedan dos caminos reales:

- **Ruta A — Catalina como cliente web**: OpenDesign corre en otra máquina de tu red y
  desde Catalina abrís la UI en Chrome 128 / Safari 15.6. Sin tocar el Mac.
- **Ruta B — nativo**: actualizar macOS (o OpenCore Legacy Patcher si el Mac es 2012–2015)
  y compilar/instalar la app normal.

Ambas rutas se conectan igual a FreeLLMAPI (sección 3).

---

## 1. Ruta A — Catalina como cliente web (recomendada si no querés tocar el Mac)

La UI web es la misma que la del escritorio; sólo se necesita una máquina con
Node 24 + pnpm 10.33.2 (otro Mac, una PC Linux, un servidor casero).

> **Atajo listo para usar:** [`deploy/catalina/`](../deploy/catalina/README.es.md) tiene el
> kit completo — `setup.sh` (instala, compila, detecta la IP de LAN y arranca), `status.sh`,
> `stop.sh` y `freellmapi.sh` (gateway local). El paso a paso manual queda abajo como
> referencia de qué hace cada cosa.

**En la máquina servidor:**

```bash
git clone https://github.com/sebastisnzoth/open-design.git
cd open-design
corepack enable                # pnpm 10.33.2 según packageManager
corepack pnpm install --frozen-lockfile
corepack pnpm bootstrap        # compila packages/, daemon, web y tools

# Arranca daemon + web escuchando en toda la LAN
OD_HOST=0.0.0.0 \
OD_ALLOWED_ORIGINS="http://192.168.0.42:3000" \
OD_ALLOWED_DEV_ORIGINS="192.168.0.42" \
corepack pnpm tools-dev run web --daemon-port 7456 --web-port 3000
```

Qué hace cada variable (verificado en este repo):

- `OD_HOST=0.0.0.0` — el sidecar web (`apps/web/sidecar/server.ts`, `const HOST = process.env.OD_HOST || "127.0.0.1"`)
  deja de escuchar sólo en loopback. Sin esto el puerto queda en `127.0.0.1` y la LAN no llega.
- `OD_ALLOWED_ORIGINS` / `OD_ALLOWED_DEV_ORIGINS` — alimentan `allowedDevOrigins` en
  `apps/web/next.config.ts`; sin ellos Next bloquea los assets `/_next/*` pedidos desde
  otro origen (síntoma: HTML carga, la app queda en blanco).
- `--daemon-port 7456` queda en `127.0.0.1` a propósito: sólo el web se expone.

Comprobalo desde el servidor antes de ir al Mac:

```bash
curl -s -o /dev/null -w "web=%{http_code}\n"   http://192.168.0.42:3000/
curl -s -o /dev/null -w "api=%{http_code}\n"   http://192.168.0.42:3000/api/health
```

**En el Mac con Catalina:**

1. Instalá **Chrome 128** (última build para 10.15) o usá Safari 15.6.
2. Abrí `http://192.168.0.42:3000`.
3. Si el firewall del servidor lo pide, habilitá el puerto 3000 sólo para la subred local.

Notas:

- No expongas el puerto a internet: ni OpenDesign ni FreeLLMAPI tienen autenticación
  multi-tenant (son local-first por diseño).
- Si en Safari 15.6 ves pantalla en blanco, es limitación del motor JS: usá Chrome 128.

---

## 2. Ruta B — instalación nativa (requiere macOS 12+)

**Primero confirmá que tu Mac puede**: Ajustes del Sistema → Actualización de software.
Los Mac de 2015 en adelante llegan oficialmente a Monterey/Ventura; los de 2012–2014
pueden llegar con [OpenCore Legacy Patcher](https://dortania.github.io/OpenCore-Legacy-Patcher/).

Con macOS 12+ y Xcode Command Line Tools instaladas:

```bash
git clone https://github.com/sebastisnzoth/open-design.git
cd open-design
corepack enable
corepack pnpm install --frozen-lockfile
corepack pnpm bootstrap

# Compila la app + DMG (sin firma ni notarización: build local)
corepack pnpm tools-pack mac build --to dmg
```

- Salida del artefacto: `.tmp/tools-pack/out/mac/namespaces/<namespace>/builder/`
  (`DMG`/`.app`), según `tools/pack/src/config/index.ts`.
- Arquitectura: todos los Mac con Catalina son **Intel x64**, así que el build debe ser x64
  (`tools-pack` usa `process.arch`). `arm64` no aplica.
- `--signed` / `--notarize` sólo si tenés certificado Apple Developer; sin eso el build
  local es sin firma y macOS lo va a frenar en el primer arranque.

Instalación y Gatekeeper (app sin firmar):

```bash
# arrastrá OpenDesign.app a /Applications y después:
xattr -dr com.apple.quarantine /Applications/OpenDesign.app
open /Applications/OpenDesign.app
```

Si sigue bloqueando: Ajustes del Sistema → Privacidad y seguridad → *Abrir igualmente*.

> **No intentes “bajar” Electron a 32.x para que corra en Catalina.** Sería un port de
> 9 majors (Electron 41 → 32), con Node 24 → 20 en el daemon y sin validación del resto
> del stack. Es más trabajo que actualizar el sistema y queda fuera del soporte del repo.

---

## 3. FreeLLMAPI en modo local

FreeLLMAPI es un gateway OpenAI-compatible self-hosted que junta los free tiers de ~30
proveedores (Google AI Studio, Groq, Cerebras, Mistral, OpenRouter free, NVIDIA, etc.)
detrás de `http://127.0.0.1:3001/v1` con failover automático.

### 3.1 Levantarlo

Con Docker (lo más simple):

```bash
curl -fsSL https://freellmapi.co/install.sh | bash
# crea ~/freellmapi, genera ENCRYPTION_KEY y expone 127.0.0.1:3001
docker compose -f ~/freellmapi/docker-compose.yml ps
```

Sin Docker (Node 20+, en la máquina servidor — **no** en Catalina):

```bash
git clone https://github.com/tashfeenahmed/freellmapi.git
cd freellmapi && npm install
printf "ENCRYPTION_KEY=%s\nPORT=3001\nHOST_BIND=127.0.0.1\n" \
  "$(node -e 'console.log(require("crypto").randomBytes(32).toString("hex"))')" > .env
npm run build && node server/dist/index.js
```

`HOST_BIND=127.0.0.1` es el “modo local” de verdad: el gateway no queda expuesto a la LAN.

### 3.2 Cargar proveedores y sacar la key unificada

1. Abrí `http://localhost:3001` (dashboard).
2. **Keys** → agregá las API keys gratuitas que tengas (Google AI Studio, Groq, Cerebras,
   OpenRouter, Mistral…). Sin keys no hay modelos.
3. Ordená la **Fallback Chain** (el router usa las de arriba primero).
4. Copiá la **unified key** del encabezado de la página Keys (formato `freellmapi-…`).

Verificación:

```bash
export FREELLMAPI_KEY="freellmapi-…"
curl -s http://127.0.0.1:3001/v1/models -H "Authorization: Bearer $FREELLMAPI_KEY" | head -c 400
curl -s http://127.0.0.1:3001/v1/chat/completions \
  -H "Authorization: Bearer $FREELLMAPI_KEY" -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"ping"}]}' | head -c 300
```

### 3.3 Conectarlo en OpenDesign (BYOK)

En OpenDesign: **Ajustes → Ejecución → API** (modo BYOK, sin CLI local) y completá:

| Campo | Valor |
| --- | --- |
| Proveedor / protocolo | **OpenAI** (OpenAI-compatible) |
| Base URL | `http://127.0.0.1:3001/v1` |
| API key | `freellmapi-…` (la unificada) |
| Modelo | `auto` (o `auto:fast`, `auto:smart`, o un id concreto) |

Cómo se usa por dentro (para que sepas qué esperar):

- El protocolo `openai` con Base URL propia va por el runtime BYOK
  (`apps/daemon/src/runtimes/byok-opencode.ts`), que arma el proveedor
  `open-design-byok` con `@ai-sdk/openai-compatible` y pasa la key al hijo por
  `OPEN_DESIGN_BYOK_API_KEY` — nunca queda escrita en el repo.
- `baseUrl` y `model` son editables en la config (`AppConfig` en `apps/web/src/state/config.ts`);
  un `baseUrl` en loopback/local es aceptado (existe el preset `vLLM` con
  `http://127.0.0.1:8000/v1` como precedente).
- Descubrimiento de modelos: pide `/v1/models` al gateway; FreeLLMAPI lo implementa, así que
  el selector debería poblarse. Si el gateway no tiene keys, la lista vuelve vacía → cargá keys primero.

**Si OpenDesign corre en otra máquina que FreeLLMAPI**: en Base URL poné la IP de la máquina
del gateway (`http://192.168.0.42:3001/v1`) y en FreeLLMAPI escuchá en esa interfaz
(`HOST_BIND=0.0.0.0`), con firewall limitado a la LAN.

### 3.4 “Modo local” de punta a punta

- **Datos**: `OD_DATA_DIR=~/OpenDesignData` para que proyectos/estado queden en una carpeta tuya.
- **Telemetría**: OpenDesign soporta sink `none` (`OD_TELEMETRY_ENV`); con eso no sale nada.
- **Red**: daemon en `127.0.0.1`, FreeLLMAPI en `127.0.0.1`, sólo el web en la LAN si usás Ruta A.
- **Ojo con la letra chica**: FreeLLMAPI es local, pero las requests salen después a
  Google/Groq/Cerebras/OpenRouter. Si querés inferencia 100% en tu equipo, apuntá el
  proveedor *custom* de FreeLLMAPI a **Ollama / llama.cpp** local (`http://127.0.0.1:11434`).

---

## 4. Checklist de instalación

- [ ] Elegí ruta: A (cliente web) o B (nativo con macOS 12+).
- [ ] En el servidor: `pnpm install --frozen-lockfile && pnpm bootstrap`.
- [ ] Ruta A: `OD_HOST=0.0.0.0` + `OD_ALLOWED_ORIGINS` con la IP del servidor; probar `/` y `/api/health`.
- [ ] Ruta B: `pnpm tools-pack mac build --to dmg` (x64) y `xattr -dr com.apple.quarantine`.
- [ ] FreeLLMAPI arriba en `127.0.0.1:3001` con al menos una key de proveedor.
- [ ] `/v1/models` y `/v1/chat/completions` responden con la unified key.
- [ ] OpenDesign: Ajustes → API → OpenAI + base URL `http://127.0.0.1:3001/v1` + modelo `auto` → **Probar conexión**.
- [ ] Primer run de diseño con el modelo en `auto`.

## 5. Problemas típicos

| Síntoma | Causa / solución |
| --- | --- |
| `App is damaged` / no abre | App sin firmar: `xattr -dr com.apple.quarantine`, luego *Abrir igualmente* |
| `tools-dev must run with Node ~24` | Estás bajo Node 22: `nvm use 24` (y reinstalar `better-sqlite3`) |
| HTML carga pero la UI queda en blanco desde el Mac | Falta `OD_ALLOWED_ORIGINS`/`OD_ALLOWED_DEV_ORIGINS` con la IP del servidor |
| `401` al probar en OpenDesign | La key unificada de FreeLLMAPI está mal copiada (debe empezar con `freellmapi-`) |
| `429` o “no models” | Fallback chain agotada o sin keys cargadas en FreeLLMAPI |
| Safari 15.6 rompe la UI | Usá Chrome 128 (último soportado en Catalina) |
