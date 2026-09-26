// Usuario de la aplicación con permisos solo sobre su base (la API no usa la cuenta root).
const dbName = process.env.SMARTPOT_DB_NAME || "smartpot";
const username = process.env.SMARTPOT_DB_USERNAME || "smartpot";
const password = process.env.SMARTPOT_DB_PASSWORD;

if (!password || password.length < 16) {
    throw new Error("SMARTPOT_DB_PASSWORD debe tener al menos 16 caracteres");
}

const target = db.getSiblingDB(dbName);
if (target.getUser(username)) {
    print(`El usuario ${username} ya existe en ${dbName}`);
} else {
    target.createUser({user: username, pwd: password, roles: [{role: "readWrite", db: dbName}]});
    print(`Usuario ${username} creado con permisos readWrite sobre ${dbName}`);
}
