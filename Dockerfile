# Usar la imagen oficial de MongoDB
FROM mongo:latest

# Copiar el script de inicialización al directorio especial de MongoDB
COPY init.js /docker-entrypoint-initdb.d/

# Exponer el puerto de MongoDB
EXPOSE 27017
