// Validación de las colecciones de SmartPot: la base rechaza documentos sin los campos que la API necesita.
// La usan el script de inicio (base nueva) y la migración (base existente); aplicarla varias veces no cambia nada.
// Los índices los crea la API al arrancar (auto-index-creation) para no duplicar su definición.

const CROP_TYPES = ["TOMATO", "LETTUCE", "STRAWBERRY", "BASIL", "SPINACH", "PEPPER"];
const ACTUATOR_TYPES = ["WATER_PUMP", "UV_LIGHT", "FAN", "HUMIDIFIER", "NUTRIENT_DOSER", "PH_DOSER"];
const NOTIFICATION_TYPES = ["INFO", "ALERT", "COMMAND", "DEVICE", "AI"];

globalThis.SMARTPOT_SCHEMAS = {
    users: {
        required: ["email", "passwordHash", "role", "createdAt"],
        properties: {
            email: {bsonType: "string", pattern: "^[^@\\s]+@[^@\\s]+$"},
            passwordHash: {bsonType: "string", minLength: 59},
            role: {enum: ["USER", "ADMIN"]},
            createdAt: {bsonType: "date"}
        }
    },
    crops: {
        required: ["ownerId", "name", "type", "automationEnabled", "createdAt"],
        properties: {
            ownerId: {bsonType: "objectId"},
            name: {bsonType: "string", minLength: 1, maxLength: 60},
            type: {enum: CROP_TYPES},
            automationEnabled: {bsonType: "bool"},
            createdAt: {bsonType: "date"}
        }
    },
    readings: {
        required: ["cropId", "measuredAt", "measures"],
        properties: {
            cropId: {bsonType: "objectId"},
            measuredAt: {bsonType: "date"},
            measures: {bsonType: "object"},
            source: {enum: ["MQTT", "HTTP"]}
        }
    },
    actuators: {
        required: ["cropId", "type", "active"],
        properties: {
            cropId: {bsonType: "objectId"},
            type: {enum: ACTUATOR_TYPES},
            active: {bsonType: "bool"}
        }
    },
    commands: {
        required: ["cropId", "actuatorId", "actuatorType", "action", "status", "source", "createdAt"],
        properties: {
            cropId: {bsonType: "objectId"},
            actuatorId: {bsonType: "objectId"},
            actuatorType: {enum: ACTUATOR_TYPES},
            action: {enum: ["ACTIVATE", "DEACTIVATE"]},
            status: {enum: ["PENDING", "SENT", "EXECUTED", "FAILED", "EXPIRED"]},
            source: {enum: ["USER", "AGENT"]},
            createdAt: {bsonType: "date"}
        }
    },
    notifications: {
        required: ["userId", "type", "title", "message", "read", "createdAt"],
        properties: {
            userId: {bsonType: "objectId"},
            type: {enum: NOTIFICATION_TYPES},
            title: {bsonType: "string"},
            message: {bsonType: "string"},
            read: {bsonType: "bool"},
            createdAt: {bsonType: "date"}
        }
    },
    password_reset_tokens: {
        required: ["tokenHash", "userId", "expiresAt"],
        properties: {
            tokenHash: {bsonType: "string", minLength: 64, maxLength: 64},
            userId: {bsonType: "objectId"},
            expiresAt: {bsonType: "date"}
        }
    },
    // Vínculo de una cuenta con un canal externo (hoy Telegram): address es el id del chat.
    channel_links: {
        required: ["userId", "type", "address", "enabled", "events", "linkedAt", "failures"],
        properties: {
            userId: {bsonType: "objectId"},
            type: {enum: ["TELEGRAM"]},
            address: {bsonType: "string", minLength: 1, maxLength: 64},
            displayName: {bsonType: "string", maxLength: 200},
            enabled: {bsonType: "bool"},
            events: {bsonType: "array", maxItems: NOTIFICATION_TYPES.length, uniqueItems: true,
                items: {enum: NOTIFICATION_TYPES}},
            linkedAt: {bsonType: "date"},
            lastDeliveredAt: {bsonType: "date"},
            failures: {bsonType: "int", minimum: 0}
        }
    },
    // Maceta virtual de un cultivo: el simulador la recrea a partir de este documento.
    virtual_devices: {
        required: ["cropId", "ownerId", "mode", "intervalSeconds", "createdAt", "updatedAt"],
        properties: {
            cropId: {bsonType: "objectId"},
            ownerId: {bsonType: "objectId"},
            mode: {enum: ["AUTO", "MANUAL", "WEATHER"]},
            manual: {bsonType: "object"},
            location: {
                bsonType: "object",
                required: ["name", "latitude", "longitude"],
                properties: {
                    name: {bsonType: "string", minLength: 1, maxLength: 120},
                    latitude: {bsonType: "double", minimum: -90, maximum: 90},
                    longitude: {bsonType: "double", minimum: -180, maximum: 180}
                }
            },
            intervalSeconds: {bsonType: "int", minimum: 10, maximum: 300},
            createdAt: {bsonType: "date"},
            updatedAt: {bsonType: "date"}
        }
    }
};

// Crea cada colección con su validador o, si ya existe, se lo aplica con collMod. Si hay documentos que no
// cumplen el esquema, la validación queda en "moderate": los documentos nuevos y los que ya cumplen se validan,
// y los antiguos se pueden seguir actualizando hasta corregirlos.
globalThis.applySmartPotSchemas = function (target) {
    const existing = new Set(target.getCollectionNames());
    return Object.entries(globalThis.SMARTPOT_SCHEMAS).map(([name, schema]) => {
        const validator = {$jsonSchema: {bsonType: "object", ...schema}};
        if (!existing.has(name)) {
            target.createCollection(name, {validator, validationLevel: "strict", validationAction: "error"});
            return {name, action: "creada", level: "strict", invalid: 0};
        }
        const invalid = target.getCollection(name).countDocuments({$nor: [validator]});
        const level = invalid === 0 ? "strict" : "moderate";
        target.runCommand({collMod: name, validator, validationLevel: level, validationAction: "error"});
        return {name, action: "actualizada", level, invalid};
    });
};
