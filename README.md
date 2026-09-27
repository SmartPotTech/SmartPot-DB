# SmartPot-DB (MongoDB)

## Estado del Proyecto

[![Database Image CI](https://github.com/SmartPotTech/SmartPot-DB/actions/workflows/ci.yml/badge.svg)](https://github.com/SmartPotTech/SmartPot-DB/actions/workflows/ci.yml)
[![Publish Docker Images](https://github.com/SmartPotTech/SmartPot-DB/actions/workflows/packaging.yml/badge.svg)](https://github.com/SmartPotTech/SmartPot-DB/actions/workflows/packaging.yml)

## Descripción

SmartPot-DB es la base de datos de **SmartPot**: una imagen de **MongoDB 8.0** que en su primer arranque crea el usuario de la aplicación, las nueve colecciones con **validación `$jsonSchema`** y, si se pide, una cuenta de demostración con dos cultivos y 48 horas de lecturas. [SmartPot-API](https://github.com/SmartPotTech/SmartPot-API) se conecta con el usuario de la aplicación, que solo tiene `readWrite` sobre su base, y crea los índices al arrancar.

## Estructura del Proyecto

```text
SmartPot-DB/
├── .github/
│   ├── dependabot.yml          # Actualización de la imagen base y de las Actions
│   └── workflows/
│       ├── ci.yml              # Construye la imagen y valida con y sin datos demo
│       ├── packaging.yml       # Publica la imagen en GHCR con SBOM y procedencia (y en Docker Hub con credenciales)
│       └── deploy.yml          # Pide el despliegue al workflow central de SmartPotTech/.github
├── init/
│   ├── 01_app_user.js          # Usuario de la aplicación con readWrite sobre su base
│   ├── 02_collections.js       # Aplica los esquemas en una base nueva
│   └── 03_demo_data.js         # Datos demo si SMARTPOT_SEED_DEMO=true
├── schemas/
│   └── collections.js          # Esquemas de las nueve colecciones y su aplicación idempotente
├── scripts/
│   └── migrate.js              # Aplica los esquemas a una base existente
├── tests/
│   └── validate.sh             # Colecciones, validadores, permisos, migración y demo
├── compose.yaml                # Base local endurecida con volumen persistente
├── Dockerfile                  # mongo:8.0 sin privilegios + scripts de inicio
└── .env.example
```

## Modelo de Datos

```mermaid
erDiagram
  USERS ||--o{ CROPS : owns
  USERS ||--o{ NOTIFICATIONS : receives
  USERS ||--o{ PASSWORD_RESET_TOKENS : requests
  CROPS ||--o{ READINGS : records
  CROPS ||--o{ ACTUATORS : has
  CROPS ||--o{ COMMANDS : receives
  ACTUATORS ||--o{ COMMANDS : executes
  USERS ||--o{ CHANNEL_LINKS : links
  CROPS ||--o| VIRTUAL_DEVICES : simulates
```

| Colección | Campos obligatorios | Reglas |
| --- | --- | --- |
| `users` | `email`, `passwordHash`, `role`, `createdAt` | Hash BCrypt; rol `USER` o `ADMIN` |
| `crops` | `ownerId`, `name`, `type`, `automationEnabled`, `createdAt` | Seis especies; `device` guarda la clave cifrada del dispositivo |
| `readings` | `cropId`, `measuredAt`, `measures` | Origen `MQTT` o `HTTP`; la API las borra al año (TTL) |
| `actuators` | `cropId`, `type`, `active` | Uno por tipo en cada cultivo |
| `commands` | `cropId`, `actuatorId`, `actuatorType`, `action`, `status`, `source`, `createdAt` | Estados `PENDING`, `SENT`, `EXECUTED`, `FAILED`, `EXPIRED`; TTL de 180 días |
| `notifications` | `userId`, `type`, `title`, `message`, `read`, `createdAt` | TTL de 90 días |
| `password_reset_tokens` | `tokenHash`, `userId`, `expiresAt` | Solo el SHA-256 del token; se borra al vencer |
| `channel_links` | `userId`, `type`, `address`, `enabled`, `events`, `linkedAt`, `failures` | Canal `TELEGRAM`; `address` es el id del chat; `events` sin repetidos entre los tipos de notificación |
| `virtual_devices` | `cropId`, `ownerId`, `mode`, `intervalSeconds`, `createdAt`, `updatedAt` | Modo `AUTO`, `MANUAL` o `WEATHER`; intervalo de 10 a 300 s; `location` con nombre, latitud y longitud válidas |

Los identificadores entre colecciones se guardan como `ObjectId`. Los campos de más (como `_class`) se permiten; los tipos y valores de los campos listados no. Los índices, incluidos los únicos de `channel_links` y `virtual_devices`, los crea la API al arrancar.

## Migración

Los scripts de `init/` solo corren con el volumen vacío, así que una base existente no recibe los esquemas nuevos por sí sola. `schemas/collections.js` es la única definición y se aplica de forma idempotente: crea la colección que falte y, a la que exista, le pone su validador con `collMod`. Después de actualizar la imagen:

```bash
docker exec smartpot-db mongosh --quiet /opt/smartpot/migrate.js
```

El script se autentica con la cuenta root del contenedor, leída del entorno para que la clave no aparezca en la línea de comandos, e informa cada colección. Si una colección tiene documentos antiguos que no cumplen el esquema, su validación queda en `moderate`: los documentos nuevos y los que ya cumplen se validan, y los antiguos se pueden seguir actualizando hasta corregirlos. Sin documentos inválidos queda en `strict`.

## Datos de Demostración

Con `SMARTPOT_SEED_DEMO=true` se carga la cuenta **`demo@smartpot.app`** con contraseña **`SmartPot2026`**:

| Cultivo | Tipo | Contenido |
| --- | --- | --- |
| Lechugas del balcón | `LETTUCE` | Modo automático activo, 288 lecturas, un riego del agente y otro manual |
| Tomates cherry | `TOMATO` | 288 lecturas con ciclo día/noche |

Las claves de dispositivo de la demo están cifradas con la clave AES pública del entorno de demostración, así el simulador de SmartPot-DataGenerator puede conectarse sin configuración.

> [!WARNING]
> `SMARTPOT_SEED_DEMO` es `false` por defecto. Actívalo solo en local, demo o pruebas: la contraseña demo es pública.

Los scripts de `init/` se ejecutan **solo cuando el volumen está vacío**. Cambiar las variables en una base ya creada no tiene efecto: hay que recrear el volumen.

## Guía de Instalación

### Requisitos Previos

- Docker (Docker Desktop o Docker Engine con Compose v2)

### Ejecución con Docker Compose

```bash
git clone https://github.com/SmartPotTech/SmartPot-DB.git
cd SmartPot-DB
cp .env.example .env    # define las contraseñas
docker compose up -d
```

Cadena de conexión de la API:

```text
mongodb://smartpot:<SMARTPOT_DB_PASSWORD>@localhost:27017/smartpot?authSource=smartpot
```

### Prueba de la imagen

```bash
docker build -t smartpot-db:ci .
sh tests/validate.sh smartpot-db:ci true
```

Además de colecciones, permisos y datos demo, la prueba simula una base anterior (una colección sin validador y otra con un documento antiguo), corre la migración y comprueba que es idempotente.

## Imagen publicada

```bash
docker pull ghcr.io/smartpottech/smartpot-db:latest
```

La imagen corre como el usuario `999` y admite sistema de archivos de solo lectura con `tmpfs` en `/tmp`.

Cada cambio en `main` pasa por el CI, publica la imagen en GHCR (y en Docker Hub como réplica cuando el repositorio tiene credenciales) y pide el despliegue al workflow central de [SmartPotTech/.github](https://github.com/SmartPotTech/.github), que actualiza producción de a uno y verifica `/health`.

## Documentación

La base guarda todo lo que la plataforma necesita recordar. La [documentación técnica](https://github.com/SmartPotTech/.github/blob/main/docs/SmartPot_Technical_Documentation.md) resume cada colección con sus índices, vencimientos y validación. Los superdiagramas muestran la plataforma completa en una sola imagen ampliable:

- [Linaje de los datos](https://github.com/SmartPotTech/.github/blob/main/docs/images/superdiagrams/SmartPot_Super_04_Data_Lineage.svg): de dónde sale cada dato, en qué colección queda y quién lo usa
- [Modelo de dominio](https://github.com/SmartPotTech/.github/blob/main/docs/images/superdiagrams/SmartPot_Super_06_Domain_Model.svg): las entidades de la API que se guardan en cada colección

## Licencia

Este proyecto está bajo la licencia MIT. Consulta el archivo [LICENSE](LICENSE) para más detalles.
