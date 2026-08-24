# Changelog

## 1.4.0

### Añadido

- **`signInWithProvider(provider)`: login social en una sola llamada.** Abre el
  proveedor en una ventana emergente, espera el retorno y devuelve el perfil,
  igual que `login`. Como la app no se descarga, la respuesta llega por `await`
  y no por la URL de arranque: desaparece la necesidad de leer `Uri.base`, de
  limpiar la barra de direcciones y de enseñarle al enrutador qué hacer con
  `?code=`. Requiere un fragmento de tres líneas en `web/index.html`, que está
  en el README. En web trae la ventana emergente puesta; en móvil y escritorio
  le pasas un `RobleSocialOpener` —al crear el cliente con `socialOpener`, o por
  llamada— que abra el proveedor con el plugin que uses. El paquete no elige por
  ti para no arrastrar código nativo a quien no usa login social.

- **Inicio de sesión con Google y Microsoft.** En Roble el login social es
  también registro: un correo nuevo crea un usuario ya verificado y uno
  existente enlaza la identidad del proveedor, así que no hay un
  `signUpWithGoogle` aparte.

  - `socialConfig(provider)` consulta si el proveedor está activo en el
    proyecto, sin necesitar sesión. Sirve para no pintar un botón que
    respondería `403`.
  - `socialLoginUrl(provider, {extra, redirect})` construye la URL de
    arranque. No hace ninguna petición: hay que navegar a ella. El paquete
    deliberadamente no abre el navegador, para no arrastrar `url_launcher` a
    todo el que use la librería sin tocar el login social. `redirect` elige,
    por nombre, a cuál de los destinos de retorno configurados en la consola
    vuelve el usuario; omitirlo usa el llamado `default`. Es lo que permite
    que la app web, la de móvil y el entorno de desarrollo compartan proyecto
    y vuelva cada una a su sitio. **Un proyecto sin destinos configurados no
    puede arrancar el flujo**: Roble ya no deduce el retorno de la cabecera
    `Origin`.
  - `completeSocialLogin(callbackUrl, {persistSession})` canjea el código de
    la URL de retorno, guarda la sesión y devuelve el perfil — la misma forma
    que `login`.

  Con ellos llegan `RobleSocialProvider` y `RobleSocialConfig`.

- **`extra` se valida antes de salir a la red.** Como viaja en la URL del
  navegador, un `extra` inválido se descubriría a mitad del flujo de OAuth,
  cuando ya es tarde para dar un mensaje útil. Ahora `socialLoginUrl` lanza
  `ArgumentError` en el acto si supera los 4 KB serializado, si no es
  convertible a JSON, o si usa una clave que Roble reserva —`role`,
  `isAdmin`, `userId`, `permissions`, `__proto__`…— **a cualquier nivel de
  anidamiento**, indicando la ruta exacta de la clave culpable.

- **`executeQueryByName(name, {params})`** ejecuta una consulta guardada por
  su nombre en vez de por su UUID
  (`POST /saved-queries/by-name/{name}/execute`). Es lo preferible en código
  que se mantiene: el nombre sobrevive a borrar y recrear la consulta, el UUID
  no. El nombre se escapa solo, así que admite espacios y acentos.

- Primeras pruebas del paquete (`test/`), sobre el `MockClient` de `http`: 36
  casos que cubren el flujo social completo, la validación de `extra`, la
  persistencia de la sesión y las consultas guardadas.

## 1.3.0

### Añadido

- **`createMany(..., strict: true)`** lanza `RoblePartialInsertException` si el
  servidor rechaza alguna fila, en vez de confiar en que quien llama revise
  `skipped`. La excepción conserva el resultado completo, así que se sabe qué
  sí llegó a escribirse.
- **`RobleApiConfig.fromContract` valida sus argumentos** y lanza
  `ArgumentError` si `baseUrl` no es una URL o si el `contractId` está vacío o
  sigue siendo un valor de ejemplo. Antes eso se manifestaba como un `500`
  incomprensible en la primera petición.
- **Pista en el `500` de autenticación**: es lo que devuelve Roble cuando el
  contrato no existe, así que ahora el mensaje lo sugiere en lugar de dejar
  solo `Error inesperado al autenticar`.
- **`register(autoLogin: true)`** inicia sesión al terminar el registro y
  devuelve el perfil, igual que `login`. Por defecto es `false` y se sigue
  devolviendo el mensaje del servidor. `registerWithVerification` no lo
  admite: hasta validar el código del correo la cuenta no puede entrar.
- **`login(persistSession: false)`** mantiene la sesión solo en memoria: sirve
  para todo mientras la app esté abierta, pero no sobrevive al reinicio. Es el
  "recordarme" de siempre. Poner `false` **borra además la sesión que hubiera
  guardada**, para no dejar una sesión anterior recuperable en el dispositivo.
  El valor se respeta también en los refrescos automáticos posteriores.

### Cambios incompatibles

- **El servicio Realtime sale de la API pública.** `db.realtime` y los tipos
  `RobleRealtime*` se retiran mientras se estabiliza, junto con la dependencia
  `socket_io_client`. El código sigue en el historial (`v1.2.0`) para
  reincorporarlo más adelante.

- **Se recorta la superficie de datos a lo esencial.** Desaparecen
  `createTable()` y `getTableData()` —usaban endpoints que ROBLE no
  documenta—, `createTableFromTemplate()` (las tablas se crean en la consola)
  y los envoltorios `getAll()` y `getWhere()`, que eran `read()` con otro
  nombre. Se mantiene `getById()`, que sí aporta: devuelve una fila o `null`.

  | Antes | Ahora |
  | --- | --- |
  | `getAll(tabla)` | `read(tabla)` |
  | `getWhere(tabla, col, valor)` | `read(tabla, filters: {col: valor})` |

- **La sesión se persiste sola.** El paquete usa `flutter_secure_storage`
  (Keychain / Keystore / almacenamiento cifrado) por defecto, así que ya no
  hay que implementar ni pasar un `RobleTokenStorage`. El parámetro `storage`
  sigue existiendo para sustituirlo en pruebas por `RobleMemoryStorage`.

  Esto añade la dependencia `flutter_secure_storage` y sube el SDK mínimo a
  Dart 3.3 / Flutter 3.19.

- **`RobleApiConfig` solo se crea con `fromContract()`.** El constructor con
  `authUrl`/`dataUrl`/`realtimeUrl` sueltas pasa a ser privado, y desaparecen
  `fromStrings()`, `copyWith()` y `validate()`. Las URLs se componen siempre a
  partir del host y del identificador del contrato.

- **La sesión deja de ser manipulable desde fuera.** Se eliminan de la API
  pública `accessToken`, `refreshToken`, `setTokens()`, `clearTokens()` y
  `onTokenUpdate`, y el `http.Client` pasa a ser privado. El paquete guarda
  los tokens, los adjunta a cada petición, los renueva ante un `401` y los
  borra al cerrar sesión; nada de eso necesita intervención de la app.

  En su lugar hay un único miembro de consulta:

  ```dart
  bool get isLoggedIn
  ```

  Equivalencias: `db.accessToken != null` → `db.isLoggedIn`; guardar tokens a
  mano → pasar un `storage` al constructor; restaurar sesión →
  `restoreSession()`; borrarla → `logout()`. El `http.Client` se sigue
  pudiendo inyectar por el constructor para pruebas, pero ya no se expone.

### Cambiado

- **`restoreSession()` ahora comprueba que la sesión siga viva.** Además de
  cargar los tokens guardados, renueva el access token contra el servidor, así
  que un `true` significa que la sesión sirve de verdad y no solo que había
  tokens en el almacenamiento. Si el refresh token caducó o fue revocado,
  limpia la sesión y devuelve `false`.

  Los fallos de red **no** borran la sesión: se propagan
  `RobleApiNetworkException` y `RobleApiTimeoutException` para poder
  distinguir "sesión caducada" de "sin conexión".

  Con `restoreSession(verify: false)` se mantiene el comportamiento anterior
  de solo leer el almacenamiento.

## 1.2.0

### Cambios incompatibles

- **`currentUser()` ahora devuelve el perfil del usuario, no los datos del
  token.** Pasa de `GET /verify-token` a `GET /me`, que es lo que realmente
  interesa a una app: `userId`, `email`, `name`, el `extra` del registro y las
  fechas de creación y actualización. Antes devolvía los claims del JWT
  (`sub`, `role`, `sessionId`), que son detalle interno de la autenticación.

  | Antes (`/verify-token`) | Ahora (`/me`) |
  | --- | --- |
  | `sub` | `userId` |
  | `email` | `email` |
  | `dbName`, `role`, `sessionId` | — |
  | — | `id`, `name`, `extra`, `createdAt`, `updatedAt` |

  Si leías `user['sub']`, usa `user['userId']`. La librería ya no llama a
  `/verify-token`: la validez del token la gestiona ella sola con el refresco
  automático.

- **`login()` devuelve el perfil del usuario, no los tokens.** Tras
  autenticar pide `/me` y devuelve el mismo mapa que [currentUser]. Los tokens
  se guardan internamente y siguen disponibles en `accessToken` y
  `refreshToken`.

  Si la llamada a `/me` falla, la sesión **sigue activa**: el error se propaga
  pero `accessToken` ya tiene valor, así que se puede distinguir un fallo de
  credenciales de uno de perfil y reintentar con `currentUser()`.

## 1.1.0

### Añadido

- **Persistencia de sesión opcional**: la interfaz `RobleTokenStorage`, el
  parámetro `storage` del constructor y `restoreSession()`. El cliente guarda
  la sesión en cada login y refresco y la borra al cerrar sesión, así que
  sobrevive a un reinicio de la app. Incluye `RobleMemoryStorage` para
  pruebas. Sin `storage`, los tokens siguen viviendo solo en memoria, como
  hasta ahora.

### Corregido

- Si el servidor rotara el refresh token al refrescar, ahora se conserva en
  lugar de descartarse. Hoy `/refresh-token` solo devuelve `accessToken`, así
  que es prevención.

## 1.0.0

Primera versión publicada bajo el nombre `roble`. Sustituye al paquete
`roble_api_database`, cuya API se mantiene salvo por los cambios listados abajo.

### Añadido

- `RobleApiConfig.fromContract({baseUrl, contractId})`: compone las rutas
  `/auth/...` y `/database/...` a partir del identificador del contrato.
- Getters públicos `accessToken` y `refreshToken`.
- Callback `onTokenUpdate`, invocado en cada cambio del access token.
- `RobleApiConfig.timeout` configurable (30 s por defecto).
- Documentación de todos los métodos públicos en el README.
- Cobertura completa de la API documentada de ROBLE (19 endpoints):
  `registerWithVerification()`, `verifyEmail()`, `resendCode()`, `currentUser()`
  (`/verify-token`, el único endpoint que devuelve la identidad del usuario),
  `forgotPassword()`, `resetPassword()`, `deleteAccount()`, `createMany()`,
  `executeQuery()`, `createTableFromTemplate()` y `publicRead()`.
- Modelos `RobleInsertResult`, `RobleSkippedRecord` y `RobleQueryResult`.
- **Servicio Realtime** (`db.realtime`): árbol JSON por proyecto con API al
  estilo Firebase — `ref()`, `child()`, `parent`, `key`, `get(shallow:)`,
  `set()`, `update()`, `push()`, `remove()`, más `collections()` y `health()`.
- **Suscripciones en tiempo real**: `ref.onValue` y `ref.onEvent` sobre
  WebSocket, con `RobleRealtimeEvent`, `status`, `onStatusChange` y `close()`.
  Un solo socket compartido, resuscripción automática al reconectar y
  cancelación por colección cuando no quedan escuchas. Añade la dependencia
  `socket_io_client`.
- `register()` y `registerWithVerification()` aceptan un `extra` opcional
  (`Map<String, dynamic>`) con campos adicionales que el backend guarda junto
  al usuario. Se envía en el campo `extra` del cuerpo, y se omite si es nulo.

### Eliminado

- `authHeaders` y `dataHeaders` de `RobleApiConfig`, junto con
  `withBearerToken()` y el getter muerto `defaultHeaders`. La API solo necesita
  `Content-Type` y `Authorization`, y ambos los pone el cliente. Si necesitas
  cabeceras propias, inyecta un `http.Client` que las añada.

### Corregido

- **`PATCH` se enviaba como `PUT`.** El `switch` de `_makeRequest` agrupaba
  ambos métodos en `client.put()`, así que `realtime.ref().update()`
  sobrescribía el nodo en lugar de fusionar los campos. Ahora usa
  `client.patch()`.
- **`create()` podía informar éxito sobre una fila rechazada.** Enviaba el
  registro a `/insert`, que responde `200` con `{inserted: [], skipped: [...]}`
  cuando el servidor lo rechaza; al no haber nada en `inserted`, el método
  devolvía ese objeto como si fuera la fila creada, sin `_id` y sin error.
  Ahora usa `/insert-one`, que devuelve la fila directamente y falla con un
  error HTTP si la rechaza. Para varios registros, `createMany()` expone
  `skipped` en lugar de descartarlo.

### Cambiado

- Las excepciones que lanza el cliente ahora son las subclases exportadas del
  paquete: `RobleApiNetworkException`, `RobleApiTimeoutException`,
  `RobleApiFormatException`, `RobleApiHttpException` (con `statusCode`) y
  `RobleApiAuthException`. Antes se lanzaba una clase interna homónima que
  nunca coincidía con la exportada, por lo que `on RobleApiException catch`
  jamás capturaba nada.
- `logout()` ya no recibe `accessToken`: usa el token almacenado y limpia la
  sesión al terminar.
- El punto de entrada de la librería pasa a ser `package:roble/roble.dart`.
- Un error HTTP ya no se envuelve como `Error inesperado: ...`; se propaga como
  `RobleApiHttpException` con el mensaje del servidor.
- Tras un `401`, solo el fallo del refresco produce `RobleApiAuthException`; si
  el reintento falla, se reporta el error real de esa petición.

### Eliminado

- `refreshAccessToken()` y `refreshToken({refreshToken})` públicos. El refresco
  del token es interno y automático ante un `401`.
- `simulateGet()`, que no hacía nada.
- `RobleApiDataBase.timeoutDuration`, reemplazado por `RobleApiConfig.timeout`.
