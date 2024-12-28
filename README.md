# SmartPot-DB (MongoDB)

## Deployment

[![Docker Image CI](https://github.com/SmartPotTech/SmartPot-DB/actions/workflows/docker-image.yml/badge.svg)](https://github.com/SmartPotTech/SmartPot-DB/actions/workflows/docker-image.yml)

### 1. Creación de la Imagen Docker

Para crear la imagen Docker de la base de datos MongoDB personalizada, sigue estos pasos:

- **Ejecuta el siguiente comando** para construir la imagen de MongoDB:

```bash
docker build --platform linux/amd64 -t sebastian190030/db-smartpot:latest .
```

- Esto construye la imagen de Docker personalizada usando el `Dockerfile` que ya debe existir en tu proyecto.

### 2. Publicación de la Imagen en Docker Hub

Una vez que la imagen esté construida, puedes subirla a Docker Hub para tenerla disponible desde cualquier entorno:

- **Inicia sesión en Docker Hub** desde la terminal:

```bash
docker login
```

- **Sube la imagen** a tu repositorio en Docker Hub (cambiando `sebastian190030` por tu nombre de usuario):

```bash
docker push sebastian190030/db-smartpot:latest
```

- Esto sube la imagen creada a Docker Hub, haciéndola accesible para su distribución o despliegue en otros entornos.
