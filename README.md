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

**Sesión** · `isLoggedIn` · `restoreSession()` · `logout()`

**Cuentas** · `register()` · `registerWithVerification()` · `verifyEmail()` ·
`resendCode()` · `login()` · `currentUser()` · `forgotPassword()` ·
`resetPassword()` · `deleteAccount()`

**Login social** · `signInWithGoogle()` · `signInWithProvider()` ·
`signInWithIdToken()` · `listProviders()` · `providerClientId()` ·
`startSocialLogin()` · `exchangeSocialCode()` · `isSocialCallback()`

**Tablas** · `create()` · `createMany()` · `read()` · `getById()` · `update()` ·
`delete()` · `publicRead()` · `executeQuery()` · `executeQueryByName()`

**Árbol JSON** · `json.collections()` · `json.read()` · `json.write()` ·
`json.update()` · `json.push()` · `json.remove()` · `json.watch()`

**Tiempo real** · `watchTable()` · `watchRecord()` · `realtimePolicies()` ·
`realtimePolicy()` · `setRealtimePolicy()` · `disableRealtime()`

---

## Licencia

MIT
