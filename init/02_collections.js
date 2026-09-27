// Colecciones con validación en una base nueva; las definiciones viven en schemas/collections.js.
load("/opt/smartpot/schemas/collections.js");

const target = db.getSiblingDB(process.env.SMARTPOT_DB_NAME || "smartpot");
const results = applySmartPotSchemas(target);
print(`Colecciones con validación: ${results.map((result) => result.name).join(", ")}`);
