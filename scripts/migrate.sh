#!/bin/sh
# Aplica el esquema (schema/schema.sql) a una base existente, que ya no ejecuta los scripts de inicio. Es
# idempotente: se puede correr después de cada actualización de la imagen para sumar tablas, índices, restricciones
# o políticas nuevas sin tocar los datos.
#   docker exec smartpot-db-postgre /opt/smartpot/migrate.sh
# Se conecta por el socket local con la cuenta administradora del contenedor (POSTGRES_USER), que es la dueña del
# esquema; la clave no aparece en la línea de comandos.
set -eu

DATABASE="${POSTGRES_DB:-smartpot}"
ADMIN_USER="${POSTGRES_USER:-postgres}"

log() {
    echo "SmartPot: $*"
}

# Todas las consultas de administración usan la cuenta dueña del esquema. -v ON_ERROR_STOP=1 evita que un error
# intermedio deje la migración a medias con un código de salida 0.
psql_admin() {
    psql -v ON_ERROR_STOP=1 --no-psqlrc --username "$ADMIN_USER" --dbname "$DATABASE" "$@"
}

log "preflight: expiring duplicate in-flight commands and removing orphan rows"

# La limpieza corre ANTES de schema.sql porque el índice único parcial y las llaves foráneas no pueden crearse
# mientras existan duplicados u huérfanos. El orden va de hijos a padres para no dejar referencias colgando.
psql_admin <<'SQL'
-- Un actuador solo puede tener un comando en vuelo. Se conserva el más reciente y se expira el resto, igual que
-- hace la API cuando detecta un comando viejo, pero aquí en bloque para que el índice único pueda crearse.
UPDATE commands
SET status       = 'EXPIRED',
    completed_at = COALESCE(completed_at, now())
WHERE id IN (SELECT id
             FROM (SELECT id,
                          row_number() OVER (PARTITION BY actuator_id ORDER BY created_at DESC, id DESC) AS position
                   FROM commands
                   WHERE status IN ('PENDING', 'SENT')) AS ranked
             WHERE position > 1);

-- Comandos cuyo cultivo o actuador ya no existe.
DELETE
FROM commands c
WHERE NOT EXISTS (SELECT 1 FROM crops p WHERE p.id = c.crop_id)
   OR NOT EXISTS (SELECT 1 FROM actuators a WHERE a.id = c.actuator_id);

-- Notificaciones de cuentas eliminadas; las de un cultivo eliminado conservan el aviso y pierden solo el cultivo.
DELETE
FROM notifications n
WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.id = n.user_id);
UPDATE notifications n
SET crop_id = NULL
WHERE n.crop_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM crops c WHERE c.id = n.crop_id);

-- Tokens y vínculos de cuentas eliminadas.
DELETE
FROM password_reset_tokens t
WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.id = t.user_id);
DELETE
FROM channel_links l
WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.id = l.user_id);
DELETE
FROM access_tokens t
WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.id = t.user_id);

-- Configuración de canales y simulación de cultivos eliminados. owner_id no lleva llave foránea propia: se deduce
-- del cultivo, por eso solo se limpia por crop_id.
DELETE
FROM crop_channels cc
WHERE NOT EXISTS (SELECT 1 FROM crops c WHERE c.id = cc.crop_id);
DELETE
FROM virtual_devices vd
WHERE NOT EXISTS (SELECT 1 FROM crops c WHERE c.id = vd.crop_id);

-- Hijos del cultivo antes de borrar el cultivo: sin llaves foráneas todavía, el borrado en cascada no existe.
DELETE
FROM actuators a
WHERE NOT EXISTS (SELECT 1 FROM crops c WHERE c.id = a.crop_id);
DELETE
FROM readings r
WHERE NOT EXISTS (SELECT 1 FROM crops c WHERE c.id = r.crop_id);

-- Cultivos cuyo dueño ya no existe. Al llegar aquí sus hijos ya fueron limpiados.
DELETE
FROM crops c
WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.id = c.owner_id);
SQL

# TimescaleDB rechaza ALTER TABLE ... ADD CONSTRAINT mientras la compresión está habilitada, incluso si no hay
# fragmentos comprimidos. Solo se descomprime y se desactiva cuando faltan las restricciones nuevas de readings;
# en ejecuciones posteriores el coste es cero. schema.sql vuelve a habilitar la compresión al final.
needs_constraints=$(psql_admin -tAc "
SELECT CASE
           WHEN to_regclass('public.readings') IS NULL THEN 0
           WHEN NOT EXISTS (SELECT 1
                            FROM pg_constraint
                            WHERE conrelid = 'public.readings'::regclass
                              AND conname = 'readings_crop_id_fkey')
               AND EXISTS (SELECT 1
                           FROM timescaledb_information.hypertables
                           WHERE hypertable_name = 'readings'
                             AND compression_enabled)
               THEN 1
           ELSE 0
       END")

if [ "$needs_constraints" = "1" ]; then
    log "temporarily disabling compression to add integrity constraints to readings"
    psql_admin <<'SQL'
SELECT decompress_chunk(chunk, TRUE)
FROM show_chunks('readings') AS chunk;
ALTER TABLE readings SET (timescaledb.compress = FALSE);
SQL
fi

log "applying schema to database '$DATABASE'"
psql_admin -f /opt/smartpot/schema.sql

# Se recompresión solo lo que ya estaba fuera de la ventana de 12 horas antes de la migración; los fragmentos
# recientes los tomará la política de compresión en su siguiente ejecución.
if [ "$needs_constraints" = "1" ]; then
    log "recompressing chunks older than 12 hours"
    psql_admin <<'SQL'
SELECT compress_chunk(chunk, TRUE)
FROM show_chunks('readings', now() - INTERVAL '12 hours') AS chunk;
SQL
fi

log "schema is up to date"
