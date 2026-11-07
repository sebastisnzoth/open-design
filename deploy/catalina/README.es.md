# Servidor OpenDesign para un Mac con Catalina

Este kit deja OpenDesign corriendo en una máquina moderna (Linux o macOS 13+) y expuesto
en la LAN, para que el Mac con **macOS 10.15 Catalina** lo use desde el navegador
(Chrome 128 o Safari 15.6). Opcionalmente levanta **FreeLLMAPI** en modo local como
proveedor BYOK.

> **Por qué no se instala directo en Catalina:** la app de escritorio usa Electron 41
> (requiere macOS 12+) y el stack necesita Node 24 (binarios oficiales con target 13.5).
> Ver `docs/macos-catalina-freellmapi.es.md` para el detalle y para la ruta nativa
> (actualizar macOS / OpenCore Legacy Patcher).

---

## Puesta en marcha (3 comandos)

```bash
# 1. Requisitos en el servidor: Node 24 + corepack (o pnpm 10.33.2)
node -v            # v24.x

# 2. Arranca todo (instala deps si faltan, compila y publica en la LAN)
./deploy/catalina/setup.sh --with-freellmapi

# 3. Estado y URL para el Mac
./deploy/catalina/status.sh
```

`setup.sh` imprime al final la URL exacta para el Mac, por ejemplo:

```
http://192.168.0.42:3000
```

En el Mac con Catalina: abrí esa URL con **Chrome 128** (última versión compatible con
10.15) o Safari 15.6.

Para parar:

```bash
./deploy/catalina/stop.sh          # OpenDesign
./deploy/catalina/stop.sh --all    # OpenDesign + FreeLLMAPI
```

## Qué hace `setup.sh`

1. Verifica **Node 24** (falla con un mensaje claro si estás en 22) y resuelve pnpm vía corepack.
2. `pnpm install --frozen-lockfile` y `pnpm bootstrap` sólo si faltan `node_modules/` o los `dist/`.
3. Detecta la IP de LAN (`ipconfig getifaddr` en macOS, `ip route` en Linux; override con `OD_LAN_IP`).
4. Exporta lo necesario para exponer la UI **sin que Next la bloquee**:
   - `OD_HOST=0.0.0.0` — el sidecar web (`apps/web/sidecar/server.ts`) sale de loopback.
   - `OD_ALLOWED_ORIGINS` / `OD_ALLOWED_DEV_ORIGINS` — llenan `allowedDevOrigins`
     (`apps/web/next.config.ts`). Sin esto cargan el HTML y la UI queda en blanco.
   - `OD_WEB_DEV_BUNDLER=turbopack` — webpack tarda minutos y se queda sin memoria en
     máquinas de 2 vCPU / 4 GB; Turbopack compila en ~25 s.
5. Arranca `tools-dev start web` (daemon en `127.0.0.1`, web en `0.0.0.0`) y espera el primer 200.

## FreeLLMAPI en modo local

```bash
./deploy/catalina/freellmapi.sh start    # Docker si existe; si no, checkout + Node en ~/freellmapi
./deploy/catalina/freellmapi.sh key      # te manda al dashboard a copiar la unified key
./deploy/catalina/freellmapi.sh logs
./deploy/catalina/freellmapi.sh stop
```

- Escucha en `127.0.0.1:3001` (`HOST=127.0.0.1` en `~/freellmapi/.env`; en Docker el puerto
  se publica como `127.0.0.1:3001`). Si `ss -lnt` muestra además tu IP de LAN, bloqueá 3001
  en el firewall: el gateway no tiene auth multi-tenant.
- Con Docker: crea/gestiona el contenedor `freellmapi` y guarda estado en `~/freellmapi/data`.
- Sin Docker: clona el repo, `npm install`, `npm run build` y corre `server/dist/index.js`
  como proceso propio (pid en `~/freellmapi/.freellmapi.pid`).

Después, en el dashboard (`http://127.0.0.1:3001`): cargá las keys de los free tiers
(Google AI Studio, Groq, Cerebras, Mistral, OpenRouter…) y copiá la **unified key**
(`freellmapi-…`).

### Conectar en OpenDesign

**Ajustes → Ejecución → API → OpenAI**

| Campo | Valor |
| --- | --- |
| Base URL | `http://127.0.0.1:3001/v1` |
| API key | `freellmapi-…` |
| Modelo | `auto` |

Si el servidor de OpenDesign no es el mismo que el de FreeLLMAPI, usá la IP de la máquina
del gateway en Base URL y levantá FreeLLMAPI escuchando en esa interfaz.

## Pruebas

```bash
./deploy/catalina/tests/smoke.sh                 # 27 casos rápidos, sin red
./deploy/catalina/tests/smoke.sh --integration   # + arranque real en puertos alternos
```

Cubren: sintaxis, argumentos inválidos, Node < 24, puertos no numéricos o repetidos, IP de
LAN inusable, puertos ocupados (falla en <1 s, no espera 3 min), idempotencia sobre una
instancia viva, y que `stop` **no mate un PID reciclado** que ya no es suyo.

## Variables

| Variable | Default | Uso |
| --- | --- | --- |
| `OD_LAN_IP` | autodetectada | IP que se publica en la URL del Mac |
| `OD_WEB_PORT` | `3000` | puerto web (el que se expone en la LAN) |
| `OD_DAEMON_PORT` | `7456` | puerto del daemon (queda en loopback) |
| `OD_NAMESPACE` | `default` | namespace de `tools-dev` (permite varios entornos) |
| `FREELLMAPI_DIR` | `~/freellmapi` | carpeta del checkout/estado |
| `FREELLMAPI_PORT` | `3001` | puerto local del gateway |
| `FREELLMAPI_IMAGE` | `ghcr.io/tashfeenahmed/freellmapi:latest` | imagen Docker |

## Checklist

- [ ] El servidor tiene Node 24 y `corepack pnpm --version` responde `10.33.2`.
- [ ] `./deploy/catalina/setup.sh` termina con ✓ en las cuatro comprobaciones de `status.sh`.
- [ ] Desde el Mac, la URL `http://<ip>:<puerto>` carga la UI (no en blanco).
- [ ] `http://127.0.0.1:3001/v1/models` responde `401` sin key y `200` con la unified key.
- [ ] En OpenDesign, *Probar conexión* del proveedor OpenAI da OK.

## Problemas típicos

| Síntoma | Causa |
| --- | --- |
| `tools-dev must run with Node ~24` | Estás en Node 22: `nvm use 24` y `pnpm install --frozen-lockfile` |
| HTML carga pero la UI queda en blanco desde el Mac | Falta `OD_ALLOWED_ORIGINS`/`OD_ALLOWED_DEV_ORIGINS` con la IP correcta |
| `El web no respondió en 180s` | Revisá `pnpm tools-dev logs web`; el primer arranque necesita compilar |
| FreeLLMAPI no arranca sin Docker | Necesita `better-sqlite3` compilado para tu Node (normalmente lo resuelve `npm install`) |
| `401` en `/v1/models` | Es lo esperado sin la unified key; pegala en OpenDesign, no en `.env` |
| `No pude validar better-sqlite3` (aviso) | Sólo es informativo; si el daemon arranca, ignoralo |
| `better-sqlite3 está compilado para otro Node` | Cambiaste de versión de Node: el script reconstruye solo (necesita red + Xcode CLT) |
| FreeLLMAPI “no pudo cargar better-sqlite3” | npm no bajó el prebuilt (sin red/proxy): `npm install --force` en `~/freellmapi` o usá Docker |

## Notas de seguridad

- El daemon queda en `127.0.0.1`; **sólo** se expone el puerto web. Si no querés exponerlo
  en la LAN, no uses este kit: `pnpm tools-dev start web` (sin `OD_HOST`) queda en loopback.
- FreeLLMAPI puede quedar escuchando también en tu IP de LAN aunque `HOST=127.0.0.1`
  (su proceso abre más de un listener). Verificá con `ss -lnt | grep 3001` / `lsof -i :3001`
  y, si aparece la IP de LAN, bloqueá el puerto en el firewall.
- Ninguno de los dos servicios tiene auth multi-tenant: no los expongas a internet.
