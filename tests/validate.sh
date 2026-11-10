#!/bin/sh
# Valida de punta a punta la imagen de base de datos: configuración del motor, esquema, integridad referencial,
# restricciones, permisos por rol, agregados continuos, migración idempotente, la ruta de actualización con
# compresión y el ciclo de respaldo/restauración. Falla el proceso si una sola comprobación no se cumple.
#   sh tests/validate.sh <imagen> <true|false>
set -eu

IMAGE="${1:-smartpot-db-postgre:ci}"
DEMO="${2:-false}"
NAME="smartpot-db-postgre-validate"
APP_PASS="app-password-ci-1234"
READER_PASS="reader-ci-password-1234"
ROOT_PASS="root-password-ci-123"

# En Git Bash (Windows) MSYS convierte las rutas absolutas que recibe docker.exe; desactivarlo deja intactos
# /opt/smartpot/migrate.sh y /tmp dentro del contenedor. En Linux la variable no tiene efecto.
MSYS_NO_PATHCONV=1
export MSYS_NO_PATHCONV

if [ "$DEMO" != "true" ] && [ "$DEMO" != "false" ]; then
    echo "FAIL demo flag must be true or false, got '$DEMO'" >&2
    exit 2
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "FAIL image '$IMAGE' is not available" >&2
    exit 2
fi

# El contenedor es efímero: se borra siempre, incluso si una comprobación falla o el proceso se interrumpe.
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

# Endurecido: root de solo lectura, sin privilegios nuevos y solo los caps que el entrypoint de PostgreSQL necesita
# para preparar su directorio de datos y bajar al usuario postgres (los caps de escalado siguen descartados).
docker run -d --name "$NAME" \
  --read-only --tmpfs /tmp --tmpfs /run/postgresql --tmpfs /var/lib/postgresql/data \
  --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETGID --cap-add SETUID \
  --security-opt no-new-privileges \
  -e POSTGRES_USER=smartpot-root -e POSTGRES_PASSWORD="$ROOT_PASS" -e POSTGRES_DB=smartpot \
  -e SMARTPOT_DB_USERNAME=smartpot -e SMARTPOT_DB_PASSWORD="$APP_PASS" -e SMARTPOT_SEED_DEMO="$DEMO" \
  -e SMARTPOT_READER_PASSWORD="$READER_PASS" \
  "$IMAGE" >/dev/null

# Las consultas de la aplicación usan el usuario smartpot; las de administración, la cuenta root del contenedor.
# Los roles de aplicación se conectan por TCP a la IP del contenedor (no a 127.0.0.1, que el pg_hba de la imagen
# deja en trust) para comprobar también la contraseña y el pg_hba definitivo.
DB_HOST="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME" 2>/dev/null | tr -d '\r')"
if [ -z "$DB_HOST" ]; then
    echo "FAIL could not determine the container IP address" >&2
    exit 1
fi
app() { docker exec -e PGPASSWORD="$APP_PASS" "$NAME" psql -h "$DB_HOST" -qtA -v ON_ERROR_STOP=1 -U smartpot -d smartpot -c "$1"; }
reader() { docker exec -e PGPASSWORD="$READER_PASS" "$NAME" psql -h "$DB_HOST" -qtA -v ON_ERROR_STOP=1 -U smartpot_reader -d smartpot -c "$1"; }
ingest() { docker exec -e PGPASSWORD="$APP_PASS" "$NAME" psql -h "$DB_HOST" -qtA -v ON_ERROR_STOP=1 -U smartpot_ingest -d smartpot -c "$1"; }
root() { docker exec "$NAME" psql -qtA -v ON_ERROR_STOP=1 -U smartpot-root -d smartpot -c "$1"; }
root_db() { docker exec "$NAME" psql -qtA -v ON_ERROR_STOP=1 -U smartpot-root -d "$1" -c "$2"; }
restore_db() { root_db smartpot_restore_test "$1"; }
migrate() { docker exec "$NAME" /opt/smartpot/migrate.sh; }

# Se espera al rol de la aplicación por TCP, no por el socket UNIX. Durante la inicialización el entrypoint
# mantiene un servidor temporal que solo escucha por socket; la imagen declara un HEALTHCHECK con --start-period y
# solo abre el puerto cuando termina de aplicar el esquema y los datos demo. Así no se prueba una base a medias.
ready=0
attempts=0
while [ "$attempts" -lt 60 ]; do
    if docker exec -e PGPASSWORD="$APP_PASS" "$NAME" psql -h "$DB_HOST" -tA -U smartpot -d smartpot -c "SELECT 1" >/dev/null 2>&1; then
        ready=1
        break
    fi
    attempts=$((attempts + 1))
    sleep 2
done
if [ "$ready" -ne 1 ]; then
    echo "FAIL application role could not connect over TCP within 120 seconds"
    docker logs "$NAME" 2>&1 | tail -40 || true
    exit 1
fi

# El HEALTHCHECK también debe estar sano: confirma que el servidor definitivo responde en 127.0.0.1 y que el
# período de arranque declarado por la imagen ya terminó. Si el contenedor se declara unhealthy, se aborta.
health=""
attempts=0
while [ "$attempts" -lt 30 ]; do
    health=$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null | tr -d '\r' || true)
    [ "$health" = "healthy" ] && break
    if [ "$health" = "unhealthy" ]; then
        break
    fi
    attempts=$((attempts + 1))
    sleep 2
done
if [ "$health" != "healthy" ]; then
    echo "FAIL container health is '$health' (expected healthy after start period)"
    docker logs "$NAME" 2>&1 | tail -40 || true
    exit 1
fi

checks=0
fail=0

# check <nombre> <obtenido> <esperado>. Todos los nombres y mensajes van en inglés; los comentarios, en español.
check() {
    checks=$((checks + 1))
    if [ "$2" = "$3" ]; then
        printf 'OK   %s\n' "$1"
    else
        printf 'FAIL %s (expected %s, got %s)\n' "$1" "$3" "$2"
        fail=1
    fi
}

first_line() { printf '%s\n' "$1" | head -n 1; }

check "container healthcheck is healthy" "$health" "healthy"

# Ejecuta una consulta con el rol indicado y devuelve su salida, o la primera línea del error si falla. Evita que
# un fallo inesperado de psql aborte el script sin imprimir el FAIL correspondiente.
sql_value() {
    value_role=$1
    value_sql=$2
    if value_out=$("$value_role" "$value_sql" 2>&1); then
        printf '%s' "$value_out"
    else
        printf 'ERROR: %s' "$(first_line "$value_out")"
    fi
}

# Comprueba que una sentencia es rechazada por el motor. Exige un ERROR real (no un fallo de autenticación, que
# psql reporta como FATAL) y, si se indica, que el mensaje mencione la restricción esperada.
expect_rejected() {
    expect_name=$1
    expect_role=$2
    expect_sql=$3
    expect_pattern=${4:-}
    if expect_output=$("$expect_role" "$expect_sql" 2>&1); then
        check "$expect_name" "success" "rejection"
        return
    fi
    case "$expect_output" in
        *"ERROR:"*) ;;
        *)
            check "$expect_name" "$(first_line "$expect_output")" "SQL ERROR"
            return
            ;;
    esac
    if [ -n "$expect_pattern" ]; then
        case "$expect_output" in
            *"$expect_pattern"*) check "$expect_name" "rejected" "rejected" ;;
            *) check "$expect_name" "$(first_line "$expect_output")" "error mentioning $expect_pattern" ;;
        esac
    else
        check "$expect_name" "rejected" "rejected"
    fi
}

# Comprueba que una sentencia se acepta. Si se espera una salida (por ejemplo un RETURNING), también la compara.
expect_ok() {
    expect_name=$1
    expect_role=$2
    expect_sql=$3
    expect_expected=${4:-}
    if expect_output=$("$expect_role" "$expect_sql" 2>&1); then
        if [ -n "$expect_expected" ]; then
            check "$expect_name" "$expect_output" "$expect_expected"
        else
            check "$expect_name" "ok" "ok"
        fi
    else
        check "$expect_name" "$(first_line "$expect_output")" "success"
    fi
}

# migrate.sh devuelve el estado de docker exec; se captura para poder comprobar el código y el contenido sin que
# `set -e` corte la validación antes de imprimir el FAIL.
run_migrate() {
    if migrate_out=$(migrate 2>&1); then
        migrate_rc=0
    else
        migrate_rc=$?
    fi
    migrate_errors=$(printf '%s\n' "$migrate_out" | grep -c 'ERROR:' || true)
}

# Los doce nombres de llave foránea que debe tener el esquema. Se listan explícitamente para que un renombrado o
# una llave perdida se detecte como fallo, no como un simple cambio de cantidad.
FKS_SQL="SELECT count(*) FROM (VALUES
    ('crops', 'crops_owner_id_fkey'),
    ('readings', 'readings_crop_id_fkey'),
    ('actuators', 'actuators_crop_id_fkey'),
    ('commands', 'commands_crop_id_fkey'),
    ('commands', 'commands_actuator_id_fkey'),
    ('notifications', 'notifications_user_id_fkey'),
    ('notifications', 'notifications_crop_id_fkey'),
    ('password_reset_tokens', 'password_reset_tokens_user_id_fkey'),
    ('channel_links', 'channel_links_user_id_fkey'),
    ('crop_channels', 'crop_channels_crop_id_fkey'),
    ('virtual_devices', 'virtual_devices_crop_id_fkey'),
    ('access_tokens', 'access_tokens_user_id_fkey')
) AS expected(table_name, constraint_name)
WHERE EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = expected.table_name
      AND c.conname = expected.constraint_name
      AND c.contype = 'f'
)"

CAGGS="('readings_1m','readings_15m','readings_hourly')"

# ------------------------------------------------------------------------------
# Motor: configuración aplicada y logs limpios
# ------------------------------------------------------------------------------

# Un postgresql.auto.conf marcado como inválido deja el motor en un estado degradado aunque arranque; se revisan
# los logs completos. La línea benigna de TimescaleDB sobre la base template no coincide con estos patrones.
if log_text=$(docker logs "$NAME" 2>&1); then
    log_errors=$(printf '%s\n' "$log_text" | tr -d '\r' | grep -Ec 'postgresql\.auto\.conf contains errors|configuration file .* contains errors' || true)
else
    log_errors="docker logs failed"
fi
check "logs contain no configuration errors" "$log_errors" "0"

check "shared_buffers is 256MB" "$(sql_value root "SHOW shared_buffers")" "256MB"
check "shared_buffers needs no restart" "$(sql_value root "SELECT pending_restart FROM pg_settings WHERE name='shared_buffers'")" "f"

# ------------------------------------------------------------------------------
# Esquema relacional, hipertabla, índices y políticas
# ------------------------------------------------------------------------------

check "eleven base tables" \
    "$(sql_value root "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r'")" "11"

check "readings is a TimescaleDB hypertable" \
    "$(sql_value root "SELECT count(*) FROM timescaledb_information.hypertables WHERE hypertable_schema='public' AND hypertable_name='readings'")" "1"

check "compression is enabled on readings" \
    "$(sql_value root "SELECT compression_enabled FROM timescaledb_information.hypertables WHERE hypertable_schema='public' AND hypertable_name='readings'")" "t"

# segmentby por cultivo y orderby por tiempo descendente: los dos ajustes que definen el ratio de compresión.
check "compression settings segment by crop and order by time" \
    "$(sql_value root "SELECT count(*) FROM timescaledb_information.compression_settings WHERE hypertable_schema='public' AND hypertable_name='readings' AND ((attname='crop_id' AND segmentby_column_index=1) OR (attname='measured_at' AND orderby_column_index=1 AND orderby_asc=false))")" "2"

check "compression policy exists" \
    "$(sql_value root "SELECT count(*) FROM timescaledb_information.jobs WHERE proc_name='policy_compression' AND hypertable_schema='public' AND hypertable_name='readings'")" "1"

check "base retention policy keeps 365 days" \
    "$(sql_value root "SELECT count(*) FROM timescaledb_information.jobs WHERE proc_name='policy_retention' AND hypertable_schema='public' AND hypertable_name='readings' AND config->>'drop_after'='365 days'")" "1"

check "obsolete readings_crop_measured index is absent" \
    "$(sql_value root "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='readings_crop_measured'")" "0"

check "covering readings_crop_measured_covering index exists" \
    "$(sql_value root "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='readings_crop_measured_covering'")" "1"

check "all twelve foreign keys exist" "$(sql_value root "$FKS_SQL")" "12"

check "trainer_readings is a security_barrier view" \
    "$(sql_value root "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='trainer_readings' AND c.relkind='v' AND c.reloptions @> ARRAY['security_barrier=true']")" "1"

check "three continuous aggregates exist" \
    "$(sql_value root "SELECT count(*) FROM timescaledb_information.continuous_aggregates WHERE view_schema='public' AND view_name IN $CAGGS")" "3"

check "each continuous aggregate has the seven count columns" \
    "$(sql_value root "SELECT count(*) FROM (SELECT c.relname FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname IN $CAGGS AND a.attname IN ('count_temperature','count_humidity','count_brightness','count_ph','count_tds','count_atmosphere','count_soil_moisture') AND a.attnum>0 AND NOT a.attisdropped GROUP BY c.relname HAVING count(*)=7) grouped")" "3"

check "continuous aggregates include real-time data" \
    "$(sql_value root "SELECT count(*) FROM timescaledb_information.continuous_aggregates WHERE view_schema='public' AND view_name IN $CAGGS AND materialized_only=false")" "3"

check "four retention policies cover hypertable and aggregates" \
    "$(sql_value root "SELECT count(*) FROM timescaledb_information.jobs WHERE proc_name='policy_retention' AND config->>'drop_after'='365 days'")" "4"

check "three retention policies run on continuous aggregates" \
    "$(sql_value root "SELECT count(*) FROM timescaledb_information.jobs j JOIN timescaledb_information.continuous_aggregates ca ON ca.materialization_hypertable_schema=j.hypertable_schema AND ca.materialization_hypertable_name=j.hypertable_name WHERE j.proc_name='policy_retention' AND j.config->>'drop_after'='365 days'")" "3"

# Actualización desde una base heredada: el agregado de 1 minuto existía sin los contadores por métrica. El bloque
# DO de schema.sql debe detectarlo, quitar sus políticas, eliminarlo y recrearlo con la definición nueva.
root "DROP MATERIALIZED VIEW readings_1m" >/dev/null
root "CREATE MATERIALIZED VIEW readings_1m WITH (timescaledb.continuous) AS SELECT crop_id, time_bucket('1 minute', measured_at) AS bucket, count(*) AS reading_count FROM readings GROUP BY crop_id, bucket WITH NO DATA" >/dev/null
root "ALTER MATERIALIZED VIEW readings_1m SET (timescaledb.materialized_only = false)" >/dev/null
root "SELECT add_continuous_aggregate_policy('readings_1m', INTERVAL '2 hours', INTERVAL '1 minute', INTERVAL '1 minute', TRUE)" >/dev/null
check "legacy aggregate lacks the new count columns" \
    "$(sql_value root "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='readings_1m' AND column_name='count_temperature'")" "0"

run_migrate
check "legacy aggregate migration exits 0" "$migrate_rc" "0"
check "legacy aggregate migration has no ERROR output" "$migrate_errors" "0"
check "legacy aggregate migration recreates the count columns" \
    "$(sql_value root "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='readings_1m' AND column_name='count_temperature'")" "1"
check "legacy aggregate migration restores its retention policy" \
    "$(sql_value root "SELECT count(*) FROM timescaledb_information.jobs WHERE proc_name='policy_retention' AND config->>'drop_after'='365 days'")" "4"

# ------------------------------------------------------------------------------
# Datos demo: se cuentan antes de crear cualquier fila de prueba para que el número sea exacto
# ------------------------------------------------------------------------------

if [ "$DEMO" = "true" ]; then
    check "demo account exists" \
        "$(sql_value root "SELECT count(*) FROM users WHERE email='demo@smartpot.app'")" "1"
    check "demo seed creates two crops" \
        "$(sql_value root "SELECT count(*) FROM crops")" "2"
    check "both demo crops are outdoor crops in Medellin" \
        "$(sql_value root "SELECT count(*) FROM crops WHERE placement->>'setting'='OUTDOOR' AND placement->'location'->>'name'='Medellín'")" "2"
    check "demo seed creates 576 readings (48 h every 10 min)" \
        "$(sql_value root "SELECT count(*) FROM readings")" "576"
else
    check "empty seed leaves no crops" \
        "$(sql_value root "SELECT count(*) FROM crops")" "0"
fi

# ------------------------------------------------------------------------------
# Fixtures: usuario, cultivo y actuador propios para no tocar los ids demo
# ------------------------------------------------------------------------------

FIX_USER=0123456789abcdef01234560
FIX_CROP=0123456789abcdef01234561
FIX_ACT=0123456789abcdef01234562
FIX_CMD=0123456789abcdef01234563
FIX_READ=0123456789abcdef01234564
FIX_VD=0123456789abcdef01234565
FIX_CC=0123456789abcdef01234566
FIX_LINK=0123456789abcdef01234567
FIX_TOKEN=0123456789abcdef01234568
FIX_RESET=0123456789abcdef01234569
FIX_NOTIF=0123456789abcdef0123456a
INGEST_READ=0123456789abcdef0123456b
OLD_READ=0123456789abcdef0123456c
DUP_CMD_1=0123456789abcdef0123456d
DUP_CMD_2=0123456789abcdef0123456e
DUP_CMD_3=0123456789abcdef0123456f
DURATION_BAD=0123456789abcdef01234570
DURATION_OK=0123456789abcdef01234571
VD_OK=0123456789abcdef01234572
VD_BAD=0123456789abcdef01234573
CC_BAD0=0123456789abcdef01234574
CC_BAD25=0123456789abcdef01234575
CC_OK=0123456789abcdef01234576
LINK_BAD=0123456789abcdef01234577
CROP_BAD=0123456789abcdef01234579
NOTIF_BAD=0123456789abcdef0123457a
PH_BAD=0123456789abcdef0123457b
HUM_BAD=0123456789abcdef0123457c
NULL_READ=0123456789abcdef0123457d
READER_READ=0123456789abcdef0123457e
NEW_DUP_CMD=0123456789abcdef01234580
REJECT_CMD=0123456789abcdef01234581
BAD_USER=zzzzzzzzzzzzzzzzzzzzzzzz
BAD_OWNER=u
MISSING_CROP=000000000000000000000000

# El usuario de prueba lo inserta el rol de la aplicación: así se valida a la vez que puede escribir usuarios.
expect_ok "application role inserts a valid user" app \
    "INSERT INTO users (id,email,password_hash,role,created_at) VALUES ('$FIX_USER','ci-validation@example.com',repeat('x',60),'USER',now()) RETURNING 'ok'" "ok"

expect_rejected "application role cannot create tables" app \
    "CREATE TABLE ci_denied (id int)" "permission denied"

# El cultivo y el actuador son la base de casi todas las pruebas de restricciones y permisos.
# Aislamiento multi-tenant con RLS fail-closed: sin contexto de tenant la consulta falla cerrada (0 filas)
check "fail-closed: querying crops without tenant context returns 0 rows" \
    "$(sql_value app "SELECT count(*) FROM crops")" "0"

expect_rejected "fail-closed: inserting crop without tenant context is rejected by RLS" app \
    "INSERT INTO crops (id,owner_id,name,type,kind,form,automation_enabled,created_at) VALUES ('$FIX_CROP','$FIX_USER','CI Validation Crop','LETTUCE','REAL','NFT',false,now())" "violates row-level security policy"

# Con contexto de tenant activo para el dueño, la inserción y lectura son autorizadas:
app "SELECT set_tenant_context('$FIX_USER'); INSERT INTO crops (id,owner_id,name,type,kind,form,automation_enabled,created_at) VALUES ('$FIX_CROP','$FIX_USER','CI Validation Crop','LETTUCE','REAL','NFT',false,now())" >/dev/null
app "INSERT INTO actuators (id,crop_id,type,active,created_at) VALUES ('$FIX_ACT','$FIX_CROP','FAN',false,now())" >/dev/null

check "tenant context isolates crops for matching owner" \
    "$(sql_value app "SELECT set_tenant_context('$FIX_USER'); SELECT count(*) FROM crops WHERE id='$FIX_CROP'")" "1"

check "tenant context isolates crops for non-matching owner" \
    "$(sql_value app "SELECT set_tenant_context('0123456789abcdef01234599'); SELECT count(*) FROM crops WHERE id='$FIX_CROP'")" "0"

check "clearing tenant context resets to fail-closed" \
    "$(sql_value app "SELECT set_tenant_context(''); SELECT count(*) FROM crops WHERE id='$FIX_CROP'")" "0"

# ------------------------------------------------------------------------------
# Un solo comando en vuelo por actuador y reconciliación previa de migrate.sh
# ------------------------------------------------------------------------------

expect_ok "valid PENDING command is accepted" app \
    "INSERT INTO commands (id,crop_id,actuator_id,actuator_type,action,duration_seconds,status,source,created_at) VALUES ('$FIX_CMD','$FIX_CROP','$FIX_ACT','FAN','ACTIVATE',10,'PENDING','USER',now()) RETURNING 'ok'" "ok"

expect_rejected "second in-flight command for the same actuator is rejected" app \
    "INSERT INTO commands (id,crop_id,actuator_id,actuator_type,action,status,source,created_at) VALUES ('$REJECT_CMD','$FIX_CROP','$FIX_ACT','FAN','ACTIVATE','SENT','USER',now())" "commands_one_inflight_per_actuator"

# Se simula una base heredada: sin el índice único pueden existir duplicados en vuelo. migrate.sh debe conservar
# el más reciente, expirar el resto y volver a crear el índice antes de aceptar nuevas escrituras.
root "DROP INDEX IF EXISTS public.commands_one_inflight_per_actuator" >/dev/null
root "INSERT INTO commands (id,crop_id,actuator_id,actuator_type,action,status,source,created_at) VALUES ('$DUP_CMD_1','$FIX_CROP','$FIX_ACT','FAN','ACTIVATE','PENDING','USER',now() - interval '2 minutes'), ('$DUP_CMD_2','$FIX_CROP','$FIX_ACT','FAN','ACTIVATE','SENT','AGENT',now() - interval '1 minute')" >/dev/null
check "preflight starts with three in-flight commands" \
    "$(sql_value root "SELECT count(*) FROM commands WHERE actuator_id='$FIX_ACT' AND status IN ('PENDING','SENT')")" "3"

run_migrate
check "preflight migration exits 0" "$migrate_rc" "0"
check "preflight migration has no ERROR output" "$migrate_errors" "0"
check "preflight leaves one in-flight command per actuator" \
    "$(sql_value root "SELECT count(*) FROM commands WHERE actuator_id='$FIX_ACT' AND status IN ('PENDING','SENT')")" "1"
check "preflight expires the duplicate commands" \
    "$(sql_value root "SELECT count(*) FROM commands WHERE id IN ('$DUP_CMD_1','$DUP_CMD_2') AND status='EXPIRED'")" "2"
check "preflight recreates the unique partial index" \
    "$(sql_value root "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='commands_one_inflight_per_actuator'")" "1"
expect_rejected "new duplicate is rejected after preflight" root \
    "INSERT INTO commands (id,crop_id,actuator_id,actuator_type,action,status,source,created_at) VALUES ('$NEW_DUP_CMD','$FIX_CROP','$FIX_ACT','FAN','ACTIVATE','PENDING','USER',now())" "commands_one_inflight_per_actuator"

# ------------------------------------------------------------------------------
# Restricciones de rango y de formato
# ------------------------------------------------------------------------------

expect_rejected "readings rejects ph 99" app \
    "INSERT INTO readings (id,crop_id,measured_at,source,ph) VALUES ('$PH_BAD','$FIX_CROP',now(),'MQTT',99)" "readings_ph_range_check"

expect_rejected "readings rejects humidity 999" app \
    "INSERT INTO readings (id,crop_id,measured_at,source,humidity) VALUES ('$HUM_BAD','$FIX_CROP',now(),'MQTT',999)" "readings_humidity_range_check"

expect_rejected "readings rejects a row with every metric NULL" app \
    "INSERT INTO readings (id,crop_id,measured_at,source) VALUES ('$NULL_READ','$FIX_CROP',now(),'MQTT')" "readings_metric_present_check"

expect_ok "readings accepts every physical boundary value" app \
    "INSERT INTO readings (id,crop_id,measured_at,source,temperature,humidity,brightness,ph,tds,atmosphere,soil_moisture) VALUES ('$FIX_READ','$FIX_CROP',now(),'HTTP',60,100,0,0,0,1100,100) RETURNING 'ok'" "ok"

expect_rejected "commands reject duration_seconds -5" app \
    "INSERT INTO commands (id,crop_id,actuator_id,actuator_type,action,duration_seconds,status,source,created_at) VALUES ('$DURATION_BAD','$FIX_CROP','$FIX_ACT','FAN','ACTIVATE',-5,'EXECUTED','USER',now())" "commands_duration_seconds_check"

expect_ok "commands accept duration_seconds 1" app \
    "INSERT INTO commands (id,crop_id,actuator_id,actuator_type,action,duration_seconds,status,source,created_at) VALUES ('$DURATION_OK','$FIX_CROP','$FIX_ACT','FAN','ACTIVATE',1,'EXECUTED','USER',now()) RETURNING 'ok'" "ok"

expect_rejected "virtual devices reject interval_seconds 0" app \
    "INSERT INTO virtual_devices (id,crop_id,owner_id,mode,interval_seconds,created_at,updated_at) VALUES ('$VD_BAD','$FIX_CROP','$FIX_USER','AUTO',0,now(),now())" "virtual_devices_interval_seconds_check"

expect_ok "virtual devices accept interval_seconds 30" app \
    "INSERT INTO virtual_devices (id,crop_id,owner_id,mode,interval_seconds,created_at,updated_at) VALUES ('$VD_OK','$FIX_CROP','$FIX_USER','AUTO',30,now(),now()) RETURNING 'ok'" "ok"

expect_rejected "crop channels reject digest_hours 0" app \
    "INSERT INTO crop_channels (id,crop_id,owner_id,type,enabled,delivery,digest_hours) VALUES ('$CC_BAD0','$FIX_CROP','$FIX_USER','TELEGRAM',true,'DIGEST',0)" "crop_channels_digest_hours_check"

expect_rejected "crop channels reject digest_hours 25" app \
    "INSERT INTO crop_channels (id,crop_id,owner_id,type,enabled,delivery,digest_hours) VALUES ('$CC_BAD25','$FIX_CROP','$FIX_USER','TELEGRAM',true,'DIGEST',25)" "crop_channels_digest_hours_check"

expect_ok "crop channels accept digest_hours 1" app \
    "INSERT INTO crop_channels (id,crop_id,owner_id,type,enabled,delivery,digest_hours) VALUES ('$CC_OK','$FIX_CROP','$FIX_USER','TELEGRAM',true,'DIGEST',1) RETURNING 'ok'" "ok"

expect_ok "crop channels accept digest_hours 24" app \
    "UPDATE crop_channels SET digest_hours=24 WHERE id='$CC_OK' RETURNING 'ok'" "ok"

expect_rejected "channel links reject failures -1" app \
    "INSERT INTO channel_links (id,user_id,type,address,enabled,failures) VALUES ('$LINK_BAD','$FIX_USER','TELEGRAM','ci-failures',true,-1)" "channel_links_failures_check"

expect_rejected "non-hex user id is rejected by the format check" app \
    "INSERT INTO users (id,email,password_hash,role,created_at) VALUES ('$BAD_USER','ci-bad-id@example.com',repeat('x',60),'USER',now())" "users_id_format_check"

expect_rejected "crop owner id must be a 24 character hex ObjectId" app \
    "SELECT set_tenant_context('$BAD_OWNER'); INSERT INTO crops (id,owner_id,name,type,automation_enabled,created_at) VALUES ('$CROP_BAD','$BAD_OWNER','Bad Owner Crop','LETTUCE',false,now())" "crops_owner_id_format_check"

expect_rejected "notification with a non-existent crop is rejected" app \
    "INSERT INTO notifications (id,user_id,crop_id,type,title,message,read,created_at) VALUES ('$NOTIF_BAD','$FIX_USER','$MISSING_CROP','INFO','x','y',false,now())" "notifications_crop_id_fkey"

# ------------------------------------------------------------------------------
# Cascadas de borrado del cultivo y del usuario
# ------------------------------------------------------------------------------

CASCADE_USER=fedcba9876543210fedcba90
CASCADE_CROP=fedcba9876543210fedcba91
CASCADE_ACT=fedcba9876543210fedcba92
CASCADE_CMD=fedcba9876543210fedcba93
CASCADE_READ=fedcba9876543210fedcba94
CASCADE_VD=fedcba9876543210fedcba95
CASCADE_CC=fedcba9876543210fedcba96
CASCADE_NOTIF=fedcba9876543210fedcba97
CASCADE_RESET=fedcba9876543210fedcba98
CASCADE_CROP2=fedcba9876543210fedcba99
CASCADE_LINK=fedcba9876543210fedcba9a
CASCADE_TOKEN=fedcba9876543210fedcba9b

# Fixtures de cascada: el cultivo y el usuario se borran en dos pruebas distintas, y el segundo cultivo permite
# comprobar que borrar el usuario también elimina sus cultivos.
root "INSERT INTO users (id,email,password_hash,role,created_at) VALUES ('$CASCADE_USER','ci-cascade@example.com',repeat('x',60),'USER',now())" >/dev/null
root "INSERT INTO crops (id,owner_id,name,type,kind,form,automation_enabled,created_at) VALUES ('$CASCADE_CROP','$CASCADE_USER','Cascade Crop','BASIL','REAL','POT',false,now()), ('$CASCADE_CROP2','$CASCADE_USER','Cascade Crop Two','BASIL','VIRTUAL','POT',false,now())" >/dev/null
root "INSERT INTO readings (id,crop_id,measured_at,source,temperature) VALUES ('$CASCADE_READ','$CASCADE_CROP',now(),'MQTT',22)" >/dev/null
root "INSERT INTO actuators (id,crop_id,type,active,created_at) VALUES ('$CASCADE_ACT','$CASCADE_CROP','FAN',false,now())" >/dev/null
root "INSERT INTO commands (id,crop_id,actuator_id,actuator_type,action,duration_seconds,status,source,created_at) VALUES ('$CASCADE_CMD','$CASCADE_CROP','$CASCADE_ACT','FAN','ACTIVATE',5,'EXECUTED','USER',now())" >/dev/null
root "INSERT INTO virtual_devices (id,crop_id,owner_id,mode,interval_seconds,created_at,updated_at) VALUES ('$CASCADE_VD','$CASCADE_CROP','$CASCADE_USER','AUTO',60,now(),now())" >/dev/null
root "INSERT INTO crop_channels (id,crop_id,owner_id,type,enabled,delivery,digest_hours) VALUES ('$CASCADE_CC','$CASCADE_CROP','$CASCADE_USER','TELEGRAM',true,'DIGEST',6)" >/dev/null
root "INSERT INTO notifications (id,user_id,crop_id,type,title,message,read,created_at) VALUES ('$CASCADE_NOTIF','$CASCADE_USER','$CASCADE_CROP','INFO','Cascade','Cascade',false,now())" >/dev/null
root "INSERT INTO password_reset_tokens (id,token_hash,user_id,expires_at) VALUES ('$CASCADE_RESET','ci-cascade-hash','$CASCADE_USER',now() + interval '1 hour')" >/dev/null
root "INSERT INTO channel_links (id,user_id,type,address,enabled,failures) VALUES ('$CASCADE_LINK','$CASCADE_USER','TELEGRAM','ci-cascade-link',true,0)" >/dev/null
root "INSERT INTO access_tokens (id,user_id,name,token_hash,prefix,scope,created_at) VALUES ('$CASCADE_TOKEN','$CASCADE_USER','CI','ci-cascade-token','spt_ci','READ',now())" >/dev/null

root "DELETE FROM crops WHERE id='$CASCADE_CROP'" >/dev/null
check "deleting a crop cascades readings" \
    "$(sql_value root "SELECT count(*) FROM readings WHERE crop_id='$CASCADE_CROP'")" "0"
check "deleting a crop cascades actuators" \
    "$(sql_value root "SELECT count(*) FROM actuators WHERE crop_id='$CASCADE_CROP'")" "0"
check "deleting a crop cascades commands" \
    "$(sql_value root "SELECT count(*) FROM commands WHERE crop_id='$CASCADE_CROP'")" "0"
check "deleting a crop cascades virtual devices" \
    "$(sql_value root "SELECT count(*) FROM virtual_devices WHERE crop_id='$CASCADE_CROP'")" "0"
check "deleting a crop cascades crop channels" \
    "$(sql_value root "SELECT count(*) FROM crop_channels WHERE crop_id='$CASCADE_CROP'")" "0"
check "deleting a crop keeps the notification with a null crop" \
    "$(sql_value root "SELECT count(*) FROM notifications WHERE id='$CASCADE_NOTIF' AND crop_id IS NULL")" "1"

root "DELETE FROM users WHERE id='$CASCADE_USER'" >/dev/null
check "deleting a user cascades crops" \
    "$(sql_value root "SELECT count(*) FROM crops WHERE owner_id='$CASCADE_USER'")" "0"
check "deleting a user cascades notifications" \
    "$(sql_value root "SELECT count(*) FROM notifications WHERE user_id='$CASCADE_USER'")" "0"
check "deleting a user cascades password reset tokens" \
    "$(sql_value root "SELECT count(*) FROM password_reset_tokens WHERE user_id='$CASCADE_USER'")" "0"
check "deleting a user cascades channel links" \
    "$(sql_value root "SELECT count(*) FROM channel_links WHERE user_id='$CASCADE_USER'")" "0"
check "deleting a user cascades access tokens" \
    "$(sql_value root "SELECT count(*) FROM access_tokens WHERE user_id='$CASCADE_USER'")" "0"

# ------------------------------------------------------------------------------
# Permisos de los tres roles de la plataforma y de un rol sin privilegios
# ------------------------------------------------------------------------------

# La contraseña se valida por TCP contra la IP del contenedor, no por el socket local.
if docker exec -e PGPASSWORD=wrong-password "$NAME" psql -h "$DB_HOST" -qtA -U smartpot -d smartpot -c "SELECT 1" >/dev/null 2>&1; then
    wrong_app_auth=accepted
else
    wrong_app_auth=rejected
fi
check "wrong application password is rejected" "$wrong_app_auth" "rejected"

# La agregación en tiempo real incluye lo aún no materializado; tras refrescar debe devolver filas tanto con el
# seed demo como con las lecturas de prueba. Se ejecuta antes de tocar la compresión.
root "CALL refresh_continuous_aggregate('readings_1m', NULL, NULL)" >/dev/null
check "sampled continuous aggregate returns rows after refresh" \
    "$(sql_value root "SELECT count(*) > 0 FROM readings_1m")" "t"

check "reader role selects readings" \
    "$(sql_value reader "SELECT count(*) >= 0 FROM readings")" "t"
check "reader role selects the trainer view" \
    "$(sql_value reader "SELECT count(*) >= 0 FROM trainer_readings")" "t"
check "reader role selects crops anonymously despite RLS" \
    "$(sql_value reader "SELECT count(*) >= 0 FROM crops")" "t"
expect_rejected "reader role cannot select crops.owner_id" reader \
    "SELECT owner_id FROM crops" "permission denied"
expect_rejected "reader role cannot select crops.device" reader \
    "SELECT device FROM crops" "permission denied"
expect_rejected "reader role cannot select users" reader \
    "SELECT count(*) FROM users" "permission denied"
expect_rejected "reader role cannot select access tokens" reader \
    "SELECT count(*) FROM access_tokens" "permission denied"
expect_rejected "reader role cannot select password reset tokens" reader \
    "SELECT count(*) FROM password_reset_tokens" "permission denied"
check "reader role has no INSERT grant on readings" \
    "$(sql_value root "SELECT has_table_privilege('smartpot_reader','readings','INSERT')")" "f"
expect_rejected "reader role cannot insert readings" reader \
    "INSERT INTO readings (id,crop_id,measured_at,source,temperature) VALUES ('$READER_READ','$FIX_CROP',now(),'MQTT',23.5)" "read-only transaction"

expect_ok "ingest role inserts a reading" ingest \
    "INSERT INTO readings (id,crop_id,measured_at,source,temperature) VALUES ('$INGEST_READ','$FIX_CROP',now(),'HTTP',23.5) RETURNING 'ok'" "ok"
expect_rejected "ingest role cannot insert commands" ingest \
    "INSERT INTO commands (id,crop_id,actuator_id,actuator_type,action,status,source,created_at) VALUES ('$DURATION_BAD','$FIX_CROP','$FIX_ACT','FAN','ACTIVATE','EXECUTED','USER',now())" "permission denied"
expect_rejected "ingest role cannot update readings" ingest \
    "UPDATE readings SET temperature=20 WHERE id='$INGEST_READ'" "permission denied"
expect_rejected "ingest role cannot delete readings" ingest \
    "DELETE FROM readings WHERE id='$INGEST_READ'" "permission denied"
expect_rejected "ingest role cannot select users" ingest \
    "SELECT count(*) FROM users" "permission denied"

root "CREATE ROLE ci_nobody LOGIN" >/dev/null
check "role without grants has no CONNECT or schema USAGE" \
    "$(sql_value root "SELECT has_database_privilege('ci_nobody', current_database(), 'CONNECT')::text || '|' || has_schema_privilege('ci_nobody','public','USAGE')::text")" "false|false"
root "DROP ROLE ci_nobody" >/dev/null

# ------------------------------------------------------------------------------
# Migración idempotente
# ------------------------------------------------------------------------------

run_migrate
check "first idempotent migration exits 0" "$migrate_rc" "0"
check "first idempotent migration has no ERROR output" "$migrate_errors" "0"
run_migrate
check "second idempotent migration exits 0" "$migrate_rc" "0"
check "second idempotent migration has no ERROR output" "$migrate_errors" "0"

# ------------------------------------------------------------------------------
# Ruta destructiva: quitar la llave foránea con compresión activa y migrar
# ------------------------------------------------------------------------------

# Una lectura de hace 40 días garantiza un fragmento fuera de la ventana de 12 h, que es el que se comprime.
root "INSERT INTO readings (id,crop_id,measured_at,source,temperature) VALUES ('$OLD_READ','$FIX_CROP',now() - interval '40 days','MQTT',21.5)" >/dev/null

# Se reproduce el estado que migrate.sh debe reparar: descompresión total, compresión desactivada y llave ausente.
root "SELECT decompress_chunk(chunk, TRUE) FROM show_chunks('readings') AS chunk" >/dev/null
root "ALTER TABLE readings SET (timescaledb.compress = FALSE)" >/dev/null
root "ALTER TABLE readings DROP CONSTRAINT readings_crop_id_fkey" >/dev/null
check "destructive test removes the readings foreign key" \
    "$(sql_value root "SELECT count(*) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace WHERE n.nspname='public' AND t.relname='readings' AND c.conname='readings_crop_id_fkey'")" "0"

# Se vuelve a activar la compresión y se comprimen los fragmentos antiguos; migrate.sh debe detectar la llave
# ausente, descomprimir, aplicar el esquema y recompresión lo antiguo.
root "ALTER TABLE readings SET (timescaledb.compress, timescaledb.compress_segmentby = 'crop_id', timescaledb.compress_orderby = 'measured_at DESC')" >/dev/null
root "SELECT compress_chunk(chunk, TRUE) FROM show_chunks('readings', now() - interval '12 hours') AS chunk" >/dev/null
check "destructive test leaves compression enabled" \
    "$(sql_value root "SELECT compression_enabled FROM timescaledb_information.hypertables WHERE hypertable_schema='public' AND hypertable_name='readings'")" "t"
check "destructive test compresses at least one chunk" \
    "$(sql_value root "SELECT count(*) > 0 FROM timescaledb_information.chunks WHERE hypertable_name='readings' AND is_compressed")" "t"

run_migrate
check "compression recovery migration exits 0" "$migrate_rc" "0"
check "compression recovery migration has no ERROR output" "$migrate_errors" "0"
check "compression recovery restores the readings foreign key" \
    "$(sql_value root "SELECT count(*) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace WHERE n.nspname='public' AND t.relname='readings' AND c.conname='readings_crop_id_fkey'")" "1"
check "compression recovery re-enables compression" \
    "$(sql_value root "SELECT compression_enabled FROM timescaledb_information.hypertables WHERE hypertable_schema='public' AND hypertable_name='readings'")" "t"
check "compression recovery recompresses old chunks" \
    "$(sql_value root "SELECT count(*) > 0 FROM timescaledb_information.chunks WHERE hypertable_name='readings' AND is_compressed")" "t"
check "compression recovery keeps the fixture readings" \
    "$(sql_value root "SELECT count(*) > 0 FROM readings WHERE crop_id='$FIX_CROP'")" "t"

# ------------------------------------------------------------------------------
# Respaldo y restauración (DRP): dump físico, pre/post restore y verificación en una base temporal
# ------------------------------------------------------------------------------

DUMP_PATH=/tmp/smartpot-drp.dump
READINGS_SIGNATURE_SQL="SELECT md5(string_agg(id || ':' || coalesce(temperature::text,'') || ':' || coalesce(ph::text,''), ',' ORDER BY id)) FROM readings"
source_count=$(sql_value root "SELECT count(*) FROM readings")
source_signature=$(sql_value root "$READINGS_SIGNATURE_SQL")

if dump_out=$(docker exec "$NAME" pg_dump -U smartpot-root -d smartpot -Fc -f "$DUMP_PATH" 2>&1); then
    dump_rc=0
else
    dump_rc=$?
fi
check "pg_dump completes without error" "$dump_rc" "0"

if toc_out=$(docker exec "$NAME" pg_restore --list "$DUMP_PATH" 2>&1); then
    toc_rc=0
else
    toc_rc=$?
fi
toc_lines=$(printf '%s\n' "$toc_out" | wc -l | tr -d ' ')
check "pg_restore can read the dump TOC" "$toc_rc" "0"
check "dump TOC is not empty" "$([ "$toc_lines" -gt 0 ] && echo yes || echo no)" "yes"

# La base temporal se crea vacía y con la extensión antes de restaurar: TimescaleDB exige pre_restore para que
# las tablas internas y los fragmentos comprimidos se reconstruyan con los identificadores correctos.
root "DROP DATABASE IF EXISTS smartpot_restore_test WITH (FORCE)" >/dev/null
root "CREATE DATABASE smartpot_restore_test" >/dev/null
root_db smartpot_restore_test "CREATE EXTENSION IF NOT EXISTS timescaledb" >/dev/null
root_db smartpot_restore_test "SELECT timescaledb_pre_restore()" >/dev/null

# pg_restore se ejecuta como root dentro del contenedor, igual que el procedimiento documentado y probado.
if restore_out=$(docker exec "$NAME" pg_restore -U smartpot-root -d smartpot_restore_test --exit-on-error --no-owner "$DUMP_PATH" 2>&1); then
    restore_rc=0
else
    restore_rc=$?
fi
check "pg_restore completes with --exit-on-error" "$restore_rc" "0"

# post_restore debe ejecutarse antes de contar: con fragmentos comprimidos, contar antes devuelve un número
# incorrecto porque las tablas internas todavía no están reconciliadas.
check "timescaledb_post_restore succeeds" \
    "$(sql_value restore_db "SELECT timescaledb_post_restore()")" "t"

check "restored readings count matches the source" \
    "$(sql_value restore_db "SELECT count(*) FROM readings")" "$source_count"
check "restored readings keep the source signature" \
    "$(sql_value restore_db "$READINGS_SIGNATURE_SQL")" "$source_signature"
check "restored database has one readings hypertable" \
    "$(sql_value restore_db "SELECT count(*) FROM timescaledb_information.hypertables WHERE hypertable_schema='public' AND hypertable_name='readings'")" "1"
check "restored database has three continuous aggregates" \
    "$(sql_value restore_db "SELECT count(*) FROM timescaledb_information.continuous_aggregates WHERE view_schema='public' AND view_name IN $CAGGS")" "3"
check "restored database has three aggregate retention policies" \
    "$(sql_value restore_db "SELECT count(*) FROM timescaledb_information.jobs j JOIN timescaledb_information.continuous_aggregates ca ON ca.materialization_hypertable_schema=j.hypertable_schema AND ca.materialization_hypertable_name=j.hypertable_name WHERE j.proc_name='policy_retention' AND j.config->>'drop_after'='365 days'")" "3"
check "restored database has all twelve foreign keys" \
    "$(sql_value restore_db "$FKS_SQL")" "12"

root "DROP DATABASE smartpot_restore_test WITH (FORCE)" >/dev/null
check "temporary restore database is dropped" \
    "$(sql_value root "SELECT count(*) FROM pg_database WHERE datname='smartpot_restore_test'")" "0"

# ------------------------------------------------------------------------------
# Limpieza de fixtures
# ------------------------------------------------------------------------------

# Borrar el usuario de prueba elimina en cascada su cultivo, lecturas, comandos y demás filas; el usuario de
# cascada ya se borró en su prueba. Al final la base queda como al inicio (solo el seed demo, si se pidió).
root "DELETE FROM users WHERE id IN ('$FIX_USER','$CASCADE_USER')" >/dev/null
check "test fixtures are removed" \
    "$(sql_value root "SELECT (SELECT count(*) FROM users WHERE id IN ('$FIX_USER','$CASCADE_USER')) + (SELECT count(*) FROM crops WHERE id IN ('$FIX_CROP','$CASCADE_CROP','$CASCADE_CROP2')) + (SELECT count(*) FROM readings WHERE crop_id IN ('$FIX_CROP','$CASCADE_CROP','$CASCADE_CROP2')) + (SELECT count(*) FROM commands WHERE crop_id IN ('$FIX_CROP','$CASCADE_CROP','$CASCADE_CROP2'))")" "0"

# ------------------------------------------------------------------------------
# Resumen
# ------------------------------------------------------------------------------

if [ "$fail" -ne 0 ]; then
    echo "Some checks failed; container logs follow:"
    docker logs "$NAME" 2>&1 | tail -40 || true
    exit 1
fi

echo "All $checks checks passed"
exit 0
