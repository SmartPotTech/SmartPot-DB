FROM mongo:8.0

LABEL org.opencontainers.image.title="SmartPot DB" \
      org.opencontainers.image.description="MongoDB de SmartPot con validación de colecciones y datos demo opcionales" \
      org.opencontainers.image.source="https://github.com/SmartPotTech/SmartPot-DB" \
      org.opencontainers.image.licenses="MIT"

ENV MONGO_INITDB_DATABASE=smartpot \
    SMARTPOT_DB_NAME=smartpot \
    SMARTPOT_DB_USERNAME=smartpot \
    SMARTPOT_SEED_DEMO=false

# Los esquemas los comparten el inicio de una base nueva y la migración de una base existente.
COPY --chown=999:999 schemas/ /opt/smartpot/schemas/
COPY --chown=999:999 scripts/migrate.js /opt/smartpot/migrate.js
COPY --chown=999:999 init/ /docker-entrypoint-initdb.d/

USER 999:999

EXPOSE 27017

HEALTHCHECK --interval=15s --timeout=5s --start-period=40s --retries=5 \
    CMD mongosh --quiet --eval "quit(db.adminCommand('ping').ok ? 0 : 1)" || exit 1
