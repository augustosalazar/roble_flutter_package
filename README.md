# roble

Cliente de Flutter para **Roble**, la plataforma de Uninorte OpenLab.

Con este paquete tu app puede tener cuentas de usuario, guardar datos y
enterarse de los cambios al momento, sin que escribas backend.

---

## Instalación

```bash
flutter pub add roble
```

En Android, abre `android/app/src/main/AndroidManifest.xml` y añade permiso de
internet dentro de `<manifest>`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

---

## Tu primer minuto

Necesitas dos datos de la consola de Roble: la **URL** y el **id de tu
proyecto** (el «contrato»).

```dart
import 'package:roble/roble.dart';

final db = RobleApiDataBase(
  config: RobleApiConfig.fromContract(
    baseUrl: 'https://roble-api.test-openlab.uninorte.edu.co',
    contractId: 'miproyecto_ab12cd34',
  ),
);

// Crear una cuenta
await db.register(
  email: 'ana@correo.com',
  password: 'MiClave!1',
  name: 'Ana García',
);

// Entrar. Devuelve el perfil.
final usuario = await db.login(
  email: 'ana@correo.com',
  password: 'MiClave!1',
);
print('Hola ${usuario['name']}');
```

Crea `db` **una sola vez** en tu app y reutilízalo. Si lo creas de nuevo en
cada pantalla, cada copia tendrá su propia sesión.

---

## Cuentas de usuario

### Entrar y salir

```dart
await db.login(email: correo, password: clave);
await db.logout();

if (db.isLoggedIn) print('Hay alguien dentro');

final perfil = await db.currentUser();
```

### Qué devuelve el login

`login()`, `signInWithGoogle()` y cualquier otra forma de entrar devuelven
**el mismo mapa**: el perfil de la persona.

```dart
{
  'id': 'us-3f2a…',            // fila del perfil
  'userId': '9c1e…',           // el usuario. Este es el que referencian tus tablas
  'email': 'ana@correo.com',
  'name': 'Ana García',
  'role': 'admin',             // null si no tiene rol asignado
  'extra': {'programa': 'Sistemas'},
  'createdAt': '2026-08-27T12:00:00.000Z',
  'updatedAt': null,
}
```

Dos avisos:

- **`id` y `userId` no son lo mismo.** `userId` es el del usuario, el que
  guardas en tus tablas para saber de quién es cada fila. `id` es el de la
  fila del perfil.
- **`role` puede ser `null`**, si nadie le asignó rol. No es un error.

`currentUser()` devuelve exactamente esto mismo, y es lo que usas después de
`restoreSession()` para saber quién entró.

### Que la sesión sobreviva a cerrar la app

Por omisión la sesión se guarda en el almacenamiento seguro del teléfono. Al
arrancar, pregúntale a Roble si sigue siendo válida:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (await db.restoreSession()) {
    // Entra directo a la pantalla principal
  } else {
    // Muestra el login
  }
  runApp(MiApp());
}
```

### Registro con código por correo

Si prefieres confirmar que el correo existe antes de crear la cuenta:

```dart
await db.registerWithVerification(
  email: 'ana@correo.com',
  password: 'MiClave!1',
  name: 'Ana García',
);

// Ana recibe un código y lo escribe en tu pantalla
await db.verifyEmail(email: 'ana@correo.com', code: '123456');
```

`resendCode(email: ...)` lo manda otra vez si no llegó.

### Contraseña olvidada

```dart
await db.forgotPassword(email: 'ana@correo.com');
// Le llega un código por correo
await db.resetPassword(token: '123456', newPassword: 'OtraClave!2');
```

---

## Entrar con Google

Una línea:

```dart
final usuario = await db.signInWithGoogle();
```

En móvil sale el selector de cuentas del teléfono. En web se abre una ventana.
El paquete elige solo.

Antes tienes que configurar Google **en la consola de Roble** y registrar allí
el «destino de retorno» de tu app. En iOS, además, pasa el Client ID de iOS al
crear el cliente:

```dart
RobleApiDataBase(
  config: config,
  googleIosClientId: 'xxxx.apps.googleusercontent.com',
  ssoRedirect: 'mi-app-web', // el nombre que registraste en la consola
);
```

### Un destino de retorno por entorno

`ssoRedirect` no es una URL: es el **nombre** de un destino registrado en la
consola. La URL vive allí, así que puedes tener varios y elegir cuál usa cada
build.

Registra uno por entorno en vez de irle cambiando la URL al mismo:

| Nombre en la consola | URL |
|---|---|
| `mi-app-web-dev` | `http://localhost:5001` |
| `mi-app-web` | `https://mi-dominio` |
| `mi-app-movil` | `com.miempresa.miapp://sso-done` |

Así desarrollo y producción no se pelean por el mismo sitio, y puedes probar el
flujo real en local sin tocar lo que usan los demás. Publicar deja de ser un
cambio en la consola: es otro valor en la configuración de ese build.

> **En local, el puerto forma parte del destino.** `flutter run -d chrome` elige
> un puerto distinto en cada arranque si no se lo fijas, así que Google
> autentica bien y te devuelve a un puerto donde ya no hay nadie:
> `ERR_CONNECTION_REFUSED`, que parece un fallo del login y no lo es.
>
> ```bash
> flutter run -d chrome --web-port=5001
> ```
>
> Y `localhost` no es `127.0.0.1` para el proveedor, aunque sean la misma
> máquina: abre la app por el mismo origen que registraste.

Fuera de web el destino es el esquema propio de la app, declarado en
`AndroidManifest.xml` y en `Info.plist`. No lleva dominio, así que no cambia al
publicar.

¿Qué proveedores tienes activos? Para pintar solo los botones que funcionan:

```dart
for (final p in await db.listProviders()) {
  print(p.displayName); // "Google", "Microsoft"…
}
```

---

## Guardar datos: tablas

Una tabla es como una hoja de cálculo: la creas en la consola con sus columnas,
y desde la app la llenas.

```dart
// Crear
final producto = await db.create('Product', {
  'name': 'Café',
  'quantity': 12,
});

// Leer todo
final todos = await db.read('Product');

// Leer con filtro (igualdad)
final agotados = await db.read('Product', filters: {'quantity': 0});

// Uno solo, por su id
final uno = await db.getById('Product', producto['_id']);

// Cambiar
await db.update('Product', producto['_id'], {'quantity': 11});

// Borrar
await db.delete('Product', producto['_id']);
```

Cada registro trae un `_id` que pone Roble. Es lo que usas para cambiarlo o
borrarlo.

### Varios de golpe

```dart
final res = await db.createMany('Product', [
  {'name': 'Té', 'quantity': 5},
  {'name': 'Pan', 'quantity': 0},
]);
print('Guardados: ${res.inserted.length}, rechazados: ${res.skipped.length}');
```

### Consultas más complicadas

`read` solo filtra por igualdad. Para juntar tablas, sumar o paginar, guarda la
consulta SQL en la consola y llámala **por su nombre**:

```dart
final res = await db.executeQueryByName('productosSinInventario');
for (final fila in res.rows) print(fila);
```

Usa el nombre, no el UUID: el nombre sobrevive si recreas la consulta.

### Una tabla que todos pueden leer

Si marcas una tabla como pública en la consola, se puede leer **sin haber
iniciado sesión**:

```dart
final catalogo = await db.publicRead('Product');
```

Ojo: público es público. Cualquiera con el id del proyecto puede leerla.

---

## Guardar datos: árbol JSON

A veces no vale la pena declarar una tabla: un chat, un tablero, una partida.
Para eso está el árbol JSON. **No declaras nada**: la estructura nace cuando
escribes el primer dato.

```dart
// Añadir, con clave que genera el servidor
final id = await db.json.push('mensajes', {
  'texto': 'hola',
  'de': 'ana@correo.com',
});

// Leer la colección entera
final todos = await db.json.read('mensajes');

// Cambiar solo una clave
await db.json.update('mensajes/$id', {'leido': true});

// Borrar
await db.json.remove('mensajes/$id');
```

Una ruta es `coleccion/hijo/nieto`. El primer trozo es la colección.

Las claves de `push` salen ordenadas por tiempo, así que ordenarlas ordena los
mensajes — sin depender del reloj de cada teléfono.

### ¿Tabla o árbol JSON?

| Usa una **tabla** cuando | Usa el **árbol JSON** cuando |
|---|---|
| Los datos tienen forma fija | La forma cambia o no importa |
| Quieres consultas SQL | Solo lees y escribes por ruta |
| Son datos del negocio | Son datos que van y vienen |

---

## Enterarse de los cambios al momento

Escuchar te avisa cuando **otro** usuario cambia algo, sin que tengas que
recargar.

```dart
// Una tabla
final sub = db.watchTable('Product').listen((cambio) {
  print('${cambio.type}: ${cambio.record}');
});

// Un solo registro
db.watchRecord('Product', id).listen((cambio) { ... });

// El árbol JSON
db.json.watch('mensajes').listen((cambio) {
  // En un push, `record` trae {claveNueva: dato}
  cambio.record?.forEach((id, dato) => print(dato));
});

// Al salir de la pantalla
await sub.cancel();
```

Tres cosas que conviene saber:

- **No trae lo que ya existe**, solo lo que cambie de ahora en adelante. Para
  pintar la lista, léela primero y aplica encima lo que llegue.
- **Cancela al salir** de la pantalla. Si no, el socket sigue abierto.
- **Hace falta sesión iniciada.**

Puedes pedir solo algunos cambios, o filtrar en el servidor:

```dart
db.watchTable(
  'Product',
  events: [RobleChangeType.insert],
  filters: [RobleFilter('quantity', 'eq', 0)],
).listen(...);
```

Filtrar aquí ahorra el viaje de todo lo que no te interesa.

---

## Notificaciones

Avisos que se guardan y llegan al momento a quien tenga la app abierta. Es otra
cosa que el árbol JSON: no hay colección que crear, no hay ruta que elegir, y el
destinatario es un usuario del proyecto.

```dart
// Escuchar lo que vaya llegando.
db.notifications.watch().listen((evento) {
  if (evento.type == RobleNotificationEventType.created) {
    mostrarAviso(evento.notification.title);
  }
});

// Enviar a alguien.
await db.notifications.send(
  to: otroUsuarioId,
  title: 'Te toca',
  body: 'Ana movió ficha',
  topic: 'partida',
  data: {'partidaId': '42'},
);
```

El `data` es tuyo: lo que la pantalla necesite para abrir lo correcto cuando
alguien toque el aviso.

### A todo el proyecto

```dart
await db.notifications.send(
  to: robleNotificationEveryone,
  title: 'Mañana no hay clase',
);
```

Llega a todos. Cada persona la marca leída por su cuenta: que tú la leas no la
marca para los demás. Una de proyecto no se puede borrar desde la app —la
notificación es una sola y es de todos—, se marca leída y ya.

### Lo que ya estaba ahí

El stream **no** trae lo anterior, solo lo que llegue a partir de ahora. Para
pintar la lista al abrir:

```dart
final lista = await db.notifications.list();              // las 50 últimas
final sinLeer = await db.notifications.list(unread: true);
final cuantas = await db.notifications.unreadCount();     // el número del globito
```

`list()` acepta `topic`, `limit` (1-100) y `before` para ir hacia atrás.

### Marcarlas

```dart
await db.notifications.markRead(notificacion.id);
await db.notifications.markAllRead();
await db.notifications.remove(notificacion.id); // solo las dirigidas a ti
```

Marcar una vuelve por el stream como un evento `read`, y solo a **tus**
dispositivos: el teléfono se entera de lo que marcaste en el navegador.

### El globito, sin pedirlo

Al conectar, el servidor ya manda cuántas hay sin leer:

```dart
db.notifications.unreadCountChanges.listen((n) => setState(() => badge = n));
```

### Ojo

Cualquiera con sesión en el proyecto puede enviar a cualquiera, igual que
cualquiera puede escribir en cualquier rama del árbol JSON. Si el aviso lo tiene
que mandar solo el profesor, esa comprobación va en tu código.

---

## Cuando algo falla

Todo lanza alguna subclase de `RobleApiException`:

```dart
try {
  await db.login(email: correo, password: clave);
} on RobleApiHttpException catch (e) {
  if (e.statusCode == 401) mostrar('Correo o contraseña incorrectos');
} on RobleApiNetworkException {
  mostrar('Sin conexión');
} on RobleApiException catch (e) {
  mostrar(e.message);
}
```

| Excepción | Qué pasó |
|---|---|
| `RobleApiHttpException` | El servidor respondió con error. Mira `statusCode` |
| `RobleApiNetworkException` | No se pudo llegar al servidor |
| `RobleApiTimeoutException` | Tardó demasiado |
| `RobleApiAuthException` | Problema de sesión o de login social |
| `RobleApiFormatException` | La respuesta no tenía la forma esperada |
| `RobleApiConflictException` | Ya existe una cuenta con ese correo |

Los números que más vas a ver:

- **401** — no hay sesión, o las credenciales están mal.
- **403** — la tabla no es pública (en `publicRead`).
- **404** — no existe esa consulta guardada.

---

## Referencia rápida

Todos los métodos son asíncronos salvo `isLoggedIn` e `isSocialCallback`.

### Sesión

| Método | Devuelve |
|---|---|
| `isLoggedIn` | `bool` — si hay sesión en memoria |
| `restoreSession()` | `bool` — `true` si la sesión guardada sigue viva |
| `logout()` | nada |

### Cuentas

| Método | Devuelve |
|---|---|
| `register()` | el usuario creado, tal como lo mandó el servidor |
| `registerWithVerification()` | confirmación de que el correo salió |
| `verifyEmail()` | confirmación |
| `resendCode()` | confirmación |
| `login()` | **el perfil** (arriba) |
| `currentUser()` | **el perfil** |
| `forgotPassword()` | confirmación de que el correo salió |
| `resetPassword()` | confirmación |
| `deleteAccount()` | nada |

### Login social

| Método | Devuelve |
|---|---|
| `signInWithGoogle()` | **el perfil** |
| `signInWithProvider()` | **el perfil** |
| `signInWithIdToken()` | **el perfil** |
| `exchangeSocialCode()` | **el perfil** |
| `listProviders()` | `List<RobleProviderInfo>` — `name`, `displayName`, `clientId`, `autoLinkSupported` |
| `providerClientId()` | `String?` — `null` si ese proveedor no está configurado |
| `startSocialLogin()` | `Uri` — a dónde mandar a la persona |
| `isSocialCallback()` | `bool` |
| `RobleApiDataBase.newNonce()` | `String` |

### Tablas

| Método | Devuelve |
|---|---|
| `create()` | el registro creado, **con su `_id`** |
| `createMany()` | `RobleInsertResult` — `inserted` y `skipped` |
| `read()` | `List<Map>` — vacía si no hay nada, nunca `null` |
| `getById()` | `Map?` — **`null` si no existe** |
| `update()` | el registro ya cambiado |
| `delete()` | confirmación del borrado |
| `publicRead()` | `List<Map>` — sin necesidad de sesión |
| `executeQuery()` | `RobleQueryResult` — `rows`, `rowCount`, `fields` |
| `executeQueryByName()` | `RobleQueryResult` |

### Árbol JSON

| Método | Devuelve |
|---|---|
| `json.collections()` | `List<String>` — los nombres |
| `json.read()` | lo que haya en esa ruta, o `null` si no existe |
| `json.write()` | nada |
| `json.update()` | nada |
| `json.push()` | `String` — **la clave que generó el servidor** |
| `json.remove()` | nada |
| `json.watch()` | `Stream<RobleChange>` |

### Tiempo real

| Método | Devuelve |
|---|---|
| `watchTable()` | `Stream<RobleChange>` |
| `watchRecord()` | `Stream<RobleChange>` |
| `realtimePolicies()` | `List<RobleTablePolicy>` |
| `realtimePolicy()` | `RobleTablePolicy?` — `null` si esa tabla no tiene política |
| `setRealtimePolicy()` | la política ya guardada |
| `disableRealtime()` | nada |

Un `RobleChange` trae `type` (`insert`, `update`, `delete`), `table`,
`record` (la fila después del cambio, `null` al borrar), `previous`,
`primaryKey`, `id`, `commitTimestamp` y `path` (solo en el árbol JSON).

---

### Notificaciones

| Método | Devuelve |
|---|---|
| `notifications.send()` | las notificaciones creadas, una por destinatario |
| `notifications.list()` | `List<RobleNotification>`, de la más reciente a la más antigua |
| `notifications.unreadCount()` | `int` |
| `notifications.markRead()` | la notificación ya marcada |
| `notifications.markAllRead()` | `int` — cuántas cambiaron |
| `notifications.remove()` | nada |
| `notifications.watch()` | `Stream<RobleNotificationEvent>` |
| `notifications.unreadCountChanges` | `Stream<int>` |

Una `RobleNotification` trae `id`, `title`, `body`, `topic`, `data`,
`recipientId` (`*` si es de proyecto, o `isForEveryone`), `senderId`, `readAt`
(o `isUnread`), `createdAt` y `expiresAt`.

---

## Licencia

MIT
