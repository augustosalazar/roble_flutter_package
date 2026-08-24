# 📦 roble

Cliente Flutter para la plataforma [ROBLE](https://roble.openlab.uninorte.edu.co/) de Uninorte OpenLab: autenticación y CRUD sobre PostgreSQL.

https://github.com/augustosalazar/roble_api_database

> 🔁 Existe un equivalente en JavaScript/TypeScript, [`roble-client`](https://github.com/augustosalazar/roble-api-database-ReNa), con los mismos métodos y las mismas excepciones.

## 🚀 Instalación

```bash
flutter pub add roble
```

```dart
import 'package:roble/roble.dart';
```

---

## 🧭 Quick start

```dart
final db = RobleApiDataBase(
	config: RobleApiConfig.fromContract(
		baseUrl: 'https://roble-api.test-openlab.uninorte.edu.co',
		contractId: 'tu_contrato',
	),
);

// 1. Registro
await db.register(
	email: 'ana@correo.com',
	password: 'MiClave!1',
	name: 'Ana García',
	extra: {'programa': 'Sistemas'},
);

// 2. Login: devuelve el perfil
final user = await db.login(email: 'ana@correo.com', password: 'MiClave!1');
print('Hola ${user['name']} (${user['userId']})');

// 3. CRUD
final creado = await db.create('usuarios', {'nombre': 'Ana', 'edad': 28});
final todos = await db.read('usuarios');
await db.update('usuarios', creado['_id'], {'edad': 29});
await db.delete('usuarios', creado['_id']);

// 4. Cerrar sesión
await db.logout();
```

Todos los métodos son asíncronos y lanzan alguna subclase de `RobleApiException`. Ver [Manejo de errores](#-manejo-de-errores).

---

## ⚙️ Configuración

`RobleApiConfig` es inmutable. Lo habitual es componerla desde el host y el identificador del contrato:

```dart
final config = RobleApiConfig.fromContract(
	baseUrl: 'https://roble-api.test-openlab.uninorte.edu.co',
	contractId: 'tu_contrato',
	timeout: Duration(seconds: 30),
);
```

| Parámetro | Tipo | Obligatorio | Descripción |
| --- | --- | --- | --- |
| `baseUrl` | `String` | sí | Host de la API. Una barra final se ignora. |
| `contractId` | `String` | sí | Identificador del contrato, con el que se componen las rutas de auth y de datos. |
| `timeout` | `Duration` | no | Tiempo máximo por petición. Por defecto 30 s. |

`Content-Type: application/json` y `Authorization: Bearer …` los gestiona el cliente; no hay que declararlos.

`fromContract` es la única forma de crear la configuración: las URLs se componen siempre a partir del host y del contrato.

### Constructor del cliente

```dart
RobleApiDataBase({
	required RobleApiConfig config,
	http.Client? client,          // solo para tests
	RobleTokenStorage? storage,   // solo para tests
})
```

Los tokens **no se exponen**. El paquete los guarda en el almacén seguro del sistema, los adjunta a cada petición, los renueva ante un `401` y los borra al cerrar sesión. Lo único que se consulta desde fuera es `db.isLoggedIn`.

---

## 🔐 Sesión

### `bool get isLoggedIn`

`true` si este cliente tiene una sesión iniciada. No consulta al servidor.

```dart
if (db.isLoggedIn) mostrarPerfil();
```

### `Future<bool> restoreSession({bool verify = true})`

Restaura la sesión guardada y **comprueba contra el servidor que siga viva**. Llámalo al arrancar la app.

| Parámetro | Tipo | Por defecto | Descripción |
| --- | --- | --- | --- |
| `verify` | `bool` | `true` | Si es `true`, renueva el access token contra el servidor. Con `false` solo lee el almacenamiento (más rápido, pero la sesión puede estar caducada). |

**Devuelve** `true` si la sesión sirve; `false` si no había sesión guardada o el refresh token ya no vale (en ese caso limpia la sesión).

**Errores**

| Excepción | Cuándo |
| --- | --- |
| `RobleApiNetworkException` | Sin conexión. **No borra la sesión**: distínguelo de "sesión caducada" y reintenta. |
| `RobleApiTimeoutException` | El servidor no respondió a tiempo. Tampoco borra la sesión. |

```dart
try {
	if (await db.restoreSession()) {
		irAlInicio();
	} else {
		irAlLogin();
	}
} on RobleApiNetworkException {
	mostrarPantallaSinConexion();
}
```

### Persistencia entre reinicios

**No hay que configurar nada.** El paquete guarda la sesión en el almacén seguro del sistema (Keychain en iOS/macOS, Keystore en Android, almacenamiento cifrado en web, gestor de secretos en escritorio) mediante `flutter_secure_storage`. El refresh token es la credencial de larga duración, así que no va a `SharedPreferences`.

El ciclo completo es:

```dart
final db = RobleApiDataBase(config: config);   // sin storage

await db.login(email: …, password: …);          // se guarda sola
// … la app se cierra y se vuelve a abrir …
await db.restoreSession();                      // vuelve la sesión
await db.logout();                              // se borra
```

En pruebas puedes sustituirlo por `RobleMemoryStorage`, que guarda en un `Map`:

```dart
final db = RobleApiDataBase(config: config, storage: RobleMemoryStorage());
```

Si el almacén no está disponible (por ejemplo en un test de Dart puro, sin plataforma), las operaciones fallan en silencio: la sesión sigue viva en memoria pero no se persiste.

---

## 🔑 Autenticación

### `register`

```dart
Future<Map<String, dynamic>> register({
	required String email,
	required String password,
	required String name,
	Map<String, dynamic>? extra,
	bool autoLogin = false,
	bool persistSession = true,
})
```

Registra un usuario **sin verificación por correo**. La cuenta queda activa de inmediato. `POST /signup-direct`.

| Parámetro | Tipo | Por defecto | Descripción |
| --- | --- | --- | --- |
| `email` | `String` | — | Correo del usuario. |
| `password` | `String` | — | Mínimo 8 caracteres, con mayúscula, minúscula, número y un símbolo de `! @ # $ _ - .` |
| `name` | `String` | — | Nombre visible. |
| `extra` | `Map<String, dynamic>?` | `null` | Campos adicionales que el backend guarda con el usuario y devuelve en `login` y `currentUser`. |
| `autoLogin` | `bool` | `false` | Si es `true`, inicia sesión al terminar el registro. |
| `persistSession` | `bool` | `true` | Solo se aplica con `autoLogin: true`. Igual que en [`login`](#login). |

**Devuelve** depende de `autoLogin`:

| `autoLogin` | Devuelve |
| --- | --- |
| `false` | El mensaje del servidor: `{'message': 'Usuario registrado correctamente.'}` |
| `true` | El perfil del usuario, lo mismo que [`login`](#login) |

Si el registro funciona pero el login automático falla, **la cuenta ya está creada**: el error se propaga y `db.isLoggedIn` sigue en `false`, así que basta con reintentar `login()` sin volver a registrar.

> `registerWithVerification` no tiene `autoLogin`: hasta validar el código del correo la cuenta no puede iniciar sesión.

**Errores**

| Excepción | Mensaje típico |
| --- | --- |
| `RobleApiHttpException` (400) | `El email ya está registrado` · contraseña que no cumple las reglas |
| `RobleApiHttpException` (500) | `Error interno al registrar el usuario.` |

```dart
// Registro y a la pantalla principal en un solo paso
final user = await db.register(
	email: 'ana@correo.com',
	password: 'MiClave!1',
	name: 'Ana García',
	extra: {'rol': 'estudiante', 'programa': 'Sistemas'},
	autoLogin: true,
);
print(user['userId']);
```

### `registerWithVerification`

Misma firma que [`register`], pero envía un código de 6 dígitos por correo. `POST /signup`. El usuario no queda activo hasta llamar a `verifyEmail`.

```dart
await db.registerWithVerification(
	email: 'ana@correo.com',
	password: 'MiClave!1',
	name: 'Ana García',
);
```

### `verifyEmail`

```dart
Future<Map<String, dynamic>> verifyEmail({
	required String email,
	required String code,
})
```

Confirma el correo con el código recibido. `POST /verify-email`.

**Errores**: `RobleApiHttpException` (400) si el código es inválido o expiró.

```dart
await db.verifyEmail(email: 'ana@correo.com', code: '123456');
```

### `resendCode`

```dart
Future<Map<String, dynamic>> resendCode({required String email})
```

Reenvía el código de verificación. `POST /resend-code`.

### `login`

```dart
Future<Map<String, dynamic>> login({
	required String email,
	required String password,
	bool persistSession = true,
})
```

Inicia sesión y **devuelve el perfil del usuario**. Hace `POST /login` y, con el token ya guardado, `GET /me`.

| Parámetro | Tipo | Por defecto | Descripción |
| --- | --- | --- | --- |
| `email` | `String` | — | Correo. |
| `password` | `String` | — | Contraseña. |
| `persistSession` | `bool` | `true` | Si la sesión debe sobrevivir al cierre de la app. Es el clásico "recordarme". |

Con `persistSession: false` la sesión vive **solo en memoria**: todo funciona igual mientras la app esté abierta, pero al reiniciar habrá que volver a entrar. Además **borra cualquier sesión guardada antes**, para que no quede una sesión anterior recuperable en el dispositivo.

```dart
await db.login(
	email: email,
	password: password,
	persistSession: recordarme, // p. ej. el valor de un checkbox
);
```

**Devuelve**

| Campo | Tipo | Descripción |
| --- | --- | --- |
| `userId` | `String` | Id del usuario. Es con lo que se comparan campos como `autorId`. |
| `email` | `String` | Correo. |
| `name` | `String` | Nombre. |
| `extra` | `Map?` | Lo enviado en `register`, o `null`. |
| `id` | `String` | Id del registro de perfil. |
| `createdAt` / `updatedAt` | `String` | Fechas ISO-8601. |

**Errores**

| Excepción | Cuándo |
| --- | --- |
| `RobleApiHttpException` (401) | Credenciales incorrectas. |
| `RobleApiNetworkException` | Sin conexión. |

Si `POST /login` funciona pero `GET /me` falla, **la sesión queda activa** y la excepción se propaga. `db.isLoggedIn` distingue los dos casos:

```dart
try {
	final user = await db.login(email: email, password: password);
	irAlInicio(user);
} catch (e) {
	if (db.isLoggedIn) {
		irAlInicio(await db.currentUser()); // credenciales OK, falló el perfil
	} else {
		mostrarError('Correo o contraseña incorrectos');
	}
}
```

### `currentUser`

```dart
Future<Map<String, dynamic>> currentUser()
```

Perfil del usuario autenticado. `GET /me`. Mismo mapa que devuelve `login`.

**Errores**: `RobleApiHttpException` (401) si no hay sesión válida.

### `logout`

```dart
Future<void> logout()
```

Cierra la sesión en el servidor y borra los tokens locales y del almacenamiento. `POST /logout`.

**Errores**: `RobleApiAuthException` — `No hay token activo para cerrar sesión.`

### `forgotPassword`

```dart
Future<Map<String, dynamic>> forgotPassword({required String email})
```

Envía el correo de restablecimiento. `POST /forgot-password`.

**Errores**: `RobleApiHttpException` (400) si el correo no está registrado.

### `resetPassword`

```dart
Future<Map<String, dynamic>> resetPassword({
	required String token,
	required String newPassword,
})
```

Restablece la contraseña con el token que llega en el enlace del correo. `POST /reset-password`.

**Errores**: `RobleApiHttpException` (400) si el token es inválido o expiró.

### `deleteAccount`

```dart
Future<void> deleteAccount()
```

Elimina la cuenta autenticada de forma permanente y limpia la sesión. `DELETE /account`. **No se puede deshacer**: pide confirmación antes de llamarla.

**Errores**: `RobleApiAuthException` — `No hay sesión activa para eliminar la cuenta.`

---

## 🌐 Inicio de sesión con Google y Microsoft

En Roble el login social **también es registro**: un correo nuevo crea un usuario ya verificado, uno existente enlaza la identidad del proveedor con ese usuario, y a partir de ahí simplemente entra. Google y Microsoft pueden enlazar al mismo usuario si comparten correo. Por eso no hay un `signUpWithGoogle` aparte.

El flujo tiene tres pasos, y el de en medio **no lo hace el paquete**:

1. `socialLoginUrl()` te da la URL de arranque.
2. **Tu app navega a esa URL** y el usuario se autentica en el proveedor. Roble lo devuelve al `doneUrl` del proyecto con `?code=…&provider=…`.
3. `completeSocialLogin()` canjea ese código y deja la sesión iniciada.

El paso 2 requiere un navegador, no una petición HTTP. El paquete no lo hace por ti para no imponerte una dependencia de `url_launcher` a cambio de cuatro líneas que además cambian según la plataforma.

> **Configura al menos un destino de retorno en la consola de Roble.** Roble ya no deduce a dónde volver a partir de la cabecera `Origin`: resuelve la URL contra una lista de destinos con nombre que se define por proyecto. Sin ninguno configurado el flujo **no arranca**, ni siquiera para probar.
>
> Da de alta uno llamado `default` —el que se usa cuando no se pide otro— y tantos como entornos necesites: `web`, `movil`, `dev`. En móvil y escritorio apunta a un esquema propio, `miapp://sso-done`.
>
> | Situación | Respuesta de Roble |
> | --- | --- |
> | Ningún destino y sin `redirect` | `400 Configura un destino de retorno llamado default o indica ?redirect=nombre al iniciar sesión.` |
> | `redirect` con un nombre no dado de alta | `400 El destino de retorno solicitado no está autorizado para este proyecto.` |

### `socialConfig`

```dart
Future<RobleSocialConfig> socialConfig(RobleSocialProvider provider)
```

Consulta si un proveedor está disponible en el proyecto. `GET /{provider}-config`. Es público: no necesita sesión.

Sirve para no pintar un botón que va a fallar — arrancar el flujo con un proveedor apagado responde `403`.

Devuelve `RobleSocialConfig` con `enabled`, `clientId` y `tenantId` (este último solo en Microsoft; en Google siempre es `null`).

```dart
final google = await db.socialConfig(RobleSocialProvider.google);
if (google.enabled) mostrarBotonGoogle();
```

### `signInWithProvider`

```dart
Future<Map<String, dynamic>> signInWithProvider(
  RobleSocialProvider provider, {
  Map<String, dynamic>? extra,
  bool persistSession = true,
  Duration timeout = const Duration(minutes: 5),
})
```

El camino corto: abre el proveedor en una ventana, espera el retorno, canjea el
código y devuelve el perfil — **la misma forma que `login`**. La app principal
nunca se descarga, así que no hay que tocar la URL de arranque ni el enrutado.

```dart
FilledButton(
  onPressed: () async {
    final user = await db.signInWithProvider(RobleSocialProvider.google);
  },
  child: const Text('Entrar con Google'),
)
```

**Llámalo directamente desde el gesto del usuario.** Si haces cualquier `await`
antes, el navegador considera que la ventana no la pidió nadie, la bloquea, y
esto lanza `RobleApiAuthException` diciéndolo.

#### Fuera de web: `opener`

La ventana emergente solo existe en web. En móvil y escritorio le pasas tú cómo
se abre el proveedor, con un `RobleSocialOpener`: una función que recibe la URL
de arranque y devuelve la URL de retorno.

```dart
final db = RobleApiDataBase(
  config: …,
  socialOpener: (loginUrl, timeout) async => Uri.parse(
    await FlutterWebAuth2.authenticate(
      url: loginUrl.toString(),
      callbackUrlScheme: 'miapp',
    ),
  ),
);
```

Se fija una vez al crear el cliente, como `ssoRedirect`, y `signInWithProvider`
acepta un `opener` por llamada que lo sustituye. Sin ninguno de los dos y fuera
de web, lanza `RobleApiAuthException` diciéndolo.

Es deliberado que el paquete no elija el plugin: así `roble` no arrastra código
nativo a quien nunca toca el login social, y tú usas el que prefieras —
`flutter_web_auth_2`, un listener de deep links, lo que sea— sin esperar a que
la librería lo bendiga. Recuerda que ese camino necesita además el esquema
propio registrado en `AndroidManifest.xml` e `Info.plist`, y dado de alta como
destino de retorno en la consola.

#### Lo que hay que añadir a `web/index.html`

La ventana vuelve al destino de retorno, que debe devolver la URL a quien la
abrió. Pega esto dentro del `<head>`, **antes** del script de Flutter:

```html
<script>
  (function () {
    var params = new URLSearchParams(window.location.search);
    if (!params.get('code') || !window.opener) return;
    window.opener.postMessage('roble-sso:' + window.location.href,
      window.location.origin);
    window.close();
  })();
</script>
```

Al salir temprano cuando no hay `code`, un arranque normal de la app no se
entera de nada. Y como se ejecuta antes que Flutter, la ventana se cierra sin
llegar a cargar la app entera.

El destino de retorno configurado en la consola debe apuntar a esa misma
página, y estar en **el mismo origen** que la app: el mensaje se rechaza si
viene de otro, que es lo que impide que una página cualquiera se invente un
inicio de sesión.

**Errores**: `RobleApiAuthException` si la ventana se bloquea, si el usuario la
cierra antes de terminar, o si se agota `timeout`. Lo que falle en el canje sale
tal cual de `completeSocialLogin`.

### `socialLoginUrl`

```dart
Uri socialLoginUrl(
  RobleSocialProvider provider, {
  Map<String, dynamic>? extra,
  String? redirect,
})
```

Construye la URL de arranque. **No hace ninguna petición**: hay que navegar a ella.

| Parámetro | Descripción |
| --- | --- |
| `provider` | `RobleSocialProvider.google` o `.microsoft`. |
| `extra` | Campos adicionales que se guardan en el perfil del usuario. Los existentes se conservan; los que coincidan se sobrescriben. |
| `redirect` | Nombre del destino de retorno al que debe volver el usuario. Si se omite, Roble usa el llamado `default`. |

`redirect` es lo que permite que la app web, la de móvil y tu entorno de desarrollo compartan proyecto y vuelva cada una a su sitio:

```dart
// La misma app, dos entornos.
db.socialLoginUrl(RobleSocialProvider.google, redirect: 'dev');
db.socialLoginUrl(RobleSocialProvider.google, redirect: 'produccion');
```

```dart
final url = db.socialLoginUrl(
  RobleSocialProvider.google,
  extra: {'departamento': 'ingenieria', 'codigo': 12345},
);
await launchUrl(url, mode: LaunchMode.externalApplication);
```

`extra` **viaja en la URL**, así que no pongas nada secreto ahí — queda en el historial del navegador y en los logs del servidor.

**Errores** — todos `ArgumentError`, lanzados en el acto y no tras el `400` del servidor a mitad del flujo:

| Causa | Mensaje |
| --- | --- |
| `redirect` vacío o solo espacios | `No puede estar vacío. Es el nombre de un destino de retorno configurado en la consola de Roble; omítelo para usar "default"` |
| Clave reservada por Roble, a cualquier nivel de anidamiento | `Roble reserva la clave "isAdmin" (en perfil.datos); elige otro nombre` |
| Más de 4 KB serializado | `Ocupa 5013 bytes serializado y el máximo son 4096` |
| Valor no convertible a JSON | `No se puede convertir a JSON: …` |

Las claves reservadas son `role`, `roleId`, `permissions`, `isAdmin`, `isVerified`, `isSSO`, `userId`, `user_id`, `constructor`, `prototype` y `__proto__`.

### `completeSocialLogin`

```dart
Future<Map<String, dynamic>> completeSocialLogin(
  Uri callbackUrl, {
  bool persistSession = true,
})
```

Termina el inicio de sesión a partir de la URL de retorno. Lee `code` y `provider`, canja el código contra `POST /auth/{provider}/exchange`, guarda la sesión y devuelve el perfil — **la misma forma que `login`**, porque termina pidiendo `/me`.

`persistSession` hace lo mismo que en `login`.

```dart
// Flutter web: al arrancar la app.
if (Uri.base.queryParameters.containsKey('code')) {
  final user = await db.completeSocialLogin(Uri.base);
  print('Hola ${user['name']}');
}
```

**El código dura 60 segundos y es de un solo uso.** Es lo primero que hay que mirar cuando el flujo falla en pruebas: recargar la página de retorno lo reutiliza y falla.

**Errores**:

| Excepción | Cuándo |
| --- | --- |
| `RobleApiAuthException` | La URL no trae `code`, o `provider` falta o no es `google`/`microsoft`. |
| `RobleApiHttpException` `400` | `Código inválido o expirado` — reusado o pasados los 60 s. Hay que rehacer el flujo desde `socialLoginUrl`. |
| `RobleApiFormatException` | El intercambio no devolvió un access token. |

### Vidas útiles

| | |
| --- | --- |
| Código de intercambio | 60 segundos, un solo uso |
| `state` de OAuth | 5 minutos |
| Access token | 15 minutos |
| Refresh token | 7 días |

El paquete renueva el access token solo, igual que con el login normal.

---

## ✨ Login social v2

Los métodos de arriba siguen funcionando igual. Estos hablan con los endpoints
genéricos del servidor, que están detrás de `AUTH_V2_PROVIDERS`: con la bandera
apagada responden `400`.

### `signInWithIdToken`

El camino corto en una app: el SDK nativo da el `idToken` y aquí se acaba. Sin
navegador, sin ventana emergente, sin esquema de URL personalizado y sin retorno
que enrutar. Es el equivalente de `signInWithIdToken` de Supabase.

```dart
final cuenta = await GoogleSignIn().signIn();
final auth = await cuenta!.authentication;

final user = await db.signInWithIdToken(
  provider: 'google',
  idToken: auth.idToken!,
);
```

`nonce` es el que se le pidió al SDK nativo. Mándalo si lo usaste: el servidor
comprueba que coincida, y eso es lo que impide reutilizar un `id_token`
capturado.

Solo vale para proveedores OIDC —Google y Microsoft—. GitHub es OAuth2 y no
emite `id_token`, así que responde `400`.

### `listProviders`

Una llamada devuelve todos los proveedores activos, así que añadir uno en el
servidor no obliga a publicar una versión nueva de la app.

```dart
for (final p in await db.listProviders()) {
  botones.add(BotonSocial(p.displayName, () => db.startSocialLogin(p.name)));
}
```

`autoLinkSupported` dice si ese proveedor puede vincularse solo con una cuenta
que ya existe. Cuando es `false`, conviene avisarlo en la interfaz **antes** de
que el usuario pulse, no después del `409`.

### `startSocialLogin` + `exchangeSocialCode`

El flujo de navegador, con PKCE. `startSocialLogin` es asíncrono porque el
servidor crea el flujo antes de decir a dónde ir.

```dart
final url = await db.startSocialLogin('google');
await launchUrl(url, mode: LaunchMode.externalApplication);

// Al volver, con el code de la URL de retorno:
final user = await db.exchangeSocialCode(code);
```

Frente a `socialLoginUrl`: el código interceptado no sirve sin el verifier, que
nunca sale del proceso —en móvil importa, porque otra app puede registrar el
mismo esquema de URL—, y `extra` viaja en el cuerpo, así que deja de aparecer en
los logs de acceso, en los del proxy y en el historial.

### Cuentas que ya existen

Si el proveedor no certifica que el correo esté verificado y ese correo ya tiene
cuenta, Roble responde `409` y lanza `RobleApiConflictException`. Le pasa sobre
todo a Microsoft, porque la mayoría de registros de Entra de un solo tenant no
emiten `email_verified`.

```dart
try {
  await db.signInWithIdToken(provider: 'microsoft', idToken: t);
} on RobleApiConflictException catch (e) {
  mostrar(e.message); // entra con tu método actual y vincula desde ajustes
}
```

No se arregla reintentando: es deliberado, porque sin esa prueba quien controle
un tenant del proveedor podría fijar el correo de otra persona y heredar su
cuenta.

---

## 🗄️ Datos

### `create`

```dart
Future<Map<String, dynamic>> create(String tableName, Map<String, dynamic> data)
```

Inserta un registro y devuelve la fila creada, con su `_id`. `POST /insert-one`.

**Errores**: `RobleApiHttpException` (400) `Columnas inválidas: …` si algún campo no existe en la tabla; (500) si la tabla no existe.

```dart
final creado = await db.create('usuarios', {'nombre': 'Ana', 'edad': 28});
print(creado['_id']);
```

### `createMany`

```dart
Future<RobleInsertResult> createMany(
	String tableName,
	List<Map<String, dynamic>> records, {
	bool strict = false,
})
```

Inserta varios registros. `POST /insert`.

**Devuelve** `RobleInsertResult`:

| Campo | Tipo | Descripción |
| --- | --- | --- |
| `inserted` | `List<Map<String, dynamic>>` | Filas insertadas, con su `_id`. |
| `skipped` | `List<RobleSkippedRecord>` | Rechazadas: `index` y `reason`. |
| `hasSkipped` | `bool` | `true` si hubo rechazos. |

> ⚠️ El servidor responde `200` aunque rechace registros. **Revisa siempre `skipped`**, o usa `strict: true` para que no se te olvide.

Con `strict: true` un rechazo parcial deja de ser algo que haya que recordar mirar y pasa a ser un error:

```dart
try {
	await db.createMany('usuarios', registros, strict: true);
} on RoblePartialInsertException catch (e) {
	// e.result.inserted -> lo que SÍ se escribió (útil para deshacer)
	// e.result.skipped  -> qué se rechazó y por qué
	print(e.message);
}
```

Sin `strict` hay que comprobarlo a mano:

```dart
final res = await db.createMany('usuarios', registros);
if (res.hasSkipped) {
	for (final s in res.skipped) {
		print('Fila ${s.index} rechazada: ${s.reason}');
	}
}
```

### `read`

```dart
Future<List<Map<String, dynamic>>> read(
	String tableName, {
	Map<String, dynamic>? filters,
})
```

Lee registros. `GET /read`. Cada entrada de `filters` viaja como query param y **solo admite igualdad**: no hay `LIKE`, rangos, orden ni paginación. Para eso está [`executeQuery`](#executequery).

```dart
final admins = await db.read('usuarios', filters: {'rol': 'admin'});
```

**Errores**: `RobleApiHttpException` (400) si la tabla o una columna no existen.

### `update`

```dart
Future<Map<String, dynamic>> update(
	String tableName,
	dynamic id,
	Map<String, dynamic> data,
)
```

Actualiza el registro cuyo `_id` coincida. `PUT /update`. Las claves `_id` e `id` se eliminan del cuerpo automáticamente.

**Errores**: `RobleApiHttpException` (404) si el registro no existe.

### `delete`

```dart
Future<Map<String, dynamic>> delete(String tableName, dynamic id)
```

Elimina el registro cuyo `_id` coincida. `DELETE /delete`.

### `publicRead`

```dart
Future<List<Map<String, dynamic>>> publicRead(
	String tableName, {
	Map<String, dynamic>? filters,
})
```

Lee una tabla marcada como pública, **sin autenticación**. `GET /public-read`.

**Errores**: `RobleApiHttpException` (403) — `Esta tabla no está configurada para acceso público`. Es configuración de la tabla en la consola, no un problema de token.

### `executeQuery`

```dart
Future<RobleQueryResult> executeQuery(String id, {List<dynamic>? params})
```

Ejecuta una consulta guardada en la consola de Roble. `POST /execute-query`. Es la vía para joins, agregados, orden y paginación.

**Devuelve** `RobleQueryResult` con `success`, `command`, `rowCount`, `rows` y `fields`.

```dart
final res = await db.executeQuery(
	'ca7fe9c1-e740-4e50-82ba-bec89a0eec98',
	params: ['activo'],
);
print('${res.rowCount} filas');
```

### `executeQueryByName`

```dart
Future<RobleQueryResult> executeQueryByName(String name, {List<dynamic>? params})
```

Lo mismo que `executeQuery`, pero identificando la consulta por su **nombre**. `POST /saved-queries/by-name/{name}/execute`.

Es la forma preferible en código que se mantiene: el nombre lo eliges tú y sigue siendo el mismo si borras y recreas la consulta, mientras que el UUID cambia y deja el código apuntando a algo que ya no existe.

| Parámetro | Descripción |
| --- | --- |
| `name` | Nombre de la consulta en la consola. Se escapa solo, así que puede llevar espacios y acentos. |
| `params` | Parámetros posicionales de la consulta. |

**Devuelve** el mismo `RobleQueryResult` que `executeQuery`.

```dart
final res = await db.executeQueryByName('ranking_mensual', params: [2026]);
for (final fila in res.rows) print(fila);
```

**Errores**:

| Excepción | Cuándo |
| --- | --- |
| `ArgumentError` | `name` vacío o solo espacios. |
| `RobleApiHttpException` | El servidor no encuentra la consulta con ese nombre. |

---

## ❌ Manejo de errores

Todo lo que lanza el paquete hereda de `RobleApiException`, así que puedes capturar el tipo concreto:

| Excepción | Cuándo | Mensaje |
| --- | --- | --- |
| `RobleApiNetworkException` | Sin red o DNS no resuelto | `Sin conexión a internet` |
| `RobleApiTimeoutException` | Se supera `config.timeout` | `Tiempo de espera agotado` |
| `RobleApiFormatException` | Respuesta con forma inesperada | `Respuesta con formato inválido` · `No se pudo insertar el registro` · `El servidor no devolvió el ID generado.` |
| `RobleApiHttpException` | Código fuera de 2xx | El `message` del servidor. Expone además `statusCode`. |
| `RobleApiAuthException` | Problemas de sesión | `Token expirado y no se pudo refrescar: …` · `No hay token activo para cerrar sesión.` · `No hay refresh token disponible.` |
| `RoblePartialInsertException` | `createMany(strict: true)` con filas rechazadas | `El servidor rechazó 1 de 3 registros: fila 2 (…)`. Expone `result`. |
| `RobleApiException` | Cualquier otro | `Error inesperado: …` |

`RobleApiConfig.fromContract` lanza `ArgumentError` (no `RobleApiException`) si `baseUrl` no es una URL o si el `contractId` está vacío o sigue siendo un valor de ejemplo: es un fallo de programación, no del servidor.

Además, un `500` en autenticación es lo que devuelve Roble cuando **el contrato no existe**, así que a ese mensaje se le añade una pista:

```
Error inesperado al autenticar — revisa que el contractId sea correcto (mi_contrato_mal)
```

```dart
try {
	final usuarios = await db.read('usuarios');
} on RobleApiHttpException catch (e) {
	debugPrint('El servidor respondió ${e.statusCode}: ${e.message}');
} on RobleApiAuthException {
	irAlLogin();
} on RobleApiNetworkException {
	mostrarPantallaSinConexion();
} on RobleApiException catch (e) {
	debugPrint(e.message);
}
```

Captura siempre `RobleApiException` al final: es la clase base de todas.

**Refresco automático.** Si una petición de datos responde `401` y hay refresh token, el cliente renueva el access token y reintenta **una sola vez**. Es interno: no hay método público para refrescar a mano.

---

## 🧪 Testing

El constructor acepta un `http.Client` inyectado, así que se puede probar sin red:

```dart
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

final db = RobleApiDataBase(
	config: RobleApiConfig.fromContract(
		baseUrl: 'https://fake.test',
		contractId: 'proj',
	),
	storage: RobleMemoryStorage(), // evita tocar el almacén del sistema
	client: MockClient((request) async {
		return http.Response('[{"_id":"1","nombre":"Ana"}]', 200);
	}),
);

final usuarios = await db.read('usuarios');
```

---

## 📱 Ejemplo completo

[`example/`](example/) es una app Flutter que ejercita registro con `autoLogin`, login con "recordarme", restauración de sesión al arrancar, `currentUser`, el CRUD completo e inserción múltiple con registros rechazados, con un log de cada operación.

```bash
cd example
flutter run
```

---

## 👥 Autoría

Creado originalmente por [Arias3](https://github.com/Arias3).
Mantenido actualmente por **Augusto Salazar**
(<augustosalazar@uninorte.edu.co>), Universidad del Norte, como líder de
desarrollo.

---

## 🛠️ Contribuciones

Las contribuciones son bienvenidas. Abre un issue si encuentras un bug o quieres proponer una mejora.
