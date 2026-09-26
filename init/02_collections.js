// Colecciones con validación: la base rechaza documentos sin los campos que la API necesita.
// Los índices los crea la API al arrancar (auto-index-creation) para no duplicar su definición.
const target = db.getSiblingDB(process.env.SMARTPOT_DB_NAME || "smartpot");

const CROP_TYPES = ["TOMATO", "LETTUCE", "STRAWBERRY", "BASIL", "SPINACH", "PEPPER"];
const ACTUATOR_TYPES = ["WATER_PUMP", "UV_LIGHT", "FAN", "HUMIDIFIER", "NUTRIENT_DOSER", "PH_DOSER"];

const schemas = {
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
            type: {enum: ["INFO", "ALERT", "COMMAND", "DEVICE", "AI"]},
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
    }
};

for (const [name, schema] of Object.entries(schemas)) {
    target.createCollection(name, {
        validator: {$jsonSchema: {bsonType: "object", ...schema}},
        validationLevel: "strict",
        validationAction: "error"
    });
}
print(`Colecciones creadas: ${Object.keys(schemas).join(", ")}`);
