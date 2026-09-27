// Datos de demostración: solo con SMARTPOT_SEED_DEMO=true. Nunca en una base productiva.
if ((process.env.SMARTPOT_SEED_DEMO || "false").toLowerCase() !== "true") {
    print("SMARTPOT_SEED_DEMO=false: la base queda vacía");
} else {
    const target = db.getSiblingDB(process.env.SMARTPOT_DB_NAME || "smartpot");
    const now = new Date();
    const hoursAgo = (hours) => new Date(now.getTime() - hours * 3600 * 1000);

    const demoUser = ObjectId("66f5a1000000000000000001");
    const lettuce = ObjectId("66f5a1000000000000000101");
    const tomato = ObjectId("66f5a1000000000000000102");

    // Contraseña SmartPot2026 (BCrypt, costo 12).
    target.users.insertOne({
        _id: demoUser,
        name: "Ana",
        lastName: "Demo",
        email: "demo@smartpot.app",
        passwordHash: "$2a$12$/ndyKLiS20yVdLYjL3bEF.wGnZWIpD6ehw3AAsZw4aBRGTnPh5/UC",
        role: "USER",
        createdAt: hoursAgo(72),
        updatedAt: hoursAgo(72)
    });

    // Las claves de dispositivo están cifradas con la clave AES de demostración
    // (SMARTPOT_AES_KEY del entorno demo): demo-lettuce-device-key-2026 y demo-tomato-device-key-2026.
    const crops = [
        {
            _id: lettuce, name: "Lechugas del balcón", type: "LETTUCE", form: "NFT",
            key: "dZoM-zwvWcnt7AeNAc525CnuHS_1gO24GfT1ueMeUsotqk5UG6ZdKeD8vaZFpL3RMbLAJ_FIREg",
            base: {temperature: 19, humidity: 62, brightness: 850, ph: 6.0, tds: 700, soilMoisture: 70}
        },
        {
            _id: tomato, name: "Tomates cherry", type: "TOMATO", form: "POT",
            key: "_NGpODcRRCGaJBGeHGquaU0Zpkup3YI-P-v4Ux9eRFPMs6kSiDNCx5Q4uWTWQ0Uds5rqGDnaxA",
            base: {temperature: 25, humidity: 68, brightness: 1300, ph: 6.2, tds: 2000, soilMoisture: 64}
        }
    ];

    for (const crop of crops) {
        target.crops.insertOne({
            _id: crop._id,
            ownerId: demoUser,
            name: crop.name,
            type: crop.type,
            // Los dos cultivos demo publican por MQTT con su clave, como un dispositivo real.
            kind: "REAL",
            form: crop.form,
            automationEnabled: crop.type === "LETTUCE",
            device: {keyCiphertext: crop.key, keyRotatedAt: hoursAgo(72), online: false, lastSeenAt: hoursAgo(1)},
            createdAt: hoursAgo(72),
            updatedAt: hoursAgo(72)
        });
        for (const type of ["WATER_PUMP", "UV_LIGHT", "FAN"]) {
            target.actuators.insertOne({cropId: crop._id, type: type, active: false, createdAt: hoursAgo(72)});
        }

        // 48 horas de lecturas cada 10 minutos con ciclo día/noche y ruido suave.
        // El ciclo alcanza su máximo a las 17:00 UTC, mediodía en Colombia (UTC−5).
        const readings = [];
        for (let step = 288; step >= 1; step--) {
            const measuredAt = new Date(now.getTime() - step * 10 * 60 * 1000);
            const day = Math.sin(((measuredAt.getUTCHours() - 11) / 24) * 2 * Math.PI);
            const noise = () => (Math.random() - 0.5);
            const b = crop.base;
            readings.push({
                cropId: crop._id,
                measuredAt: measuredAt,
                source: "MQTT",
                measures: {
                    temperature: +(b.temperature + day * 3 + noise()).toFixed(1),
                    humidity: +(b.humidity - day * 6 + noise() * 2).toFixed(1),
                    brightness: Math.max(0, Math.round(b.brightness * Math.max(0.05, day + 0.3) + noise() * 40)),
                    ph: +(b.ph + noise() * 0.15 + step / 2880).toFixed(2),
                    tds: Math.round(b.tds - step * 0.4 + noise() * 20),
                    atmosphere: +(1012 + noise() * 3).toFixed(1),
                    soilMoisture: +(b.soilMoisture - (step % 72) / 6 + noise()).toFixed(1)
                }
            });
        }
        target.readings.insertMany(readings);
    }

    const pump = target.actuators.findOne({cropId: lettuce, type: "WATER_PUMP"});
    target.commands.insertMany([
        {
            cropId: lettuce, actuatorId: pump._id, actuatorType: "WATER_PUMP", action: "ACTIVATE",
            durationSeconds: 15, status: "EXECUTED", source: "AGENT", reason: "El sustrato está seco: riego automático.",
            message: "Bomba encendida 15 s", createdAt: hoursAgo(5), sentAt: hoursAgo(5), completedAt: hoursAgo(5)
        },
        {
            cropId: lettuce, actuatorId: pump._id, actuatorType: "WATER_PUMP", action: "ACTIVATE",
            durationSeconds: 30, status: "EXECUTED", source: "USER", message: "Bomba encendida 30 s",
            createdAt: hoursAgo(20), sentAt: hoursAgo(20), completedAt: hoursAgo(20)
        }
    ]);

    target.notifications.insertMany([
        {
            userId: demoUser, type: "INFO", title: "¡Bienvenido a SmartPot!",
            message: "Crea tu primer cultivo, real o virtual, para empezar a monitorearlo.",
            read: true, createdAt: hoursAgo(72)
        },
        {
            userId: demoUser, cropId: lettuce, type: "AI", title: "El asistente actuó en Lechugas del balcón",
            message: "El sustrato está seco: riego automático.", read: false, createdAt: hoursAgo(5)
        }
    ]);

    print("Datos demo cargados: demo@smartpot.app / SmartPot2026 con 2 cultivos y 48 h de lecturas");
}
