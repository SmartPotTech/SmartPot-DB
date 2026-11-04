#!/bin/sh
# Arranca la imagen endurecida y valida el esquema, la hipertabla, los permisos del usuario de la aplicación, las
# restricciones (CHECK), la migración idempotente y los datos demo.
#   sh tests/validate.sh <imagen> <true|false>
set -eu

IMAGE="${1:-smartpot-db-postgre:ci}"
DEMO="${2:-false}"
NAME="smartpot-db-postgre-validate"
APP_PASS="app-password-ci-1234"
READER_PASS="reader-ci-password-1234"
ROOT_PASS="root-password-ci-123"

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
app() { docker exec -e PGPASSWORD="$APP_PASS" "$NAME" psql -qtA -v ON_ERROR_STOP=1 -U smartpot -d smartpot -c "$1"; }
reader() { docker exec -e PGPASSWORD="$READER_PASS" "$NAME" psql -qtA -v ON_ERROR_STOP=1 -U smartpot_reader -d smartpot -c "$1"; }
root() { docker exec "$NAME" psql -qtA -v ON_ERROR_STOP=1 -U smartpot-root -d smartpot -c "$1"; }
migrate() { docker exec "$NAME" /opt/smartpot/migrate.sh; }

# Se espera a que el servidor acepte conexiones y a que el usuario de la aplicación exista (fin del init).
ok=0
for _ in $(seq 1 90); do
  if docker exec -e PGPASSWORD="$APP_PASS" "$NAME" psql -tA -U smartpot -d smartpot -c "SELECT 1" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[ "$ok" = "1" ] || { echo "FAIL application user could not connect"; docker logs "$NAME" | tail -40; exit 1; }

fail=0
check() { if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (expected $3, got $2)"; fail=1; fi; }

check "eleven tables" "$(app "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'")" "11"
check "connection scope is restricted" \
  "$(app "INSERT INTO access_tokens (id,user_id,name,token_hash,prefix,scope,created_at) VALUES ('0000000000000000000000a1','u','x','h','spt_x','ADMIN',now())" 2>&1 >/dev/null | grep -qi 'check\|violates' && echo rejected || echo accepted)" "rejected"
check "readings is a TimescaleDB hypertable" \
  "$(app "SELECT count(*) FROM timescaledb_information.hypertables WHERE hypertable_name='readings'")" "1"
check "readings has a retention policy" \
  "$(app "SELECT count(*) FROM timescaledb_information.jobs WHERE proc_name='policy_retention' AND hypertable_name='readings'")" "1"

check "application user writes to its database" \
  "$(app "INSERT INTO users (id, email, password_hash, role, created_at) VALUES ('0000000000000000000000ci','ci@example.com',repeat('x',60),'USER',now()) RETURNING 'ok'")" "ok"
check "application user cannot create tables (no DDL)" \
  "$(app 'CREATE TABLE ci_denied (id int)' 2>&1 >/dev/null | grep -qi 'permi\|denied\|permission' && echo denied || echo allowed)" "denied"

check "CHECK constraint rejects invalid role" \
  "$(app "INSERT INTO users (id,email,password_hash,role,created_at) VALUES ('0000000000000000000000r1','r1@x.co',repeat('x',60),'ROOT',now())" 2>&1 >/dev/null | grep -qi 'check\|violates' && echo rejected || echo accepted)" "rejected"
check "CHECK constraint rejects unknown simulation mode" \
  "$(app "INSERT INTO virtual_devices (id,crop_id,owner_id,mode,interval_seconds,created_at,updated_at) VALUES ('0000000000000000000000v1','c','o','RANDOM',30,now(),now())" 2>&1 >/dev/null | grep -qi 'check\|violates' && echo rejected || echo accepted)" "rejected"
check "CHECK constraint rejects invalid delivery mode" \
  "$(app "INSERT INTO crop_channels (id,crop_id,owner_id,type,enabled,delivery) VALUES ('0000000000000000000000d1','c','o','TELEGRAM',true,'HOURLY')" 2>&1 >/dev/null | grep -qi 'check\|violates' && echo rejected || echo accepted)" "rejected"
check "unique constraint per crop and actuator type" \
  "$(app "INSERT INTO actuators (id,crop_id,type,active,created_at) VALUES ('0000000000000000000000a1','cropci','FAN',false,now()),('0000000000000000000000a2','cropci','FAN',false,now())" 2>&1 >/dev/null | grep -qi 'duplicate\|unique\|violates' && echo rejected || echo accepted)" "rejected"

migrate >/dev/null
check "continuous aggregates include non-materialized data" \
  "$(app "SELECT count(*) FROM timescaledb_information.continuous_aggregates WHERE materialized_only = false")" "3"
check "reader role sees telemetry" "$(reader "SELECT count(*) >= 0 FROM readings")" "t"
check "reader role cannot see crop owner" \
  "$(reader 'SELECT owner_id FROM crops' 2>&1 >/dev/null | grep -qi 'permi\|denied' && echo denied || echo allowed)" "denied"
check "reader role cannot write" \
  "$(reader "DELETE FROM readings" 2>&1 >/dev/null | grep -qi 'read-only\|permi\|denied' && echo denied || echo allowed)" "denied"
check "migration is idempotent (second run without error)" "$(migrate >/dev/null 2>&1 && echo ok || echo err)" "ok"

if [ "$DEMO" = "true" ]; then
  check "demo account" "$(app "SELECT count(*) FROM users WHERE email='demo@smartpot.app'")" "1"
  check "demo crops" "$(app "SELECT count(*) FROM crops")" "2"
  check "outdoor demo crops in Medellin" \
    "$(app "SELECT count(*) FROM crops WHERE placement->>'setting'='OUTDOOR' AND placement->'location'->>'name'='Medellín'")" "2"
  check "48 h of readings per crop (576)" "$(app "SELECT count(*) FROM readings")" "576"
else
  check "no crops" "$(app "SELECT count(*) FROM crops")" "0"
fi

[ "$fail" -eq 0 ] || docker logs "$NAME" | tail -30
exit "$fail"
