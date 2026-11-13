-- Esquema de SmartPot sobre PostgreSQL + TimescaleDB. Es la única definición del modelo de datos: lo usan el
-- inicio de una base nueva (init/01_init.sh) y la migración de una base existente (scripts/migrate.sh).
-- Es idempotente: se puede correr varias veces sin cambiar nada (CREATE ... IF NOT EXISTS y bloques DO que
-- comprueban el catálogo antes de alterar).
--
-- Los identificadores son ObjectId hexadecimales de 24 caracteres generados por la API (CHAR(24)), para que los
-- ids expuestos a los demás componentes (URL, usuario MQTT por cultivo, JSON) no cambien respecto a la versión
-- anterior sobre MongoDB. Los subdocumentos ricos (lugar, dispositivo, salud, manual, destinatarios, eventos) se
-- guardan como JSONB; las variables de telemetría, en columnas tipadas para aprovechar TimescaleDB.

CREATE EXTENSION IF NOT EXISTS timescaledb;

------------------------------------------------------------------------------
-- Modelo relacional
------------------------------------------------------------------------------

-- Cuentas de la plataforma.
CREATE TABLE IF NOT EXISTS users
(
    id            CHAR(24) PRIMARY KEY,
    name          TEXT        NOT NULL DEFAULT '',
    last_name     TEXT        NOT NULL DEFAULT '',
    email         TEXT        NOT NULL,
    password_hash TEXT        NOT NULL,
    role          TEXT        NOT NULL CHECK (role IN ('USER', 'ADMIN')),
    created_at    TIMESTAMPTZ NOT NULL,
    updated_at    TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS users_email_key ON users (email);

-- Cultivos reales (con dispositivo) o virtuales (simulados). kind y form son fijos/editables según la API.
CREATE TABLE IF NOT EXISTS crops
(
    id                 CHAR(24) PRIMARY KEY,
    owner_id           CHAR(24)    NOT NULL,
    name               TEXT        NOT NULL,
    type               TEXT        NOT NULL CHECK (type IN ('TOMATO', 'LETTUCE', 'STRAWBERRY', 'BASIL', 'SPINACH', 'PEPPER')),
    kind               TEXT CHECK (kind IN ('REAL', 'VIRTUAL')),
    form               TEXT CHECK (form IN ('POT', 'NFT', 'TOWER', 'RAFT')),
    placement          JSONB,
    automation_enabled BOOLEAN     NOT NULL,
    device             JSONB,
    health             JSONB,
    created_at         TIMESTAMPTZ NOT NULL,
    updated_at         TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS crops_owner_created ON crops (owner_id, created_at DESC);
-- Para sincronizar en el broker las cuentas de los cultivos con clave de dispositivo al reconectar.
CREATE INDEX IF NOT EXISTS crops_with_device_key ON crops ((device ->> 'keyCiphertext')) WHERE device ->> 'keyCiphertext' IS NOT NULL;

-- Función de contexto seguro para fijar o limpiar el tenant actual de forma parametrizada.
CREATE OR REPLACE FUNCTION set_tenant_context(tenant_id TEXT) RETURNS void AS $$
BEGIN
    IF tenant_id IS NULL OR tenant_id = '' THEN
        PERFORM set_config('app.current_tenant_id', '', false);
    ELSE
        PERFORM set_config('app.current_tenant_id', tenant_id, false);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Aislamiento multi-tenant con Row-Level Security (RLS). La API es la frontera real y verifica estrictamente el owner_id;
-- esta política refuerza el aislamiento a nivel de motor en modo fail-closed: si app.current_tenant_id no está definido
-- o está vacío, no se expone ni permite escribir ninguna fila, salvo que se establezca app.bypass_rls = 'on' o el rol
-- sea smartpot_reader (para entrenamiento del modelo sobre vistas anonimizadas).
ALTER TABLE crops ENABLE ROW LEVEL SECURITY;
DO $crops_rls$
BEGIN
    DROP POLICY IF EXISTS crops_tenant_isolation ON crops;
    CREATE POLICY crops_tenant_isolation ON crops
        FOR ALL
        USING (
            current_setting('app.bypass_rls', true) = 'on'
            OR current_user = 'smartpot_reader'
            OR (
                NULLIF(current_setting('app.current_tenant_id', true), '') IS NOT NULL
                AND owner_id = current_setting('app.current_tenant_id', true)
            )
        )
        WITH CHECK (
            current_setting('app.bypass_rls', true) = 'on'
            OR (
                NULLIF(current_setting('app.current_tenant_id', true), '') IS NOT NULL
                AND owner_id = current_setting('app.current_tenant_id', true)
            )
        );
END
$crops_rls$;

-- Telemetría de los sensores: hipertabla de TimescaleDB particionada por tiempo. Cada variable es una columna
-- opcional (°C, % HR, lux, pH, ppm, hPa y % de humedad del sustrato).
CREATE TABLE IF NOT EXISTS readings
(
    id            CHAR(24) NOT NULL,
    crop_id       CHAR(24) NOT NULL,
    measured_at   TIMESTAMPTZ NOT NULL,
    source        TEXT CHECK (source IN ('MQTT', 'HTTP')),
    temperature   DOUBLE PRECISION,
    humidity      DOUBLE PRECISION,
    brightness    DOUBLE PRECISION,
    ph            DOUBLE PRECISION,
    tds           DOUBLE PRECISION,
    atmosphere    DOUBLE PRECISION,
    soil_moisture DOUBLE PRECISION
);
-- Hipertabla con fragmentos (chunks) de 1 día; la columna de partición es measured_at.
-- Argumentos posicionales a propósito (create_default_indexes = FALSE, if_not_exists = TRUE): evitan el
-- índice B-tree por defecto (redundantemente cubierto por el índice BRIN + cubriente) y el operador `=>`.
SELECT create_hypertable('readings', by_range('measured_at', INTERVAL '1 day'), FALSE, TRUE);
SELECT set_chunk_time_interval('readings', INTERVAL '1 day');

-- Índice cubriente único para las series por cultivo. El índice antiguo (crop_id, measured_at DESC) era un prefijo
-- exacto de este y el B-tree por defecto (measured_at) duplicaba al BRIN; ambos se eliminan de forma idempotente.
CREATE INDEX IF NOT EXISTS readings_crop_measured_covering
    ON readings (crop_id, measured_at DESC)
    INCLUDE (temperature, humidity, brightness, ph, tds, atmosphere, soil_moisture);
DROP INDEX IF EXISTS readings_crop_measured;
DROP INDEX IF EXISTS readings_measured_at_idx;
CREATE INDEX IF NOT EXISTS readings_measured_at_brin ON readings USING BRIN (measured_at);

-- Salidas de cada cultivo (bomba, luz UV, ventilador, humidificador y dosificadores) y su estado confirmado.
CREATE TABLE IF NOT EXISTS actuators
(
    id              CHAR(24) PRIMARY KEY,
    crop_id         CHAR(24)    NOT NULL,
    type            TEXT        NOT NULL CHECK (type IN ('WATER_PUMP', 'UV_LIGHT', 'FAN', 'HUMIDIFIER', 'NUTRIENT_DOSER', 'PH_DOSER')),
    active          BOOLEAN     NOT NULL,
    running_until   TIMESTAMPTZ,
    last_changed_at TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS actuators_crop_type ON actuators (crop_id, type);

-- Órdenes a los actuadores con su ciclo de vida (PENDING -> SENT -> EXECUTED | FAILED | EXPIRED).
CREATE TABLE IF NOT EXISTS commands
(
    id               CHAR(24) PRIMARY KEY,
    crop_id          CHAR(24)    NOT NULL,
    actuator_id      CHAR(24)    NOT NULL,
    actuator_type    TEXT        NOT NULL CHECK (actuator_type IN ('WATER_PUMP', 'UV_LIGHT', 'FAN', 'HUMIDIFIER', 'NUTRIENT_DOSER', 'PH_DOSER')),
    action           TEXT        NOT NULL CHECK (action IN ('ACTIVATE', 'DEACTIVATE')),
    duration_seconds INTEGER,
    status           TEXT        NOT NULL CHECK (status IN ('PENDING', 'SENT', 'EXECUTED', 'FAILED', 'EXPIRED')),
    source           TEXT        NOT NULL CHECK (source IN ('USER', 'AGENT')),
    reason           TEXT        NOT NULL DEFAULT '',
    message          TEXT        NOT NULL DEFAULT '',
    created_at       TIMESTAMPTZ NOT NULL,
    sent_at          TIMESTAMPTZ,
    completed_at     TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS commands_crop_created ON commands (crop_id, created_at DESC);
CREATE INDEX IF NOT EXISTS commands_status_sent ON commands (status, sent_at);
CREATE INDEX IF NOT EXISTS commands_actuator_status ON commands (actuator_id, status);

-- Garantiza a nivel de motor que solo exista un comando activo por actuador. migrate.sh expira los duplicados
-- históricos antes de aplicar el esquema, de modo que el índice se pueda crear sobre datos existentes.
CREATE UNIQUE INDEX IF NOT EXISTS commands_one_inflight_per_actuator
    ON commands (actuator_id)
    WHERE status IN ('PENDING', 'SENT');

-- Alertas del cultivo, del dispositivo y del asistente de IA que ve la PWA. crop_id es opcional.
CREATE TABLE IF NOT EXISTS notifications
(
    id         CHAR(24) PRIMARY KEY,
    user_id    CHAR(24)    NOT NULL,
    crop_id    CHAR(24),
    type       TEXT        NOT NULL CHECK (type IN ('INFO', 'ALERT', 'COMMAND', 'DEVICE', 'AI')),
    title      TEXT        NOT NULL,
    message    TEXT        NOT NULL,
    read       BOOLEAN     NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS notifications_user_created ON notifications (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS notifications_user_unread ON notifications (user_id, created_at DESC) WHERE read = false;
CREATE INDEX IF NOT EXISTS notifications_crop_created ON notifications (crop_id, created_at) WHERE crop_id IS NOT NULL;

-- Tokens de recuperación de contraseña: solo el SHA-256 del token. La API los purga al vencer.
CREATE TABLE IF NOT EXISTS password_reset_tokens
(
    id         CHAR(24) PRIMARY KEY,
    token_hash TEXT        NOT NULL,
    user_id    CHAR(24)    NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS password_reset_tokens_hash_key ON password_reset_tokens (token_hash);
CREATE INDEX IF NOT EXISTS password_reset_tokens_user ON password_reset_tokens (user_id);
CREATE INDEX IF NOT EXISTS password_reset_tokens_expires ON password_reset_tokens (expires_at);

-- Vínculo de una cuenta con un canal externo (hoy Telegram); address es el id del chat.
CREATE TABLE IF NOT EXISTS channel_links
(
    id                CHAR(24) PRIMARY KEY,
    user_id           CHAR(24)    NOT NULL,
    type              TEXT        NOT NULL CHECK (type IN ('TELEGRAM')),
    address           TEXT        NOT NULL,
    display_name      TEXT        NOT NULL DEFAULT '',
    enabled           BOOLEAN     NOT NULL,
    events            JSONB       NOT NULL DEFAULT '[]'::jsonb,
    linked_at         TIMESTAMPTZ,
    last_delivered_at TIMESTAMPTZ,
    failures          INTEGER     NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS channel_links_user_type ON channel_links (user_id, type);
CREATE UNIQUE INDEX IF NOT EXISTS channel_links_type_address ON channel_links (type, address);

-- Avisos de un cultivo por un canal: qué avisa, al instante o en resumen, el resumen diario (HH:mm) y los chats
-- con los que se comparte (hasta 10, en recipients).
CREATE TABLE IF NOT EXISTS crop_channels
(
    id              CHAR(24) PRIMARY KEY,
    crop_id         CHAR(24)    NOT NULL,
    owner_id        CHAR(24)    NOT NULL,
    type            TEXT        NOT NULL CHECK (type IN ('TELEGRAM')),
    enabled         BOOLEAN     NOT NULL,
    events          JSONB       NOT NULL DEFAULT '[]'::jsonb,
    delivery        TEXT CHECK (delivery IN ('INSTANT', 'DIGEST')),
    digest_hours    INTEGER,
    daily_summary_at TEXT,
    recipients      JSONB       NOT NULL DEFAULT '[]'::jsonb,
    last_digest_at  TIMESTAMPTZ,
    last_summary_at TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS crop_channels_crop_type ON crop_channels (crop_id, type);
CREATE INDEX IF NOT EXISTS crop_channels_enabled ON crop_channels (enabled) WHERE enabled;

-- Simulación de un cultivo virtual: el simulador la recrea a partir de esta fila; active es false en pausa.
CREATE TABLE IF NOT EXISTS virtual_devices
(
    id               CHAR(24) PRIMARY KEY,
    crop_id          CHAR(24)    NOT NULL,
    owner_id         CHAR(24)    NOT NULL,
    mode             TEXT        NOT NULL CHECK (mode IN ('AUTO', 'MANUAL', 'WEATHER')),
    manual           JSONB,
    location         JSONB,
    interval_seconds INTEGER     NOT NULL,
    active           BOOLEAN,
    created_at       TIMESTAMPTZ NOT NULL,
    updated_at       TIMESTAMPTZ NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS virtual_devices_crop ON virtual_devices (crop_id);
CREATE INDEX IF NOT EXISTS virtual_devices_owner ON virtual_devices (owner_id);

-- Conexiones personales (clientes MCP y similares). Solo se guarda el SHA-256 del token; el prefijo visible permite
-- reconocerlo en la PWA. READ solo consulta; CONTROL además crea, edita y acciona. Revocar es borrar la fila.
CREATE TABLE IF NOT EXISTS access_tokens
(
    id           CHAR(24) PRIMARY KEY,
    user_id      CHAR(24)    NOT NULL,
    name         TEXT        NOT NULL,
    token_hash   TEXT        NOT NULL,
    prefix       TEXT        NOT NULL,
    scope        TEXT        NOT NULL CHECK (scope IN ('READ', 'CONTROL')),
    created_at   TIMESTAMPTZ NOT NULL,
    last_used_at TIMESTAMPTZ,
    expires_at   TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS access_tokens_hash_key ON access_tokens (token_hash);
CREATE INDEX IF NOT EXISTS access_tokens_user ON access_tokens (user_id);

------------------------------------------------------------------------------
-- Integridad referencial
------------------------------------------------------------------------------

-- Las llaves foráneas se agregan con un bloque idempotente porque CREATE TABLE IF NOT EXISTS no altera tablas que
-- ya existen. ON DELETE CASCADE elimina el dato dependiente con su dueño; notifications.crop_id usa SET NULL para
-- conservar el aviso de cuenta cuando se borra el cultivo.
DO $foreign_keys$
DECLARE
    item RECORD;
BEGIN
    FOR item IN
        SELECT * FROM (VALUES
            ('crops', 'crops_owner_id_fkey', $c$FOREIGN KEY (owner_id) REFERENCES users (id) ON DELETE CASCADE$c$),
            ('readings', 'readings_crop_id_fkey', $c$FOREIGN KEY (crop_id) REFERENCES crops (id) ON DELETE CASCADE$c$),
            ('actuators', 'actuators_crop_id_fkey', $c$FOREIGN KEY (crop_id) REFERENCES crops (id) ON DELETE CASCADE$c$),
            ('commands', 'commands_crop_id_fkey', $c$FOREIGN KEY (crop_id) REFERENCES crops (id) ON DELETE CASCADE$c$),
            ('commands', 'commands_actuator_id_fkey', $c$FOREIGN KEY (actuator_id) REFERENCES actuators (id) ON DELETE CASCADE$c$),
            ('notifications', 'notifications_user_id_fkey', $c$FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE$c$),
            ('notifications', 'notifications_crop_id_fkey', $c$FOREIGN KEY (crop_id) REFERENCES crops (id) ON DELETE SET NULL$c$),
            ('password_reset_tokens', 'password_reset_tokens_user_id_fkey', $c$FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE$c$),
            ('channel_links', 'channel_links_user_id_fkey', $c$FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE$c$),
            ('crop_channels', 'crop_channels_crop_id_fkey', $c$FOREIGN KEY (crop_id) REFERENCES crops (id) ON DELETE CASCADE$c$),
            ('virtual_devices', 'virtual_devices_crop_id_fkey', $c$FOREIGN KEY (crop_id) REFERENCES crops (id) ON DELETE CASCADE$c$),
            ('access_tokens', 'access_tokens_user_id_fkey', $c$FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE$c$)
        ) AS definitions(table_name, constraint_name, definition)
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = item.table_name::regclass AND conname = item.constraint_name
        ) THEN
            EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I %s', item.table_name, item.constraint_name, item.definition);
        END IF;
    END LOOP;
END
$foreign_keys$;

------------------------------------------------------------------------------
-- Restricciones de dominio y rangos físicos
------------------------------------------------------------------------------

-- Los ids son ObjectId de 24 caracteres hexadecimales. Las columnas anulables aceptan NULL, pero cualquier valor
-- presente debe cumplir el formato; así un cliente no puede crear filas con ids arbitrarios.
DO $format_checks$
DECLARE
    item RECORD;
BEGIN
    FOR item IN
        SELECT * FROM (VALUES
            ('users', 'users_id_format_check', $c$CHECK (id ~ '^[0-9a-f]{24}$')$c$),
            ('crops', 'crops_id_format_check', $c$CHECK (id ~ '^[0-9a-f]{24}$')$c$),
            ('crops', 'crops_owner_id_format_check', $c$CHECK (owner_id ~ '^[0-9a-f]{24}$')$c$),
            ('readings', 'readings_id_format_check', $c$CHECK (id ~ '^[0-9a-f]{24}$')$c$),
            ('readings', 'readings_crop_id_format_check', $c$CHECK (crop_id ~ '^[0-9a-f]{24}$')$c$),
            ('actuators', 'actuators_id_format_check', $c$CHECK (id ~ '^[0-9a-f]{24}$')$c$),
            ('actuators', 'actuators_crop_id_format_check', $c$CHECK (crop_id ~ '^[0-9a-f]{24}$')$c$),
            ('commands', 'commands_id_format_check', $c$CHECK (id ~ '^[0-9a-f]{24}$')$c$),
            ('commands', 'commands_crop_id_format_check', $c$CHECK (crop_id ~ '^[0-9a-f]{24}$')$c$),
            ('commands', 'commands_actuator_id_format_check', $c$CHECK (actuator_id ~ '^[0-9a-f]{24}$')$c$),
            ('notifications', 'notifications_id_format_check', $c$CHECK (id ~ '^[0-9a-f]{24}$')$c$),
            ('notifications', 'notifications_user_id_format_check', $c$CHECK (user_id ~ '^[0-9a-f]{24}$')$c$),
            ('notifications', 'notifications_crop_id_format_check', $c$CHECK (crop_id IS NULL OR crop_id ~ '^[0-9a-f]{24}$')$c$),
            ('password_reset_tokens', 'password_reset_tokens_id_format_check', $c$CHECK (id ~ '^[0-9a-f]{24}$')$c$),
            ('password_reset_tokens', 'password_reset_tokens_user_id_format_check', $c$CHECK (user_id ~ '^[0-9a-f]{24}$')$c$),
            ('channel_links', 'channel_links_id_format_check', $c$CHECK (id ~ '^[0-9a-f]{24}$')$c$),
            ('channel_links', 'channel_links_user_id_format_check', $c$CHECK (user_id ~ '^[0-9a-f]{24}$')$c$),
            ('crop_channels', 'crop_channels_id_format_check', $c$CHECK (id ~ '^[0-9a-f]{24}$')$c$),
            ('crop_channels', 'crop_channels_crop_id_format_check', $c$CHECK (crop_id ~ '^[0-9a-f]{24}$')$c$),
            ('crop_channels', 'crop_channels_owner_id_format_check', $c$CHECK (owner_id ~ '^[0-9a-f]{24}$')$c$),
            ('virtual_devices', 'virtual_devices_id_format_check', $c$CHECK (id ~ '^[0-9a-f]{24}$')$c$),
            ('virtual_devices', 'virtual_devices_crop_id_format_check', $c$CHECK (crop_id ~ '^[0-9a-f]{24}$')$c$),
            ('virtual_devices', 'virtual_devices_owner_id_format_check', $c$CHECK (owner_id ~ '^[0-9a-f]{24}$')$c$),
            ('access_tokens', 'access_tokens_id_format_check', $c$CHECK (id ~ '^[0-9a-f]{24}$')$c$),
            ('access_tokens', 'access_tokens_user_id_format_check', $c$CHECK (user_id ~ '^[0-9a-f]{24}$')$c$)
        ) AS definitions(table_name, constraint_name, definition)
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = item.table_name::regclass AND conname = item.constraint_name
        ) THEN
            EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I %s', item.table_name, item.constraint_name, item.definition);
        END IF;
    END LOOP;
END
$format_checks$;

-- Rangos físicos: la API ya los valida (readings.ValidateRanges), aquí se cierran también en el motor para que
-- ninguna ruta de escritura (ingesta, SQL manual, restauración) pueda almacenar una lectura imposible.
DO $range_checks$
DECLARE
    item RECORD;
BEGIN
    FOR item IN
        SELECT * FROM (VALUES
            ('readings', 'readings_ph_range_check', $c$CHECK (ph BETWEEN 0 AND 14)$c$),
            ('readings', 'readings_humidity_range_check', $c$CHECK (humidity BETWEEN 0 AND 100)$c$),
            ('readings', 'readings_soil_moisture_range_check', $c$CHECK (soil_moisture BETWEEN 0 AND 100)$c$),
            ('readings', 'readings_brightness_range_check', $c$CHECK (brightness >= 0)$c$),
            ('readings', 'readings_tds_range_check', $c$CHECK (tds >= 0)$c$),
            ('readings', 'readings_atmosphere_range_check', $c$CHECK (atmosphere BETWEEN 300 AND 1100)$c$),
            ('readings', 'readings_temperature_range_check', $c$CHECK (temperature BETWEEN -20 AND 60)$c$),
            ('readings', 'readings_metric_present_check', $c$CHECK (num_nonnulls(temperature, humidity, brightness, ph, tds, atmosphere, soil_moisture) > 0)$c$),
            ('commands', 'commands_duration_seconds_check', $c$CHECK (duration_seconds IS NULL OR duration_seconds > 0)$c$),
            ('channel_links', 'channel_links_failures_check', $c$CHECK (failures >= 0)$c$),
            ('virtual_devices', 'virtual_devices_interval_seconds_check', $c$CHECK (interval_seconds > 0)$c$),
            ('crop_channels', 'crop_channels_digest_hours_check', $c$CHECK (digest_hours IS NULL OR digest_hours BETWEEN 1 AND 24)$c$)
        ) AS definitions(table_name, constraint_name, definition)
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = item.table_name::regclass AND conname = item.constraint_name
        ) THEN
            EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I %s', item.table_name, item.constraint_name, item.definition);
        END IF;
    END LOOP;
END
$range_checks$;

------------------------------------------------------------------------------
-- Compresión y retención de la hipertabla
------------------------------------------------------------------------------

-- La compresión se activa DESPUÉS de las restricciones: TimescaleDB no permite ALTER TABLE ... ADD CONSTRAINT
-- mientras la compresión está habilitada. migrate.sh descomprime y desactiva la compresión antes de aplicar este
-- archivo cuando detecta que faltan restricciones, y el bloque de abajo la vuelve a habilitar.
-- Agrupa por cultivo y ordena por tiempo descendente para maximizar el ratio de compresión.
ALTER TABLE readings SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'crop_id',
    timescaledb.compress_orderby = 'measured_at DESC'
);
SELECT add_compression_policy('readings', INTERVAL '12 hours', TRUE);

-- Retención de 1 año: TimescaleDB descarta los fragmentos antiguos (equivale al índice TTL anterior).
-- Tercer argumento posicional = if_not_exists (ver nota de arriba sobre `=>`).
SELECT add_retention_policy('readings', INTERVAL '365 days', TRUE);

------------------------------------------------------------------------------
-- Agregados continuos
------------------------------------------------------------------------------

-- Si una base existente tiene los agregados antiguos (sin los contadores por métrica), se eliminan aquí para que
-- las definiciones de abajo los vuelvan a crear. Sin esto, CREATE MATERIALIZED VIEW IF NOT EXISTS no actualiza la
-- lista de columnas y el promedio ponderado seguiría sesgado por los NULL.
DO $cagg_upgrade$
DECLARE
    view_name TEXT;
BEGIN
    FOREACH view_name IN ARRAY ARRAY['readings_1m', 'readings_15m', 'readings_hourly']
        LOOP
            IF to_regclass('public.' || view_name) IS NOT NULL
                AND NOT EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'public' AND table_name = view_name AND column_name = 'count_temperature'
                ) THEN
                PERFORM remove_continuous_aggregate_policy(view_name::regclass, TRUE);
                PERFORM remove_retention_policy(view_name::regclass, TRUE);
                EXECUTE format('DROP MATERIALIZED VIEW %I', view_name);
            END IF;
        END LOOP;
END
$cagg_upgrade$;

-- Vista continua de 1 minuto para streaming y resolución en tiempo real.
CREATE MATERIALIZED VIEW IF NOT EXISTS readings_1m
            WITH (timescaledb.continuous) AS
SELECT crop_id,
       time_bucket('1 minute', measured_at) AS bucket,
       min(temperature)                     AS min_temperature,
       avg(temperature)                     AS avg_temperature,
       max(temperature)                     AS max_temperature,
       count(temperature)                   AS count_temperature,
       min(humidity)                        AS min_humidity,
       avg(humidity)                        AS avg_humidity,
       max(humidity)                        AS max_humidity,
       count(humidity)                      AS count_humidity,
       min(brightness)                      AS min_brightness,
       avg(brightness)                      AS avg_brightness,
       max(brightness)                      AS max_brightness,
       count(brightness)                    AS count_brightness,
       min(ph)                              AS min_ph,
       avg(ph)                              AS avg_ph,
       max(ph)                              AS max_ph,
       count(ph)                            AS count_ph,
       min(tds)                             AS min_tds,
       avg(tds)                             AS avg_tds,
       max(tds)                             AS max_tds,
       count(tds)                           AS count_tds,
       min(atmosphere)                      AS min_atmosphere,
       avg(atmosphere)                      AS avg_atmosphere,
       max(atmosphere)                      AS max_atmosphere,
       count(atmosphere)                    AS count_atmosphere,
       min(soil_moisture)                   AS min_soil_moisture,
       avg(soil_moisture)                   AS avg_soil_moisture,
       max(soil_moisture)                   AS max_soil_moisture,
       count(soil_moisture)                 AS count_soil_moisture,
       count(*)                             AS reading_count
FROM readings
GROUP BY crop_id, bucket
WITH NO DATA;

-- Agregación en tiempo real: suma lo aún no materializado, así las series incluyen las últimas lecturas.
ALTER MATERIALIZED VIEW readings_1m SET (timescaledb.materialized_only = false);
-- Argumentos posicionales (start_offset, end_offset, schedule_interval, if_not_exists): sin `=>`.
SELECT add_continuous_aggregate_policy('readings_1m', INTERVAL '2 hours', INTERVAL '1 minute', INTERVAL '1 minute', TRUE);
-- Retención alineada con la hipertabla base: los agregados no sobreviven más de un año.
SELECT add_retention_policy('readings_1m', INTERVAL '365 days', TRUE);

-- Vista continua de 15 minutos para series intermedias y agregación analítica.
CREATE MATERIALIZED VIEW IF NOT EXISTS readings_15m
            WITH (timescaledb.continuous) AS
SELECT crop_id,
       time_bucket('15 minutes', measured_at) AS bucket,
       min(temperature)                       AS min_temperature,
       avg(temperature)                       AS avg_temperature,
       max(temperature)                       AS max_temperature,
       count(temperature)                     AS count_temperature,
       min(humidity)                          AS min_humidity,
       avg(humidity)                          AS avg_humidity,
       max(humidity)                          AS max_humidity,
       count(humidity)                        AS count_humidity,
       min(brightness)                        AS min_brightness,
       avg(brightness)                        AS avg_brightness,
       max(brightness)                        AS max_brightness,
       count(brightness)                      AS count_brightness,
       min(ph)                                AS min_ph,
       avg(ph)                                AS avg_ph,
       max(ph)                                AS max_ph,
       count(ph)                              AS count_ph,
       min(tds)                               AS min_tds,
       avg(tds)                               AS avg_tds,
       max(tds)                               AS max_tds,
       count(tds)                             AS count_tds,
       min(atmosphere)                        AS min_atmosphere,
       avg(atmosphere)                        AS avg_atmosphere,
       max(atmosphere)                        AS max_atmosphere,
       count(atmosphere)                      AS count_atmosphere,
       min(soil_moisture)                     AS min_soil_moisture,
       avg(soil_moisture)                     AS avg_soil_moisture,
       max(soil_moisture)                     AS max_soil_moisture,
       count(soil_moisture)                   AS count_soil_moisture,
       count(*)                               AS reading_count
FROM readings
GROUP BY crop_id, bucket
WITH NO DATA;

-- Agregación en tiempo real: suma lo aún no materializado, así las series incluyen las últimas lecturas.
ALTER MATERIALIZED VIEW readings_15m SET (timescaledb.materialized_only = false);
-- Argumentos posicionales (start_offset, end_offset, schedule_interval, if_not_exists): sin `=>`.
SELECT add_continuous_aggregate_policy('readings_15m', INTERVAL '24 hours', INTERVAL '15 minutes', INTERVAL '15 minutes', TRUE);
SELECT add_retention_policy('readings_15m', INTERVAL '365 days', TRUE);

-- Vista continua horaria para consultas analíticas y series temporales sin escanear datos crudos.
CREATE MATERIALIZED VIEW IF NOT EXISTS readings_hourly
            WITH (timescaledb.continuous) AS
SELECT crop_id,
       time_bucket('1 hour', measured_at) AS bucket,
       min(temperature)                   AS min_temperature,
       avg(temperature)                   AS avg_temperature,
       max(temperature)                   AS max_temperature,
       count(temperature)                 AS count_temperature,
       min(humidity)                      AS min_humidity,
       avg(humidity)                      AS avg_humidity,
       max(humidity)                      AS max_humidity,
       count(humidity)                    AS count_humidity,
       min(brightness)                    AS min_brightness,
       avg(brightness)                    AS avg_brightness,
       max(brightness)                    AS max_brightness,
       count(brightness)                  AS count_brightness,
       min(ph)                            AS min_ph,
       avg(ph)                            AS avg_ph,
       max(ph)                            AS max_ph,
       count(ph)                          AS count_ph,
       min(tds)                           AS min_tds,
       avg(tds)                           AS avg_tds,
       max(tds)                           AS max_tds,
       count(tds)                         AS count_tds,
       min(atmosphere)                    AS min_atmosphere,
       avg(atmosphere)                    AS avg_atmosphere,
       max(atmosphere)                    AS max_atmosphere,
       count(atmosphere)                  AS count_atmosphere,
       min(soil_moisture)                 AS min_soil_moisture,
       avg(soil_moisture)                 AS avg_soil_moisture,
       max(soil_moisture)                 AS max_soil_moisture,
       count(soil_moisture)               AS count_soil_moisture,
       count(*)                           AS reading_count
FROM readings
GROUP BY crop_id, bucket
WITH NO DATA;

-- Agregación en tiempo real: suma lo aún no materializado, así las series incluyen las últimas lecturas.
ALTER MATERIALIZED VIEW readings_hourly SET (timescaledb.materialized_only = false);
-- Argumentos posicionales (start_offset, end_offset, schedule_interval, if_not_exists): sin `=>`.
SELECT add_continuous_aggregate_policy('readings_hourly', INTERVAL '30 days', INTERVAL '1 hour', INTERVAL '1 hour', TRUE);
SELECT add_retention_policy('readings_hourly', INTERVAL '365 days', TRUE);

------------------------------------------------------------------------------
-- Superficie de lectura para el entrenador
------------------------------------------------------------------------------

-- Vista con security_barrier: expone la telemetría junto con la especie y el tipo de cultivo, y nada más. El
-- entrenador nunca ve owner_id, device, users, access_tokens ni password_reset_tokens. El owner de la vista es la
-- cuenta administradora, así que la vista resuelve las columnas base sin conceder SELECT directo sobre crops.
CREATE OR REPLACE VIEW trainer_readings
            WITH (security_barrier) AS
SELECT r.id,
       r.crop_id,
       c.type   AS crop_type,
       c.kind   AS crop_kind,
       r.measured_at,
       r.source,
       r.temperature,
       r.humidity,
       r.brightness,
       r.ph,
       r.tds,
       r.atmosphere,
       r.soil_moisture
FROM readings r
         JOIN crops c ON c.id = r.crop_id;

------------------------------------------------------------------------------
-- Privilegios
------------------------------------------------------------------------------

-- PUBLIC no debe heredar CONNECT ni TEMP sobre la base: solo los tres roles de la plataforma entran. La
-- revocación es dinámica porque el nombre de la base lo decide el contenedor (POSTGRES_DB).
DO $database_privileges$
BEGIN
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
END
$database_privileges$;

-- PUBLIC tampoco conserva USAGE sobre el esquema: sin esto, cualquier rol con LOGIN podría resolver los objetos.
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- Los privilegios por rol solo se aplican si el rol ya existe. En una base nueva 01_init.sh crea los roles justo
-- después de este archivo y concede con los nombres parameterizados; en una base existente migrate.sh repara aquí
-- los permisos que hayan quedado de versiones anteriores.
DO $role_privileges$
DECLARE
    role_name TEXT;
BEGIN
    FOREACH role_name IN ARRAY ARRAY ['smartpot', 'smartpot_ingest', 'smartpot_reader']
        LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
                EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), role_name);
                EXECUTE format('GRANT USAGE ON SCHEMA public TO %I', role_name);
            END IF;
        END LOOP;
END
$role_privileges$;

-- Rol transaccional de la API: DML sobre todo el esquema, sin DDL ni gestión de roles.
DO $application_privileges$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'smartpot') THEN
        EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO smartpot';
        EXECUTE 'GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO smartpot';
        EXECUTE 'GRANT EXECUTE ON FUNCTION set_tenant_context(TEXT) TO smartpot';
        EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO smartpot';
        EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO smartpot';
    END IF;
END
$application_privileges$;

-- Rol de ingesta: mínimo privilegio, solo lectura y escritura de readings. Se revoca cualquier permiso anterior
-- porque versiones previas le concedían secuencias y acceso a más tablas.
DO $ingest_privileges$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'smartpot_ingest') THEN
        EXECUTE 'REVOKE ALL ON ALL TABLES IN SCHEMA public FROM smartpot_ingest';
        EXECUTE 'REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM smartpot_ingest';
        EXECUTE 'GRANT SELECT, INSERT ON TABLE readings TO smartpot_ingest';
    END IF;
END
$ingest_privileges$;

-- Rol de solo lectura del entrenador: telemetría, la vista segura y las tres columnas anonimizadas de crops.
-- Nunca recibe SELECT de tabla completa sobre crops ni acceso a las tablas de credenciales.
DO $reader_privileges$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'smartpot_reader') THEN
        EXECUTE 'REVOKE ALL ON ALL TABLES IN SCHEMA public FROM smartpot_reader';
        EXECUTE 'REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM smartpot_reader';
        EXECUTE 'GRANT SELECT ON TABLE readings TO smartpot_reader';
        EXECUTE 'GRANT SELECT (id, type, kind) ON TABLE crops TO smartpot_reader';
        EXECUTE 'GRANT SELECT ON TABLE trainer_readings TO smartpot_reader';
    END IF;
END
$reader_privileges$;
