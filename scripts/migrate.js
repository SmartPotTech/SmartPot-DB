// Aplica los validadores de schemas/collections.js a una base existente, que ya no ejecuta los scripts de inicio.
// Es idempotente: se puede correr después de cada actualización de la imagen.
//   docker exec smartpot-db mongosh --quiet /opt/smartpot/migrate.js
// Se autentica con la cuenta root del contenedor, leída del entorno para que la clave no aparezca en la línea de
// comandos.
load("/opt/smartpot/schemas/collections.js");

const rootUser = process.env.MONGO_INITDB_ROOT_USERNAME;
const rootPassword = process.env.MONGO_INITDB_ROOT_PASSWORD;
if (!rootUser || !rootPassword) {
    throw new Error("Faltan MONGO_INITDB_ROOT_USERNAME y MONGO_INITDB_ROOT_PASSWORD en el entorno del contenedor");
}
db.getSiblingDB("admin").auth(rootUser, rootPassword);

const dbName = process.env.SMARTPOT_DB_NAME || "smartpot";
for (const result of applySmartPotSchemas(db.getSiblingDB(dbName))) {
    const note = result.invalid > 0 ? ` · ${result.invalid} documentos antiguos no cumplen el esquema` : "";
    print(`${dbName}.${result.name}: ${result.action} · validación ${result.level}${note}`);
}
