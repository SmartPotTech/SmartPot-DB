const db_admin = db.getSiblingDB("admin");

const username = process.env.MONGO_INITDB_ROOT_USERNAME || "admin";
const password = process.env.MONGO_INITDB_ROOT_PASSWORD || "admin";
const database = process.env.MONGO_INITDB_DATABASE || "smartpot";

const userExists = db_admin.getUser(username);

if (!userExists) {
    print(`Creando usuario ${username}...`);
    db_admin.createUser({
        user: username,
        pwd: password,
        roles: [{ role: "root", db: "admin" }]
    });
} else {
    print(`Usuario ${username} ya existe, actualizando contraseña...`);
    db_admin.updateUser(username, { pwd: password });
}

db = db.getSiblingDB(database);

db.createCollection('usuarios');
db.usuarios.insertMany([
    {
        "_id": ObjectId("672811d1c78d172fd8a89775"),
        "name": "Juan",
        "lastname": "Perez",
        "email": "juan.perez@example.com",
        "create_at": ISODate("2024-11-07T00:20:07.973Z"),
        "password": "$2a$12$4n181KR5etTwn1Qp1ka2je79lrxXYhVuUa3kqvQfQPDx1V2LcCTKu",
        "role": "USER",
        "_class": "smartpot.com.api.Models.Entity.User"
    },
    {
        "_id": ObjectId("672811d1c78d172fd8a89776"),
        "name": "Pedro",
        "lastname": "Nel",
        "email": "pedro@example.com",
        "create_at": ISODate("2024-11-07T00:20:07.973Z"),
        "password": "$2a$12$NPT9v8QoWxbbdoOuskROpOs48EJdgJAT4dmHu.bx5ReNF9kfW7cn.",
        "role": "USER",
        "_class": "smartpot.com.api.Models.Entity.User"
    }
]);

db.createCollection('cultivos');
db.cultivos.insertMany([
    {
        "_id": ObjectId("672ebd43e9227768a15b11df"),
        "status": "Excellent",
        "type": "TOMATTO",
        "user": ObjectId("672811d1c78d172fd8a89775"),
        "_class": "smartpot.com.api.Models.Entity.Crop"
    }
]);


db.createCollection('comandos');
db.comandos.insertMany([
    {
        "commandType": "ACTIVATE_WATER_PUMP",
        "status": "EXECUTED",
        "dateCreated": ISODate("2024-11-05T15:00:40.100Z"),
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.Command"
    },
    {
        "commandType": "ACTIVATE_WATER_PUMP",
        "status": "EXECUTED",
        "dateCreated": ISODate("2024-11-05T15:00:40.100Z"),
        "response": "SUCCESSFUL",
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.Command"
    },
    {
        "commandType": "ACTIVATE_WATER_PUMP",
        "status": "PENDING",
        "dateCreated": ISODate("2024-11-06T04:17:57.398Z"),
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.Command"
    }
]);


db.createCollection('notificaciones');
db.notificaciones.insertMany([
    {
        "message": "Estamos al pendiente de tu planta.",
        "type": "alerta",
        "date": ISODate("2024-11-06T04:13:08.902Z"),
        "_class": "smartpot.com.api.Models.Entity.Notification",
        "user": ObjectId("672ebd43e9227768a15b11df")
    }
]);

db.createCollection('sesiones');
db.sesiones.insertMany([
    {
        "registration": ISODate("2023-11-05T12:30:00.000Z"),
        "user": ObjectId("672811d1c78d172fd8a89775"),
        "_class": "smartpot.com.api.Models.Entity.Session"
    }
]);

db.createCollection('registros');
db.registros.insertMany([
    {
        "date": new ISODate("2024-11-01T00:00:00.000Z"),
        "measures": {
            "atmosphere": 18,
            "brightness": 1270,
            "temperature": 24,
            "ph": 7,
            "tds": 10,
            "humidity": 10
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-01T12:00:00.000Z"),
        "measures": {
            "atmosphere": 18.2,
            "brightness": 1272,
            "temperature": 24.3,
            "ph": 7.05,
            "tds": 10.2,
            "humidity": 11
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-02T00:00:00.000Z"),
        "measures": {
            "atmosphere": 18.5,
            "brightness": 1273,
            "temperature": 24.5,
            "ph": 7.1,
            "tds": 10.5,
            "humidity": 12
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-02T12:00:00.000Z"),
        "measures": {
            "atmosphere": 19,
            "brightness": 1275,
            "temperature": 24.8,
            "ph": 7.15,
            "tds": 10.7,
            "humidity": 13
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-03T00:00:00.000Z"),
        "measures": {
            "atmosphere": 19,
            "brightness": 1275,
            "temperature": 25,
            "ph": 7.2,
            "tds": 11,
            "humidity": 14
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-03T12:00:00.000Z"),
        "measures": {
            "atmosphere": 19.5,
            "brightness": 1277,
            "temperature": 25.2,
            "ph": 7.25,
            "tds": 11.2,
            "humidity": 15
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-04T00:00:00.000Z"),
        "measures": {
            "atmosphere": 19.5,
            "brightness": 1278,
            "temperature": 25.5,
            "ph": 7.3,
            "tds": 11.5,
            "humidity": 16
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-04T12:00:00.000Z"),
        "measures": {
            "atmosphere": 20,
            "brightness": 1280,
            "temperature": 25.8,
            "ph": 7.35,
            "tds": 11.8,
            "humidity": 17
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-05T00:00:00.000Z"),
        "measures": {
            "atmosphere": 20,
            "brightness": 1280,
            "temperature": 26,
            "ph": 7.4,
            "tds": 12,
            "humidity": 18
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-05T12:00:00.000Z"),
        "measures": {
            "atmosphere": 20.6,
            "brightness": 1283,
            "temperature": 26.2,
            "ph": 7.45,
            "tds": 12.3,
            "humidity": 19
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-06T00:00:00.000Z"),
        "measures": {
            "atmosphere": 20.5,
            "brightness": 1283,
            "temperature": 26.5,
            "ph": 7.5,
            "tds": 12.5,
            "humidity": 20
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-06T12:00:00.000Z"),
        "measures": {
            "atmosphere": 21,
            "brightness": 1286,
            "temperature": 26.7,
            "ph": 7.55,
            "tds": 12.8,
            "humidity": 21
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-07T00:00:00.000Z"),
        "measures": {
            "atmosphere": 21,
            "brightness": 1285,
            "temperature": 27,
            "ph": 7.6,
            "tds": 13,
            "humidity": 22
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-07T12:00:00.000Z"),
        "measures": {
            "atmosphere": 21.5,
            "brightness": 1289,
            "temperature": 27.1,
            "ph": 7.65,
            "tds": 13.3,
            "humidity": 23
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-08T00:00:00.000Z"),
        "measures": {
            "atmosphere": 21.5,
            "brightness": 1288,
            "temperature": 27.5,
            "ph": 7.7,
            "tds": 13.5,
            "humidity": 24
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-08T12:00:00.000Z"),
        "measures": {
            "atmosphere": 22,
            "brightness": 1292,
            "temperature": 27.5,
            "ph": 7.75,
            "tds": 13.8,
            "humidity": 25
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-09T00:00:00.000Z"),
        "measures": {
            "atmosphere": 22,
            "brightness": 1290,
            "temperature": 28,
            "ph": 7.8,
            "tds": 14,
            "humidity": 26
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-09T12:00:00.000Z"),
        "measures": {
            "atmosphere": 22.5,
            "brightness": 1295,
            "temperature": 28,
            "ph": 7.85,
            "tds": 14.3,
            "humidity": 27
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-10T00:00:00.000Z"),
        "measures": {
            "atmosphere": 22.5,
            "brightness": 1293,
            "temperature": 28.5,
            "ph": 7.9,
            "tds": 14.5,
            "humidity": 28
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-10T12:00:00.000Z"),
        "measures": {
            "atmosphere": 23,
            "brightness": 1297,
            "temperature": 28.4,
            "ph": 7.95,
            "tds": 14.8,
            "humidity": 29
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-11T00:00:00.000Z"),
        "measures": {
            "atmosphere": 23,
            "brightness": 1295,
            "temperature": 29,
            "ph": 8,
            "tds": 15,
            "humidity": 30
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-11T12:00:00.000Z"),
        "measures": {
            "atmosphere": 23.5,
            "brightness": 1300,
            "temperature": 28.9,
            "ph": 8,
            "tds": 15.2,
            "humidity": 31
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-12T00:00:00.000Z"),
        "measures": {
            "atmosphere": 23.5,
            "brightness": 1298,
            "temperature": 29.5,
            "ph": 8.1,
            "tds": 15.5,
            "humidity": 32
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-12T12:00:00.000Z"),
        "measures": {
            "atmosphere": 24,
            "brightness": 1303,
            "temperature": 29.2,
            "ph": 8.05,
            "tds": 15.7,
            "humidity": 33
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-13T00:00:00.000Z"),
        "measures": {
            "atmosphere": 24,
            "brightness": 1300,
            "temperature": 30,
            "ph": 8.2,
            "tds": 16,
            "humidity": 34
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-13T12:00:00.000Z"),
        "measures": {
            "atmosphere": 24.5,
            "brightness": 1306,
            "temperature": 29.6,
            "ph": 8.15,
            "tds": 16.2,
            "humidity": 35
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-14T00:00:00.000Z"),
        "measures": {
            "atmosphere": 24.5,
            "brightness": 1303,
            "temperature": 30.5,
            "ph": 8.3,
            "tds": 16.5,
            "humidity": 36
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-14T12:00:00.000Z"),
        "measures": {
            "atmosphere": 25,
            "brightness": 1308,
            "temperature": 30,
            "ph": 8.25,
            "tds": 16.7,
            "humidity": 37
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-15T00:00:00.000Z"),
        "measures": {
            "atmosphere": 25,
            "brightness": 1305,
            "temperature": 31,
            "ph": 8.4,
            "tds": 17,
            "humidity": 38
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-15T12:00:00.000Z"),
        "measures": {
            "atmosphere": 25.5,
            "brightness": 1311,
            "temperature": 30.4,
            "ph": 8.35,
            "tds": 17.2,
            "humidity": 39
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-16T00:00:00.000Z"),
        "measures": {
            "atmosphere": 25.5,
            "brightness": 1308,
            "temperature": 31.5,
            "ph": 8.5,
            "tds": 17.5,
            "humidity": 40
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-16T12:00:00.000Z"),
        "measures": {
            "atmosphere": 26,
            "brightness": 1313,
            "temperature": 30.9,
            "ph": 8.45,
            "tds": 17.7,
            "humidity": 41
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-17T00:00:00.000Z"),
        "measures": {
            "atmosphere": 26,
            "brightness": 1310,
            "temperature": 32,
            "ph": 8.6,
            "tds": 18,
            "humidity": 42
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-17T12:00:00.000Z"),
        "measures": {
            "atmosphere": 26.5,
            "brightness": 1316,
            "temperature": 31.3,
            "ph": 8.55,
            "tds": 18.2,
            "humidity": 43
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-18T00:00:00.000Z"),
        "measures": {
            "atmosphere": 26.5,
            "brightness": 1313,
            "temperature": 32.5,
            "ph": 8.7,
            "tds": 18.5,
            "humidity": 44
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-18T12:00:00.000Z"),
        "measures": {
            "atmosphere": 27,
            "brightness": 1318,
            "temperature": 31.7,
            "ph": 8.65,
            "tds": 18.8,
            "humidity": 45
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-19T00:00:00.000Z"),
        "measures": {
            "atmosphere": 27,
            "brightness": 1315,
            "temperature": 33,
            "ph": 8.8,
            "tds": 19,
            "humidity": 46
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-19T12:00:00.000Z"),
        "measures": {
            "atmosphere": 27.5,
            "brightness": 1320,
            "temperature": 32.1,
            "ph": 8.75,
            "tds": 19.3,
            "humidity": 47
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-20T00:00:00.000Z"),
        "measures": {
            "atmosphere": 27.5,
            "brightness": 1318,
            "temperature": 33.5,
            "ph": 8.9,
            "tds": 19.5,
            "humidity": 48
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-20T12:00:00.000Z"),
        "measures": {
            "atmosphere": 28,
            "brightness": 1323,
            "temperature": 32.5,
            "ph": 8.85,
            "tds": 19.8,
            "humidity": 49
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-21T00:00:00.000Z"),
        "measures": {
            "atmosphere": 28,
            "brightness": 1320,
            "temperature": 34,
            "ph": 9,
            "tds": 20,
            "humidity": 50
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-21T12:00:00.000Z"),
        "measures": {
            "atmosphere": 28.5,
            "brightness": 1325,
            "temperature": 33,
            "ph": 8.95,
            "tds": 20.3,
            "humidity": 51
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-22T00:00:00.000Z"),
        "measures": {
            "atmosphere": 28.5,
            "brightness": 1323,
            "temperature": 34.5,
            "ph": 9.1,
            "tds": 20.5,
            "humidity": 52
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-22T12:00:00.000Z"),
        "measures": {
            "atmosphere": 29,
            "brightness": 1328,
            "temperature": 33.4,
            "ph": 9.05,
            "tds": 20.8,
            "humidity": 53
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-23T00:00:00.000Z"),
        "measures": {
            "atmosphere": 29,
            "brightness": 1325,
            "temperature": 35,
            "ph": 9.2,
            "tds": 21,
            "humidity": 54
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-23T12:00:00.000Z"),
        "measures": {
            "atmosphere": 29.5,
            "brightness": 1330,
            "temperature": 33.9,
            "ph": 9.15,
            "tds": 21.3,
            "humidity": 55
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-24T00:00:00.000Z"),
        "measures": {
            "atmosphere": 29.5,
            "brightness": 1328,
            "temperature": 35.5,
            "ph": 9.3,
            "tds": 21.5,
            "humidity": 56
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-24T12:00:00.000Z"),
        "measures": {
            "atmosphere": 30,
            "brightness": 1333,
            "temperature": 34.3,
            "ph": 9.25,
            "tds": 21.8,
            "humidity": 57
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-25T00:00:00.000Z"),
        "measures": {
            "atmosphere": 30,
            "brightness": 1330,
            "temperature": 36,
            "ph": 9.4,
            "tds": 22,
            "humidity": 58
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-26T00:00:00.000Z"),
        "measures": {
            "atmosphere": 30.5,
            "brightness": 1333,
            "temperature": 36.5,
            "ph": 9.5,
            "tds": 22.5,
            "humidity": 60
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-27T00:00:00.000Z"),
        "measures": {
            "atmosphere": 31,
            "brightness": 1335,
            "temperature": 37,
            "ph": 9.6,
            "tds": 23,
            "humidity": 62
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-28T00:00:00.000Z"),
        "measures": {
            "atmosphere": 31.5,
            "brightness": 1338,
            "temperature": 37.5,
            "ph": 9.7,
            "tds": 23.5,
            "humidity": 64
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-29T00:00:00.000Z"),
        "measures": {
            "atmosphere": 32,
            "brightness": 1340,
            "temperature": 38,
            "ph": 9.8,
            "tds": 24,
            "humidity": 66
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    },
    {
        "date": new ISODate("2024-11-30T00:00:00.000Z"),
        "measures": {
            "atmosphere": 32.5,
            "brightness": 1343,
            "temperature": 38.5,
            "ph": 9.9,
            "tds": 24.5,
            "humidity": 68
        },
        "crop": ObjectId("672ebd43e9227768a15b11df"),
        "_class": "smartpot.com.api.Models.Entity.History"
    }]);
