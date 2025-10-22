# Usar la imagen oficial de MongoDB
FROM mongo:latest

# Copiar el script de inicialización al directorio especial de MongoDB
COPY init.js /docker-entrypoint-initdb.d/

# Exponer el puerto de MongoDB
EXPOSE 27017

# Variables de entorno
ENV MONGO_INITDB_ROOT_USERNAME=admin
ENV MONGO_INITDB_ROOT_PASSWORD=admin
ENV MONGO_INITDB_DATABASE=smartpot

# Exponemos el puerto
EXPOSE 27017