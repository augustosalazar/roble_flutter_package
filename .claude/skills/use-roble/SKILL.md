---
name: use-roble
description: Integrar el paquete roble (Roble de Uninorte OpenLab) en una app Flutter. Usar para añadir autenticación, base de datos, árbol JSON, login con Google o tiempo real de Roble, para empezar una app desde cero, o para migrar una que ya habla con Roble con http a mano. Incluye un smoke que verifica la conexión contra el servidor real.
---

# Integrar el paquete `roble`

Cliente de Roble para Flutter. Este documento es para **añadirlo a una app que
no lo tiene**, o para migrar una que ya habla con Roble a mano.

**Empieza preguntando**, porque el camino cambia mucho:

1. ¿**Desde cero** o **migrando** algo que ya existe?
2. Si migra: ¿desde `http`/`dio` crudos, o desde una versión anterior?
3. ¿Qué necesita: solo cuentas, datos, login social, tiempo real, o todo?
4. ¿A qué plataformas apunta? Android e iOS piden configuración nativa para
   el login con Google; web no.

## Instalar

```bash
flutter pub add roble
```

Verificado con `roble 1.4.0` y Flutter 3.47.0.

En Android, `android/app/src/main/AndroidManifest.xml` necesita, dentro de
`<manifest>`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

## Verificar que funciona: el smoke

**Hazlo antes de escribir nada de la app.** Prueba conexión, cuentas, árbol
JSON y tiempo real de una pasada, contra el servidor real, y **limpia lo que
crea**: registra una cuenta desechable y la borra al terminar.

`smoke_test.dart` está **junto a este SKILL.md**. Cópialo a `test/` del
proyecto que estás integrando y córrelo desde ahí:

```bash
cp "$SKILL_DIR/smoke_test.dart" test/smoke_test.dart
ROBLE_CONTRACT_ID=tu_contrato flutter test test/smoke_test.dart --reporter expanded
```

**Ojo:** pub.dev no publica directorios ocultos, así que esta skill **no
viaja dentro del paquete**. Vive en el repo
`github.com/augustosalazar/roble_flutter_package`, en
`.claude/skills/use-roble/`. Si la necesitas en otro proyecto, cópiala de
ahí.

Salida real de una corrida buena:

```
00:00 +0: sin sesión: los proveedores son públicos
  proveedores: google
00:00 +1: flujo completo con una cuenta desechable
  login -> userId=b2216b68-2a77-4547-aea6-96052913852f role=user
  push -> mtbqbkod_Xvs1tz1sykVdXt1zaop3
  tiempo real: llegó el cambio
00:05 +2: All tests passed!
```

`ROBLE_BASE_URL` cambia el host; por omisión apunta al de pruebas de OpenLab.

Se corre con `flutter test` y no con `dart run` a propósito: el paquete
importa `package:flutter`, así que necesita el SDK de Flutter para arrancar.

Si el smoke pasa, el problema que venga después está en el código de la app,
no en la conexión.

## Empezar desde cero

Un cliente, **creado una sola vez** y compartido:

```dart
final db = RobleApiDataBase(
  config: RobleApiConfig.fromContract(
    baseUrl: 'https://roble-api.test-openlab.uninorte.edu.co',
    contractId: 'miproyecto_ab12cd34',
  ),
);
```

Crearlo en cada pantalla da a cada copia su propia sesión.

Al arrancar, antes de decidir qué pantalla mostrar:

```dart
if (await db.restoreSession()) {
  // pantalla principal
} else {
  // login
}
```

Lo demás —cuentas, tablas, árbol JSON, tiempo real, qué devuelve cada
método— está en el README del paquete. No lo repitas aquí.

### Login con Google

Una llamada, y el paquete elige el camino según la plataforma:

```dart
final usuario = await db.signInWithGoogle();
```

Hace falta, además:

- Configurar Google **en la consola de Roble** y registrar allí el «destino de
  retorno» de la app.
- Pasar `ssoRedirect` con el nombre de ese destino.
- En iOS, `googleIosClientId`. El Client ID **web** no: ese lo trae Roble.

## Migrar desde `http`/`dio` crudos

| Lo que había | Pasa a ser |
|---|---|
| `POST /auth/{c}/login` + guardar tokens a mano | `db.login(email:, password:)` |
| Refrescar el token en un interceptor | nada: el paquete lo hace solo |
| `GET /auth/{c}/me` | `db.currentUser()` |
| `GET /database/{c}/read?tableName=X` | `db.read('X')` |
| `POST /database/{c}/insert-one` | `db.create('X', {...})` |

**Borra el interceptor de refresco.** El paquete reintenta una vez ante un 401
por su cuenta; dos capas compitiendo producen refrescos duplicados.

**Deja de guardar los tokens tú.** El paquete los persiste en el almacenamiento
seguro y los recupera con `restoreSession()`.

## Migrar de 1.3.0 a 1.4.0

**Es aditivo: no desaparece ningún método ni cambia lo que devuelve ninguno.**
Actualizar no debería obligar a tocar nada.

Lo que gana: `signInWithGoogle()` y el resto del login social v2, `watchTable`
/ `watchRecord`, `db.json` (árbol JSON), `executeQueryByName`, y `role` en el
perfil.

`role` necesita `auth-service` v1.7.8 o más; contra uno anterior llega `null`.

## Gotchas

- **Bajo `flutter test` la sesión no persiste, y nadie te avisa.** El
  almacenamiento seguro es un plugin nativo y ahí no está registrado; el
  paquete se lo traga y `restoreSession()` devuelve `false` sin lanzar. En
  pruebas, **inyecta un `RobleTokenStorage` en memoria** — el smoke trae uno
  listo para copiar.

- **El tiempo real necesita ~1,5 s para abrir el socket.** Si escribes
  inmediatamente después de `watch()`, el evento se pierde: la suscripción aún
  no existía. El smoke espera a propósito antes de hacer `push`.

- **Cancela la suscripción al salir de la pantalla.** Un
  `StreamSubscription` sin `cancel()` deja el socket abierto.

- **Escuchar exige sesión iniciada.**

- **Con GetX, registra con `fenix: true`.** Un `Get.lazyPut` sin `fenix`
  consume su fábrica al descartar la ruta, y volver a entrar a la pantalla
  falla con «not found». Pasa con el cliente y con todo lo que cuelgue de él.

- **`register()` puede crear la cuenta sin verificar el correo.** Depende de
  la configuración del proyecto. No asumas que hace falta el código.

- **`role` es `null` si nadie asignó rol.** No es un error.

- **`id` y `userId` no son lo mismo** en el perfil. `userId` es el del
  usuario, el que referencian tus tablas; `id` es el de la fila del perfil.

## Troubleshooting

| Síntoma | Causa | Arreglo |
|---|---|---|
| `restoreSession()` siempre `false` en pruebas | el almacenamiento seguro no existe ahí | inyecta un `RobleTokenStorage` en memoria |
| El smoke falla en «proveedores» | `contractId` o `baseUrl` mal | cópialos de la consola de Roble |
| `AVISO tiempo real: no llegó ningún cambio` | el socket no llegó a suscribirse | sube la espera antes del `push` |
| «not found» al reentrar a una pantalla | `lazyPut` sin `fenix` | `fenix: true` en toda la cadena |
| 401 en todo tras un rato | sesión caducada | `restoreSession()`; si da `false`, pide login |
| 403 en `publicRead` | la tabla no está marcada como pública | márcala en la consola |
| 404 en `executeQueryByName` | no existe esa consulta guardada | créala en la consola, por nombre |
| `state inválido o expirado` en login social | el destino de retorno no coincide | registra la URL exacta en la consola y pásala en `ssoRedirect` |
