FROM timescale/timescaledb:2.17.2-pg17

LABEL org.opencontainers.image.title="SmartPot DB (PostgreSQL + TimescaleDB)" \
      org.opencontainers.image.description="PostgreSQL with TimescaleDB for SmartPot: relational schema, telemetry hypertable, and optional demo seed data" \
      org.opencontainers.image.source="https://github.com/SmartPotTech/SmartPot-DB" \
      org.opencontainers.image.licenses="MIT"

ENV POSTGRES_DB=smartpot \
    SMARTPOT_DB_USERNAME=smartpot \
    SMARTPOT_SEED_DEMO=false

# El esquema y el seed los comparten el inicio de una base nueva y la migración de una existente.
# La imagen de TimescaleDB 2.17.2 es de enero de 2025: se actualizan los paquetes de Alpine. Sus binarios en Go
# arrastran una librería estándar vieja: timescaledb-tune y timescaledb-parallel-copy no se usan (01_init.sh fija la
# configuración con ALTER SYSTEM) y gosu se reemplaza por su-exec (C, misma sintaxis) para que el entrypoint siga
# preparando el directorio de datos como root y luego baje a postgres.
RUN apk upgrade --no-cache     && apk add --no-cache su-exec     && rm -f /usr/local/bin/timescaledb-tune /usr/local/bin/timescaledb-parallel-copy              /docker-entrypoint-initdb.d/001_timescaledb_tune.sh     && ln -sf /sbin/su-exec /usr/local/bin/gosu

COPY schema/schema.sql schema/demo.sql /opt/smartpot/
COPY scripts/migrate.sh /opt/smartpot/migrate.sh
COPY init/01_init.sh /docker-entrypoint-initdb.d/01_init.sh
RUN chmod 0755 /opt/smartpot/migrate.sh /docker-entrypoint-initdb.d/01_init.sh

EXPOSE 5432

# El chequeo usa TCP en 127.0.0.1 y no el socket UNIX a propósito: durante la inicialización el entrypoint levanta
# un servidor temporal que solo escucha por socket, así que un pg_isready por socket lo declararía sano antes de que
# el servidor definitivo aplique la configuración y abra el puerto.
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
    CMD pg_isready -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-smartpot-root}" -d "${POSTGRES_DB:-smartpot}" || exit 1
