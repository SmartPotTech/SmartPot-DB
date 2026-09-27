#!/bin/sh
# Arranca la imagen endurecida y valida colecciones, validadores, permisos, la migración y los datos demo.
#   sh tests/validate.sh <imagen> <true|false>
set -eu

IMAGE="${1:-smartpot-db:ci}"
DEMO="${2:-false}"
NAME="smartpot-db-validate"
APP_PASS="app-password-ci-1234"
ROOT_PASS="root-password-ci-123"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker run -d --name "$NAME" \
  --read-only --tmpfs /tmp --tmpfs /data/db:uid=999,gid=999 \
  --cap-drop ALL --security-opt no-new-privileges \
  -e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD="$ROOT_PASS" \
  -e SMARTPOT_DB_PASSWORD="$APP_PASS" -e SMARTPOT_SEED_DEMO="$DEMO" \
  "$IMAGE" >/dev/null

app() { docker exec "$NAME" mongosh --quiet -u smartpot -p "$APP_PASS" --authenticationDatabase smartpot smartpot --eval "$1"; }
root() { docker exec "$NAME" mongosh --quiet -u root -p "$ROOT_PASS" --authenticationDatabase admin smartpot --eval "$1"; }
migrate() { docker exec "$NAME" mongosh --quiet /opt/smartpot/migrate.js; }

# Los scripts de init corren en un mongod temporal que después se reinicia: se espera a que termine.
for _ in $(seq 1 90); do
  docker logs "$NAME" 2>&1 | grep -q "MongoDB init process complete" && break
  sleep 2
done
for _ in $(seq 1 60); do
  app 'db.runCommand({ping: 1}).ok' >/dev/null 2>&1 && break
  sleep 2
done

fail=0
check() { if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (esperado $3, obtenido $2)"; fail=1; fi; }

check "nueve colecciones" "$(app 'db.getCollectionNames().length')" "9"
check "el validador rechaza un cultivo incompleto" \
  "$(app 'try { db.crops.insertOne({name: "x"}); "aceptado" } catch (e) { "rechazado" }')" "rechazado"
check "el usuario de la app no administra usuarios" \
  "$(app 'try { db.getSiblingDB("admin").createUser({user: "x", pwd: "y", roles: []}); "admin" } catch (e) { "denegado" }')" "denegado"
check "el usuario de la app escribe en su base" \
  "$(app 'db.users.insertOne({email: "ci@example.com", passwordHash: "x".repeat(60), role: "USER", createdAt: new Date()}).acknowledged')" "true"

check "el validador rechaza un vínculo de canal incompleto" \
  "$(app 'try { db.channel_links.insertOne({type: "TELEGRAM"}); "aceptado" } catch (e) { "rechazado" }')" "rechazado"
check "el validador acepta un vínculo de Telegram completo" \
  "$(app 'db.channel_links.insertOne({userId: new ObjectId(), type: "TELEGRAM", address: "123456789", enabled: true, events: ["ALERT", "DEVICE"], linkedAt: new Date(), failures: NumberInt(0)}).acknowledged')" "true"
check "el validador rechaza una simulación con un modo desconocido" \
  "$(app 'try { db.virtual_devices.insertOne({cropId: new ObjectId(), ownerId: new ObjectId(), mode: "RANDOM", intervalSeconds: NumberInt(30), createdAt: new Date(), updatedAt: new Date()}); "aceptado" } catch (e) { "rechazado" }')" "rechazado"
check "el validador acepta una simulación con clima" \
  "$(app 'db.virtual_devices.insertOne({cropId: new ObjectId(), ownerId: new ObjectId(), mode: "WEATHER", location: {name: "Bogota", latitude: 4.711, longitude: -74.0721}, intervalSeconds: NumberInt(30), createdAt: new Date(), updatedAt: new Date()}).acknowledged')" "true"

# Una base creada antes de los validadores nuevos: una colección sin validador y otra con un documento antiguo.
root 'db.runCommand({collMod: "channel_links", validator: {}, validationLevel: "off"}).ok' >/dev/null
root 'db.virtual_devices.insertOne({cropId: "antiguo"}, {bypassDocumentValidation: true}).acknowledged' >/dev/null
migrate >/dev/null
check "la migración devuelve el validador a una colección que no lo tenía" \
  "$(root 'db.getCollectionInfos({name: "channel_links"})[0].options.validationLevel')" "strict"
check "la migración deja en moderate una colección con documentos antiguos" \
  "$(root 'db.getCollectionInfos({name: "virtual_devices"})[0].options.validationLevel')" "moderate"
check "la migración es idempotente" "$(migrate | grep -c ': actualizada')" "9"

if [ "$DEMO" = "true" ]; then
  check "cuenta demo" "$(app 'db.users.countDocuments({email: "demo@smartpot.app"})')" "1"
  check "cultivos demo" "$(app 'db.crops.countDocuments()')" "2"
  check "48 h de lecturas por cultivo" "$(app 'db.readings.countDocuments()')" "576"
else
  check "sin cultivos" "$(app 'db.crops.countDocuments()')" "0"
fi

[ "$fail" -eq 0 ] || docker logs "$NAME" | tail -30
exit "$fail"
