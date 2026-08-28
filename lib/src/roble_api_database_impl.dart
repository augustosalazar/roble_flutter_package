import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'roble_api_config.dart';
import 'roble_api_exception.dart';
import 'roble_models.dart';
import 'roble_pkce.dart';
import 'roble_google_signin.dart';
import 'roble_json_db.dart';
import 'roble_realtime.dart';
import 'roble_realtime_client.dart';
import 'roble_social_auth.dart';
import 'roble_social_window.dart';
import 'roble_storage.dart';

/// Cliente HTTP robusto para interactuar con la API Roble.
///
/// - Soporta inyección de `http.Client` para facilitar tests.
/// - Maneja timeouts, errores de red y parsing.
/// - Expone métodos CRUD y auth adaptados al backend Roble.
class RobleApiDataBase {
  /// URLs base del proyecto.
  final RobleApiConfig config;

  /// Dónde se persiste la sesión. Por defecto [RobleSecureStorage].
  final RobleTokenStorage storage;

  final http.Client _client;

  String? _accessToken;
  String? _refreshToken;

  /// Si la sesión debe sobrevivir al cierre de la app. Lo fija `login` con su
  /// parámetro `persistSession` y afecta también a los refrescos posteriores.
  bool _persistTokens = true;

  /// Verifier del flujo social v2 en curso, a la espera del canje.
  ///
  /// Vive en memoria y solo hasta que [exchangeSocialCode] lo consume: si
  /// sobreviviera al intento, un código robado podría canjearse más tarde.
  RoblePkce? _pkcePendiente;

  late final String _storageKey =
      'roble.session.${config.authUrl.split('/').last}';

  /// Destino de retorno del login social al que vuelve **esta** app, por su
  /// nombre en la consola de Roble. `null` usa el llamado `default`.
  ///
  /// Es una constante de la app, no de cada llamada: la versión web siempre
  /// vuelve al destino web y la de móvil al de móvil. Se fija una vez aquí y
  /// [startSocialLogin] lo usa solo.
  final String? ssoRedirect;

  /// Cómo se abre el proveedor en el login social. `null` usa la ventana
  /// emergente de web, que fuera de web lanza pidiendo que pongas la tuya.
  ///
  /// Se fija una vez aquí, como [ssoRedirect], porque es una constante de la
  /// app: cada plataforma abre el proveedor siempre igual.
  final RobleSocialOpener? socialOpener;

  /// Client ID de iOS de Google. En Android se deja `null`: alli lo resuelve el
  /// SDK a partir de la firma del paquete. Es por plataforma, asi que Roble no
  /// lo guarda y es lo unico de Google que sigue en manos de la app.
  final String? googleIosClientId;

  final RobleIdTokenSource? _idTokenSource;
  RobleIdTokenSource? _googleCache;

  /// Origen del `id_token` nativo. Se crea la primera vez que se usa: en web
  /// nunca llega a tocar el plugin.
  RobleIdTokenSource get _google =>
      _idTokenSource ??
      (_googleCache ??= RobleGoogleSignIn(iosClientId: googleIosClientId));

  /// Como se abre el socket de tiempo real. Solo se pasa en pruebas.
  final RobleSocketFactory? socketFactory;

  /// Crea el cliente.
  ///
  /// La sesión se persiste sola en el almacén seguro del sistema; no hace
  /// falta configurar nada. [storage] y [client] existen para poder
  /// sustituirlos en pruebas.
  ///
  /// [ssoRedirect] solo hace falta si usas login social y el destino de
  /// retorno de esta app no es el `default`. [socialOpener] solo hace falta
  /// para usar [signInWithProvider] fuera de web.
  RobleApiDataBase({
    required this.config,
    http.Client? client,
    RobleTokenStorage? storage,
    String? ssoRedirect,
    this.socialOpener,
    this.socketFactory,
    this.googleIosClientId,
    RobleIdTokenSource? idTokenSource,
  })  : _idTokenSource = idTokenSource,
        _client = client ?? http.Client(),
        storage = storage ?? RobleSecureStorage(),
        ssoRedirect = _validarRedirect(ssoRedirect, 'ssoRedirect');

  /// Recorta el nombre del destino y rechaza los vacíos.
  ///
  /// Un `redirect` en blanco no es "sin destino": el servidor lo trata como un
  /// destino desconocido y responde `400`, un mensaje que despista.
  static String? _validarRedirect(String? valor, String nombre) {
    if (valor == null) return null;

    final limpio = valor.trim();
    if (limpio.isEmpty) {
      throw ArgumentError.value(
        valor,
        nombre,
        'No puede estar vacío. Es el nombre de un destino de retorno '
            'configurado en la consola de Roble; omítelo para usar "default"',
      );
    }
    return limpio;
  }

  // ============================================================
  // ============= SESIÓN =======================================
  // ============================================================

  /// `true` si hay una sesión iniciada en este cliente.
  ///
  /// No dice si el servidor la sigue aceptando: para eso está
  /// [restoreSession].
  bool get isLoggedIn => _accessToken != null && _accessToken!.isNotEmpty;

  void _updateAccessToken(String? token) {
    _accessToken = token;
    // Único punto por el que pasan login, refresco, logout y restauración.
    unawaited(_persistSession());
  }

  /// Descarta la sesión en memoria y en el almacenamiento.
  void _clearTokens() {
    _refreshToken = null;
    _updateAccessToken(null);
    // El socket lleva el access token de esta sesion en el handshake, asi que
    // no tiene por que sobrevivirla: sin esto quedaba abierto y recibiendo
    // cambios despues de cerrar sesion.
    unawaited(_realtime?.close());
    _realtime = null;
    _json = null;
  }

  /// Restaura la sesión y comprueba que siga siendo válida.
  ///
  /// Llámalo al arrancar la app, antes de pintar pantallas protegidas:
  ///
  /// ```dart
  /// if (await db.restoreSession()) {
  ///   irAlInicio();
  /// } else {
  ///   irAlLogin();
  /// }
  /// ```
  ///
  /// Carga los tokens del [storage] (si no hay ya una sesión en memoria) y
  /// renueva el access token con el refresh token. Devuelve `true` solo si el
  /// servidor acepta la renovación, así que un `true` significa que la sesión
  /// sirve de verdad, no solo que había tokens guardados.
  ///
  /// Si el refresh token ya no vale, limpia la sesión y devuelve `false`.
  ///
  /// Los fallos de red **no** borran la sesión: se propaga la excepción
  /// ([RobleApiNetworkException], [RobleApiTimeoutException]) para que la app
  /// pueda distinguir "sesión caducada" de "sin conexión" y reintentar.
  ///
  /// Con [verify] en `false` solo carga los tokens del almacenamiento, sin
  /// llamar al servidor: más rápido, pero la sesión puede estar caducada.
  Future<bool> restoreSession({bool verify = true}) async {
    // 1. Si no hay sesión en memoria, se intenta cargar del almacenamiento.
    if (_refreshToken == null) await _loadStoredSession();
    if (_refreshToken == null) return false;

    // Si la sesión venía del almacén, se sigue persistiendo.
    _persistTokens = true;

    if (!verify) return true;

    // 2. Renovar es la única forma de saber si el refresh token sigue vivo.
    try {
      await _refreshAccessToken();
      return true;
    } on RobleApiNetworkException {
      rethrow;
    } on RobleApiTimeoutException {
      rethrow;
    } catch (_) {
      // Token revocado o caducado: la sesión ya no sirve.
      _clearTokens();
      return false;
    }
  }

  /// Borra la sesión guardada sin tocar la que hay en memoria.
  Future<void> _forgetStoredSession() async {
    try {
      await storage.removeItem(_storageKey);
    } catch (_) {
      // Almacenamiento no disponible: no hay nada que borrar.
    }
  }

  /// Carga los tokens guardados en [storage], si los hay.
  Future<void> _loadStoredSession() async {
    try {
      final raw = await storage.getItem(_storageKey);
      if (raw == null || raw.isEmpty) return;

      final data = jsonDecode(raw);
      if (data is! Map) return;

      final access = data['accessToken'] as String?;
      final refresh = data['refreshToken'] as String?;
      if (access == null || refresh == null) return;

      _refreshToken = refresh;
      _updateAccessToken(access);
    } catch (_) {
      // Sesión corrupta o almacenamiento no disponible: se empieza de cero.
    }
  }

  /// Guarda o borra la sesión. Nunca hace fallar la petición en curso.
  Future<void> _persistSession() async {
    try {
      final access = _accessToken;
      final refresh = _refreshToken;

      if (access != null && refresh != null) {
        // Con `persistSession: false` la sesión vive solo en memoria.
        if (!_persistTokens) return;
        await storage.setItem(
          _storageKey,
          jsonEncode({'accessToken': access, 'refreshToken': refresh}),
        );
      } else {
        // Al cerrar sesión se limpia siempre, se estuviera persistiendo o no.
        await storage.removeItem(_storageKey);
      }
    } catch (_) {
      // Almacenamiento lleno o sin permisos: la sesión sigue en memoria.
    }
  }

  // ============================================================
  // ============= MÉTODOS INTERNOS =============================
  // ============================================================

  Uri _buildUri(String baseUrl, String endpoint,
      [Map<String, String>? queryParams]) {
    // Un endpoint vacio apunta a la base misma: pegarle la barra dejaria una
    // final, y no toda ruta la tolera.
    final url = endpoint.isEmpty ? baseUrl : '$baseUrl/$endpoint';
    return Uri.parse(url).replace(queryParameters: queryParams);
  }

  Map<String, String> _buildHeaders({bool skipAuth = false}) {
    final headers = <String, String>{'Content-Type': 'application/json'};

    // ✅ Si hay token, lo agrega automáticamente como header
    if (!skipAuth && _accessToken != null && _accessToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $_accessToken';
    }

    return headers;
  }

  /// Ejecuta una solicitud HTTP genérica.
  ///
  /// [skipAuth] omite el header `Authorization`, necesario para endpoints
  /// públicos como `/public-read`.
  Future<dynamic> _makeRequest(
    String method,
    String endpoint, {
    Object? body,
    Map<String, String>? queryParams,
    bool isAuthRequest = false,
    bool skipAuth = false,
    String? baseUrlOverride,
  }) async {
    final baseUrl =
        baseUrlOverride ?? (isAuthRequest ? config.authUrl : config.dataUrl);
    final uri = _buildUri(baseUrl, endpoint, queryParams);
    final headers = _buildHeaders(skipAuth: skipAuth);

    try {
      http.Response response;
      switch (method.toUpperCase()) {
        case 'GET':
          response =
              await _client.get(uri, headers: headers).timeout(config.timeout);
          break;
        case 'POST':
          response = await _client
              .post(uri,
                  headers: headers,
                  body: body != null ? jsonEncode(body) : null)
              .timeout(config.timeout);
          break;
        case 'PUT':
          response = await _client
              .put(uri,
                  headers: headers,
                  body: body != null ? jsonEncode(body) : null)
              .timeout(config.timeout);
          break;
        case 'PATCH':
          response = await _client
              .patch(uri,
                  headers: headers,
                  body: body != null ? jsonEncode(body) : null)
              .timeout(config.timeout);
          break;
        case 'DELETE':
          response = await _client
              .delete(uri,
                  headers: headers,
                  body: body != null ? jsonEncode(body) : null)
              .timeout(config.timeout);
          break;
        default:
          throw RobleApiException('HTTP method $method no soportado');
      }

      // Respuesta exitosa
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (response.body.isEmpty) return null;
        try {
          return jsonDecode(response.body);
        } catch (_) {
          return response.body;
        }
      }

      // Manejo de errores HTTP
      if (response.statusCode == 401 &&
          _refreshToken != null &&
          !isAuthRequest &&
          !skipAuth) {
        // 🔁 Intentamos refrescar el token automáticamente
        try {
          await _refreshAccessToken();
        } catch (e) {
          throw RobleApiAuthException(
              'Token expirado y no se pudo refrescar: $e');
        }
        // Reintentamos la misma solicitud una sola vez
        return await _makeRequest(
          method,
          endpoint,
          body: body,
          queryParams: queryParams,
          isAuthRequest: isAuthRequest,
          skipAuth: skipAuth,
          baseUrlOverride: baseUrlOverride,
        );
      }

      String msg;
      if (response.body.isEmpty) {
        msg = 'El servidor respondió sin cuerpo';
      } else {
        try {
          final decoded = jsonDecode(response.body);
          final detail = (decoded is Map)
              ? (decoded['message'] ?? decoded['error'])
              : null;
          msg = detail != null ? '$detail' : response.body;
        } catch (_) {
          msg = response.body;
        }
      }

      // Un 500 en autenticación es lo que devuelve Roble cuando el contrato
      // no existe; sin esta pista el mensaje no ayuda nada a diagnosticarlo.
      if (isAuthRequest && response.statusCode == 500) {
        msg = '$msg — revisa que el contractId sea correcto '
            '(${config.authUrl.split('/').last})';
      }

      throw RobleApiHttpException(response.statusCode, msg);
    } on RobleApiException {
      // Ya es una excepción del paquete: la propagamos sin envolverla.
      rethrow;
    } on SocketException {
      throw const RobleApiNetworkException('Sin conexión a internet');
    } on TimeoutException {
      throw const RobleApiTimeoutException('Tiempo de espera agotado');
    } on FormatException {
      throw const RobleApiFormatException('Respuesta con formato inválido');
    } catch (e) {
      throw RobleApiException('Error inesperado: $e');
    }
  }

  // ============================================================
  // ============= MÉTODOS DE AUTENTICACIÓN =====================
  // ============================================================

  /// Registra un usuario sin verificación por correo. La cuenta queda activa
  /// de inmediato.
  ///
  /// [extra] son campos adicionales opcionales que el backend guarda junto al
  /// usuario; se envían tal cual en el campo `extra` del cuerpo.
  ///
  /// **Lo que devuelve depende de [autoLogin]:**
  ///
  /// - `false` (por defecto): el mensaje del servidor, p. ej.
  ///   `{'message': 'Usuario registrado correctamente.'}`.
  /// - `true`: inicia sesión y devuelve el perfil, lo mismo que [login].
  ///
  /// [persistSession] solo se aplica cuando [autoLogin] es `true`, y hace lo
  /// mismo que en [login].
  ///
  /// Si el registro funciona pero el login automático falla, **la cuenta ya
  /// está creada**: el error se propaga y [isLoggedIn] sigue en `false`, así
  /// que basta con reintentar [login] sin volver a registrar.
  ///
  /// ```dart
  /// final user = await db.register(
  ///   email: 'ana@correo.com',
  ///   password: 'MiClave!1',
  ///   name: 'Ana García',
  ///   autoLogin: true,
  /// );
  /// print(user['userId']);
  /// ```
  Future<Map<String, dynamic>> register({
    required String email,
    required String password,
    required String name,
    Map<String, dynamic>? extra,
    bool autoLogin = false,
    bool persistSession = true,
  }) async {
    final res = await _makeRequest(
      'POST',
      'signup-direct',
      body: {
        'email': email,
        'password': password,
        'name': name,
        if (extra != null) 'extra': extra,
      },
      isAuthRequest: true,
    );

    if (autoLogin) {
      return await login(
        email: email,
        password: password,
        persistSession: persistSession,
      );
    }

    return (res is Map) ? Map<String, dynamic>.from(res) : {};
  }

  /// Registra un usuario y envía un código de verificación por correo.
  ///
  /// El registro no queda activo hasta llamar a [verifyEmail] con el código.
  ///
  /// [extra] son campos adicionales opcionales que el backend guarda junto al
  /// usuario; se envían tal cual en el campo `extra` del cuerpo.
  Future<Map<String, dynamic>> registerWithVerification({
    required String email,
    required String password,
    required String name,
    Map<String, dynamic>? extra,
  }) async {
    final res = await _makeRequest(
      'POST',
      'signup',
      body: {
        'email': email,
        'password': password,
        'name': name,
        if (extra != null) 'extra': extra,
      },
      isAuthRequest: true,
    );
    return (res is Map) ? Map<String, dynamic>.from(res) : {};
  }

  /// Confirma el correo con el código de 6 dígitos recibido.
  Future<Map<String, dynamic>> verifyEmail({
    required String email,
    required String code,
  }) async {
    final res = await _makeRequest(
      'POST',
      'verify-email',
      body: {'email': email, 'code': code},
      isAuthRequest: true,
    );
    return (res is Map) ? Map<String, dynamic>.from(res) : {};
  }

  /// Reenvía el código de verificación.
  Future<Map<String, dynamic>> resendCode({required String email}) async {
    final res = await _makeRequest(
      'POST',
      'resend-code',
      body: {'email': email},
      isAuthRequest: true,
    );
    return (res is Map) ? Map<String, dynamic>.from(res) : {};
  }

  /// Inicia sesión y devuelve el perfil del usuario.
  ///
  /// Con [persistSession] en `true` (por defecto) la sesión se guarda en el
  /// almacén seguro y sobrevive al cierre de la app; con `false` vive solo en
  /// memoria: todo funciona igual mientras la app esté abierta, pero al
  /// reiniciar habrá que volver a entrar. Es el clásico "recordarme".
  ///
  /// Poner `false` **borra además cualquier sesión guardada antes**, para que
  /// no quede una sesión anterior recuperable en el dispositivo.
  ///
  /// Tras autenticar, pide el perfil a `/me`. Si esa segunda llamada falla, la
  /// sesión **sigue activa**: el error se propaga, pero [accessToken] ya tiene
  /// valor, así que puedes distinguir un fallo de credenciales de uno de
  /// perfil y reintentar con [currentUser].
  ///
  /// ```dart
  /// try {
  ///   final user = await db.login(email: email, password: password);
  /// } catch (e) {
  ///   if (db.accessToken != null) {
  ///     // credenciales correctas, solo falló el perfil
  ///     final user = await db.currentUser();
  ///   } else {
  ///     // credenciales inválidas o problema de red
  ///   }
  /// }
  /// ```
  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
    bool persistSession = true,
  }) async {
    final res = await _makeRequest(
      'POST',
      'login',
      body: {'email': email, 'password': password},
      isAuthRequest: true,
    );

    _persistTokens = persistSession;
    // Si esta vez no se quiere recordar la sesión, se borra la anterior.
    if (!persistSession) await _forgetStoredSession();

    if (res is Map) {
      _refreshToken = res['refreshToken'] as String?;
      _updateAccessToken(res['accessToken'] as String?);
    }

    return await currentUser();
  }

  /// Cierra la sesión en el servidor y descarta los tokens locales.
  Future<void> logout() async {
    if (_accessToken == null || _accessToken!.isEmpty) {
      throw const RobleApiAuthException(
          'No hay token activo para cerrar sesión.');
    }

    await _makeRequest('POST', 'logout', isAuthRequest: true);
    _clearTokens();
  }

  /// Devuelve el perfil del usuario autenticado: `userId`, `email`, `name`,
  /// el `extra` que se envió al registrarse y las fechas del registro.
  ///
  /// Lanza [RobleApiHttpException] con `401` si no hay sesión válida.
  Future<Map<String, dynamic>> currentUser() async {
    final res = await _makeRequest('GET', 'me', isAuthRequest: true);

    if (res is Map) return Map<String, dynamic>.from(res);
    throw const RobleApiFormatException(
        'Respuesta inesperada al obtener el usuario.');
  }

  /// Envía un correo con el enlace de restablecimiento de contraseña.
  Future<Map<String, dynamic>> forgotPassword({required String email}) async {
    final res = await _makeRequest(
      'POST',
      'forgot-password',
      body: {'email': email},
      isAuthRequest: true,
    );
    return (res is Map) ? Map<String, dynamic>.from(res) : {};
  }

  /// Restablece la contraseña con el token recibido por correo.
  Future<Map<String, dynamic>> resetPassword({
    required String token,
    required String newPassword,
  }) async {
    final res = await _makeRequest(
      'POST',
      'reset-password',
      body: {'token': token, 'newPassword': newPassword},
      isAuthRequest: true,
    );
    return (res is Map) ? Map<String, dynamic>.from(res) : {};
  }

  /// Elimina permanentemente la cuenta autenticada y limpia la sesión local.
  ///
  /// La operación no se puede deshacer: pide confirmación al usuario antes
  /// de llamarla.
  Future<void> deleteAccount() async {
    if (_accessToken == null || _accessToken!.isEmpty) {
      throw const RobleApiAuthException(
          'No hay sesión activa para eliminar la cuenta.');
    }

    await _makeRequest('DELETE', 'account', isAuthRequest: true);
    _clearTokens();
  }

  // ============================================================
  // ============= INICIO DE SESIÓN SOCIAL ======================
  // ============================================================

  /// Claves que Roble rechaza dentro de `extra`, a cualquier nivel de
  /// anidamiento: unas por seguridad del propio usuario (`role`, `isAdmin`),
  /// otras porque contaminarían el prototipo al deserializar en JavaScript.
  static const Set<String> _extraForbiddenKeys = {
    '__proto__',
    '_proto_',
    'constructor',
    'prototype',
    'role',
    'roleId',
    'permissions',
    'isAdmin',
    'isVerified',
    'isSSO',
    'userId',
    'user_id',
  };

  /// Límite del servidor para `extra` ya serializado.
  static const int _extraMaxBytes = 4096;

  /// Inicia sesión con [provider] en una ventana, sin descargar la app.
  ///
  /// Es el camino corto en web: abre el proveedor, espera el retorno y
  /// devuelve el perfil, igual que [login]. No hay que tocar la URL de
  /// arranque ni el enrutado, porque la app principal nunca se recarga.
  ///
  /// ```dart
  /// final user = await db.signInWithProvider(RobleSocialProvider.google);
  /// ```
  ///
  /// En una app nativa suele ser mejor [signInWithIdToken], que no abre
  /// ninguna ventana.
  ///
  /// Fuera de web hay que pasar un [RobleSocialOpener], al crear el cliente
  /// con `socialOpener` o aquí: el paquete no abre el navegador por su cuenta
  /// para no obligar a cargar con un plugin nativo a quien no usa esto.
  ///
  /// Lanza [RobleApiAuthException] si la ventana se bloquea, si el usuario la
  /// cierra, si se agota [timeout] o si el retorno no trae `code`; y lo mismo
  /// que [exchangeSocialCode] si el canje falla.
  Future<Map<String, dynamic>> signInWithProvider(
    RobleSocialProvider provider, {
    Map<String, dynamic>? extra,
    bool persistSession = true,
    Duration timeout = const Duration(minutes: 5),
    RobleSocialOpener? opener,
  }) async {
    // El de la llamada manda; si no, el de la app; si no, la ventana de web.
    final abrir = opener ?? socialOpener ?? awaitSocialCallback;

    final url = await startSocialLogin(provider.name, extra: extra);
    final callback = await abrir(url, timeout);

    return exchangeSocialCode(_codigoDe(callback),
        persistSession: persistSession);
  }

  /// Inicia sesion con Google por el mejor camino que soporte la plataforma.
  ///
  /// En movil usa el SDK nativo: sale un selector de cuentas, sin navegador,
  /// sin esquema de URL propio y sin retorno que enrutar. En web, o donde el
  /// SDK no exista, cae al flujo de ventana de [signInWithProvider]. Devuelve
  /// el perfil, igual que [login].
  ///
  /// ```dart
  /// final perfil = await db.signInWithGoogle();
  /// ```
  ///
  /// El Client ID sale de la consola de Roble, no del build de la app: es la
  /// audiencia para la que Google emite el token y la que el servidor comprueba
  /// despues, asi que teniendolo de un solo sitio no pueden discrepar. Solo el
  /// de iOS se pasa aqui, con `googleIosClientId`, porque es por plataforma.
  ///
  /// Lanza [RobleApiAuthException] si se cancela el selector.
  Future<Map<String, dynamic>> signInWithGoogle({
    bool persistSession = true,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (_google.isSupported) {
      final serverClientId = await providerClientId('google');

      // Sin clientId, o Google no esta configurado en el proyecto, o el
      // servidor es anterior a que el endpoint lo devolviera. El flujo de
      // navegador no lo necesita, asi que se intenta por ahi.
      if (serverClientId != null) {
        return _signInWithGoogleNatively(
          serverClientId,
          persistSession: persistSession,
        );
      }
    }

    return signInWithProvider(
      RobleSocialProvider.google,
      persistSession: persistSession,
      timeout: timeout,
    );
  }

  Future<Map<String, dynamic>> _signInWithGoogleNatively(
    String serverClientId, {
    required bool persistSession,
  }) async {
    final nonce = newNonce();
    final idToken = await _google.idToken(
      serverClientId: serverClientId,
      nonce: nonce,
    );

    if (idToken == null) {
      // Cancelado. Caer al flujo de navegador aqui abriria una ventana que la
      // persona acaba de rechazar.
      throw const RobleApiAuthException(
          'Inicio de sesión con Google cancelado.');
    }

    return signInWithIdToken(
      provider: 'google',
      idToken: idToken,
      nonce: nonce,
      persistSession: persistSession,
    );
  }

  /// Client ID que el proyecto tiene configurado para [provider], o `null` si
  /// ese proveedor no esta configurado.
  ///
  /// Evita que la app lleve una segunda copia del valor: la consola de Roble es
  /// el unico sitio donde se define.
  Future<String?> providerClientId(String provider) async {
    for (final p in await listProviders()) {
      if (p.name == provider) return p.clientId;
    }
    return null;
  }

  /// Valor de un solo uso que ata un `id_token` a esta peticion.
  ///
  /// Viaja al proveedor, vuelve dentro del token y Roble comprueba que sea el
  /// mismo, que es lo que impide reutilizar un token capturado. [signInWithGoogle]
  /// ya lo hace por su cuenta; esto es para quien llame a [signInWithIdToken]
  /// directamente.
  static String newNonce() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// `true` si [url] es un retorno del login social.
  ///
  /// Para no repartir por la app el conocimiento de que el retorno se
  /// reconoce por un `?code=`:
  ///
  /// ```dart
  /// // Al arrancar, en web.
  /// if (db.isSocialCallback(Uri.base)) {
  ///   await db.exchangeSocialCode(Uri.base.queryParameters['code']!);
  /// }
  /// ```
  bool isSocialCallback(Uri url) =>
      url.queryParameters['code']?.isNotEmpty ?? false;

  /// Saca el `code` de la URL de retorno, o explica qué le falta.
  ///
  /// Un retorno sin `code` suele ser el proveedor devolviendo un error, y
  /// decirlo aquí ahorra un canje que iba a fallar de todas formas.
  String _codigoDe(Uri callbackUrl) {
    final code = callbackUrl.queryParameters['code'];
    if (code == null || code.isEmpty) {
      final error = callbackUrl.queryParameters['error'];
      throw RobleApiAuthException(
        error != null
            ? 'El proveedor rechazó el inicio de sesión: $error'
            : 'La URL de retorno no trae ningún código de autorización.',
      );
    }
    return code;
  }

  // ============================================================
  // ============= LOGIN SOCIAL v2 ==============================
  // ============================================================
  //
  // Hablan con los endpoints genéricos, que están detrás de
  // AUTH_V2_PROVIDERS en el servidor: con la bandera apagada responden 400.

  /// Guarda los tokens de una respuesta de sesión y devuelve el perfil.
  ///
  /// Es lo que ya hacían `login` y el canje social, en un solo sitio.
  Future<Map<String, dynamic>> _iniciarSesionCon(
    dynamic res,
    bool persistSession,
  ) async {
    _persistTokens = persistSession;
    if (!persistSession) await _forgetStoredSession();

    if (res is Map) {
      _refreshToken = res['refreshToken'] as String?;
      _updateAccessToken(res['accessToken'] as String?);
    }

    if (!isLoggedIn) {
      throw const RobleApiFormatException(
          'La respuesta no incluyó un access token.');
    }

    return await currentUser();
  }

  /// Convierte el `409` del servidor en [RobleApiConflictException].
  ///
  /// Merece su propio tipo porque no se arregla reintentando: hay que entrar
  /// con el método que ya se tiene y vincular el proveedor después.
  Future<T> _traduciendoConflicto<T>(Future<T> Function() accion) async {
    try {
      return await accion();
    } on RobleApiConflictException {
      rethrow;
    } on RobleApiHttpException catch (e) {
      if (e.statusCode == 409) throw RobleApiConflictException(e.message);
      rethrow;
    }
  }

  /// Proveedores habilitados en el proyecto, en una sola llamada.
  ///
  /// Sirve para pintar los botones sin saber de antemano qué proveedores hay,
  /// así que añadir uno en el servidor no obliga a publicar una versión nueva
  /// de la app.
  ///
  /// ```dart
  /// for (final p in await db.listProviders()) {
  ///   botones.add(BotonSocial(p.displayName, () => db.startSocialLogin(p.name)));
  /// }
  /// ```
  Future<List<RobleProviderInfo>> listProviders() async {
    final res = await _makeRequest(
      'GET',
      'auth/providers',
      isAuthRequest: true,
      skipAuth: true,
    );

    if (res is List) {
      return res
          .whereType<Map>()
          .map(RobleProviderInfo.fromJson)
          .toList(growable: false);
    }
    throw const RobleApiFormatException(
        'Respuesta inesperada al listar los proveedores.');
  }

  /// Arranca el login social v2 y devuelve la URL a la que hay que navegar.
  ///
  /// Frente al flujo antiguo, que se quitó en 2.0.0:
  ///
  /// - Añade **PKCE**, así que un código interceptado no sirve sin el verifier
  ///   que se queda en este proceso. En móvil importa: otra app puede
  ///   registrar el mismo esquema de URL y quedarse con el retorno.
  /// - `extra` viaja en el **cuerpo**, no en la URL, así que deja de aparecer
  ///   en los logs de acceso, en los del proxy y en el historial.
  /// - Acepta cualquier proveedor por nombre, no solo los dos del enum.
  ///
  /// Es asíncrono porque el servidor tiene que crear el flujo antes de decir a
  /// dónde ir. Después hay que llamar a [exchangeSocialCode] con el `code`
  /// que llega en la URL de retorno.
  Future<Uri> startSocialLogin(
    String provider, {
    Map<String, dynamic>? extra,
    String? redirect,
    String? scopes,
    bool offlineAccess = false,
  }) async {
    if (extra != null && extra.isNotEmpty) _validarSocialExtra(extra);

    final pkce = RoblePkce.generar();

    final destino = _validarRedirect(redirect, 'redirect') ?? ssoRedirect;
    final res = await _makeRequest(
      'POST',
      'auth/$provider/start',
      isAuthRequest: true,
      skipAuth: true,
      body: {
        'codeChallenge': pkce.challenge,
        if (destino != null) 'redirect': destino,
        if (extra != null && extra.isNotEmpty) 'extra': extra,
        if (scopes != null) 'scopes': scopes,
        if (offlineAccess) 'offlineAccess': true,
      },
    );

    if (res is! Map || res['url'] is! String) {
      throw const RobleApiFormatException(
          'El servidor no devolvió la URL de inicio del proveedor.');
    }

    // Solo se guarda si el servidor aceptó el flujo: si falló, no queda un
    // verifier huérfano que confunda al canje siguiente.
    _pkcePendiente = pkce;
    return Uri.parse(res['url'] as String);
  }

  /// Canjea el código del retorno por una sesión, y devuelve el perfil.
  ///
  /// Consume el verifier de [startSocialLogin], de modo que un canje fallido
  /// no se puede reintentar con el mismo: se arranca un login nuevo.
  ///
  /// Lanza [RobleApiConflictException] si el proveedor no certifica el correo
  /// y ese correo ya tiene cuenta.
  Future<Map<String, dynamic>> exchangeSocialCode(
    String code, {
    bool persistSession = true,
  }) async {
    final pkce = _pkcePendiente;
    _pkcePendiente = null;

    final res = await _traduciendoConflicto(() => _makeRequest(
          'POST',
          'auth/token',
          isAuthRequest: true,
          skipAuth: true,
          body: {
            'code': code,
            if (pkce != null) 'codeVerifier': pkce.verifier,
          },
        ));

    return _iniciarSesionCon(res, persistSession);
  }

  /// Inicia sesión con un `id_token` que ya obtuvo el SDK nativo.
  ///
  /// Es el equivalente de `signInWithIdToken` de Supabase, y el camino que
  /// mejor encaja en una app: `google_sign_in` devuelve el `idToken`, se manda
  /// aquí y se acabó. Sin navegador, sin ventana emergente, sin esquema de URL
  /// personalizado y sin retorno que enrutar.
  ///
  /// ```dart
  /// final cuenta = await GoogleSignIn().signIn();
  /// final auth = await cuenta!.authentication;
  /// final user = await db.signInWithIdToken(
  ///   provider: 'google',
  ///   idToken: auth.idToken!,
  /// );
  /// ```
  ///
  /// [nonce] es el que se pidió al SDK nativo. Mándalo si lo usaste: el
  /// servidor comprueba que coincida, que es lo que impide reutilizar un
  /// `id_token` capturado.
  ///
  /// Solo vale para proveedores OIDC —Google y Microsoft—. GitHub es OAuth2 y
  /// no emite `id_token`, así que responde `400`.
  ///
  /// Lanza [RobleApiConflictException] si el proveedor no certifica el correo
  /// y ese correo ya tiene cuenta.
  Future<Map<String, dynamic>> signInWithIdToken({
    required String provider,
    required String idToken,
    String? nonce,
    bool persistSession = true,
  }) async {
    if (idToken.isEmpty) {
      throw ArgumentError.value(idToken, 'idToken', 'No puede estar vacío');
    }

    final res = await _traduciendoConflicto(() => _makeRequest(
          'POST',
          'auth/id-token',
          isAuthRequest: true,
          skipAuth: true,
          body: {
            'provider': provider,
            'token': idToken,
            if (nonce != null) 'nonce': nonce,
          },
        ));

    return _iniciarSesionCon(res, persistSession);
  }

  // ============================================================
  // ============= TIEMPO REAL ==================================
  // ============================================================

  RobleRealtimeClient? _realtime;

  /// Cliente de tiempo real, creado la primera vez que se usa.
  RobleRealtimeClient get realtime {
    return _realtime ??= RobleRealtimeClient(
      // El socket cuelga del host, no de la ruta del contrato: socket.io
      // negocia por `/socket.io` y el proyecto viaja en el query.
      origin: Uri.parse(config.realtimeUrl).origin,
      dbName: config.realtimeUrl.split('/').last,
      accessToken: () => _accessToken,
      socketFactory: socketFactory,
    );
  }

  RobleJsonDb? _json;

  /// Base de datos JSON del proyecto: un arbol sin esquema, al estilo de
  /// Firebase Realtime Database.
  ///
  /// Es la alternativa a [watchTable] cuando los datos no merecen una tabla:
  /// aqui la estructura se crea al escribir y el arbol no vive en el esquema
  /// del proyecto.
  ///
  /// ```dart
  /// await db.json.push('mensajes', {'texto': 'hola'});
  /// db.json.watch('mensajes').listen(pintar);
  /// ```
  RobleJsonDb get json {
    return _json ??= RobleJsonDb(
      realtime: realtime,
      request: (method, path, {body, queryParams}) => _makeRequest(
        method,
        path,
        body: body,
        queryParams: queryParams,
        baseUrlOverride: config.realtimeUrl,
      ),
    );
  }

  /// `{host}/realtime/config/{contrato}`, de donde cuelgan las politicas.
  ///
  /// No es `realtimeUrl`: ese apunta a `/realtime/{contrato}` y la
  /// configuracion vive un nivel antes, bajo `/realtime/config`.
  String get _policyBaseUrl {
    final uri = Uri.parse(config.realtimeUrl);
    return '${uri.origin}/realtime/config/${config.realtimeUrl.split('/').last}';
  }

  /// Politicas de tiempo real del proyecto, una por tabla configurada.
  ///
  /// Una tabla que no aparezca aqui no esta sin tiempo real: sin politica emite
  /// a cualquiera con sesion. La politica sirve para restringir o apagar.
  Future<List<RobleTablePolicy>> realtimePolicies() async {
    final res = await _makeRequest(
      'GET',
      'policies',
      baseUrlOverride: _policyBaseUrl,
    );

    if (res is List) {
      return res
          .whereType<Map>()
          .map(RobleTablePolicy.fromJson)
          .toList(growable: false);
    }
    throw const RobleApiFormatException(
        'Respuesta inesperada al listar las politicas de tiempo real.');
  }

  /// La politica de una tabla, o `null` si no tiene ninguna.
  Future<RobleTablePolicy?> realtimePolicy(
    String tableName, {
    String schema = 'public',
  }) async {
    final res = await _makeRequest(
      'GET',
      'policies/$schema/$tableName',
      baseUrlOverride: _policyBaseUrl,
    );

    if (res == null || (res is String && res.isEmpty)) return null;
    if (res is Map) return RobleTablePolicy.fromJson(res);
    throw const RobleApiFormatException(
        'Respuesta inesperada al leer la politica de tiempo real.');
  }

  /// Crea o reemplaza la politica de una tabla.
  ///
  /// ```dart
  /// await db.setRealtimePolicy(const RobleTablePolicy(
  ///   table: 'orders',
  ///   enabled: true,
  ///   events: [RobleChangeType.insert, RobleChangeType.update],
  ///   access: RobleRealtimeAccess.authenticated,
  /// ));
  /// ```
  ///
  /// Reemplaza, no combina: lo que no se indique vuelve a su valor por
  /// omision. Para cambiar un campo suelto, lee con [realtimePolicy] primero.
  Future<RobleTablePolicy> setRealtimePolicy(RobleTablePolicy policy) async {
    final res = await _makeRequest(
      'PUT',
      'policies/${policy.schema}/${policy.table}',
      baseUrlOverride: _policyBaseUrl,
      body: policy.toJson(),
    );

    if (res is Map) return RobleTablePolicy.fromJson(res);
    throw const RobleApiFormatException(
        'Respuesta inesperada al guardar la politica de tiempo real.');
  }

  /// Deja una tabla muda.
  ///
  /// El servidor no borra la fila, la marca deshabilitada, asi que volver a
  /// habilitarla con [setRealtimePolicy] es un cambio y no un alta.
  Future<void> disableRealtime(
    String tableName, {
    String schema = 'public',
  }) async {
    await _makeRequest(
      'DELETE',
      'policies/$schema/$tableName',
      baseUrlOverride: _policyBaseUrl,
    );
  }

  /// Escucha los cambios de una tabla entera.
  ///
  /// Devuelve un stream que emite un [RobleChange] por cada fila insertada,
  /// modificada o borrada. La suscripcion se pide al empezar a escuchar y se
  /// cancela sola al cerrar el `StreamSubscription`.
  ///
  /// ```dart
  /// final sub = db.watchTable('products').listen((change) {
  ///   switch (change.type) {
  ///     case RobleChangeType.insert: agregar(change.record!);
  ///     case RobleChangeType.update: reemplazar(change.record!);
  ///     case RobleChangeType.delete: quitar(change.id!);
  ///   }
  /// });
  ///
  /// await sub.cancel(); // deja de escuchar y avisa al servidor
  /// ```
  ///
  /// [events] limita a que operaciones. Por omision, las tres.
  ///
  /// [filters] los aplica el servidor antes de mandar nada, asi que filtrar
  /// aqui ahorra el viaje de todo lo que no interesa.
  ///
  /// Hace falta sesion iniciada: el socket lleva el access token y el servidor
  /// comprueba que el proyecto del token sea este.
  ///
  /// El stream **no** trae el estado actual de la tabla, solo lo que cambie a
  /// partir de ahora. Para pintar la lista completa, lee con [read] y aplica
  /// encima lo que vaya llegando.
  @Deprecated(
    'El tiempo real de Roble escucha colecciones del arbol JSON, no tablas '
    'SQL. El servidor rechaza estas suscripciones con '
    'REALTIME_UNKNOWN_COLLECTION, asi que ya no entregan nada: usa '
    'db.json.watch sobre la coleccion correspondiente. Se retira en una '
    'version mayor futura.',
  )
  Stream<RobleChange> watchTable(
    String tableName, {
    List<RobleChangeType>? events,
    List<RobleFilter> filters = const [],
  }) {
    return realtime.watch(tableName, events: events, filters: filters);
  }

  /// Escucha los cambios de un registro concreto, por su `_id`.
  ///
  /// ```dart
  /// db.watchRecord('products', id).listen((change) {
  ///   if (change.type == RobleChangeType.delete) {
  ///     cerrarPantalla();
  ///   } else {
  ///     mostrar(change.record!);
  ///   }
  /// });
  /// ```
  ///
  /// Es [watchTable] con un filtro por clave primaria, que el servidor evalua
  /// antes de mandar: el resto de filas de la tabla no llegan siquiera.
  @Deprecated(
    'Va sobre watchTable, asi que hereda su final: el servidor solo emite '
    'colecciones del arbol JSON. Usa db.json.watch sobre la ruta del nodo que '
    'te interese. Se retira en una version mayor futura.',
  )
  Stream<RobleChange> watchRecord(
    String tableName,
    Object id, {
    List<RobleChangeType>? events,
  }) {
    return realtime.watch(
      tableName,
      events: events,
      filters: [RobleFilter.equals('_id', id)],
    );
  }

  /// Comprueba `extra` contra lo que el servidor va a rechazar.
  ///
  /// Vale más fallar aquí, con el nombre de la clave culpable, que enterarse
  /// por un `400` a mitad del flujo de OAuth.
  void _validarSocialExtra(Map<String, dynamic> extra) {
    _checkExtraKeys(extra, const []);

    final String encoded;
    try {
      encoded = jsonEncode(extra);
    } catch (e) {
      throw ArgumentError.value(
        extra,
        'extra',
        'No se puede convertir a JSON: $e',
      );
    }

    // El límite es del `extra` serializado, lo mida quien lo mida: ahora viaja
    // en el cuerpo, pero el servidor sigue aplicando el mismo tope.
    final bytes = utf8.encode(encoded).length;
    if (bytes > _extraMaxBytes) {
      throw ArgumentError.value(
        extra,
        'extra',
        'Ocupa $bytes bytes serializado y el máximo son $_extraMaxBytes',
      );
    }
  }

  /// Recorre `extra` en profundidad buscando claves reservadas.
  void _checkExtraKeys(Object? node, List<String> path) {
    if (node is Map) {
      for (final entry in node.entries) {
        final key = '${entry.key}';
        if (_extraForbiddenKeys.contains(key)) {
          final donde = path.isEmpty ? '' : ' (en ${path.join('.')})';
          throw ArgumentError.value(
            key,
            'extra',
            'Roble reserva la clave "$key"$donde; elige otro nombre',
          );
        }
        _checkExtraKeys(entry.value, [...path, key]);
      }
    } else if (node is List) {
      for (var i = 0; i < node.length; i++) {
        _checkExtraKeys(node[i], [...path, '[$i]']);
      }
    }
  }

  /// Refresca el access token con el refresh token almacenado.
  ///
  /// Es interno a propósito: se invoca automáticamente cuando una petición
  /// de datos responde `401`. No forma parte de la API pública.
  Future<void> _refreshAccessToken() async {
    if (_refreshToken == null) {
      throw const RobleApiAuthException('No hay refresh token disponible.');
    }

    final res = await _makeRequest(
      'POST',
      'refresh-token',
      body: {'refreshToken': _refreshToken},
      isAuthRequest: true,
    );

    if (res is Map && res.containsKey('accessToken')) {
      // Hoy el servidor solo devuelve accessToken, pero si algún día rota el
      // refresh token no hay que perderlo.
      final rotated = res['refreshToken'] as String?;
      if (rotated != null) _refreshToken = rotated;

      _updateAccessToken(res['accessToken'] as String?);
    } else {
      throw const RobleApiAuthException(
          'Respuesta inválida al refrescar el token.');
    }
  }

  // ============================================================
  // ============= DATOS ========================================
  // ============================================================

  /// Inserta un registro y devuelve la fila creada, con su `_id`.
  ///
  /// Usa `/insert-one`, que devuelve el registro directamente. Si el servidor
  /// rechaza la fila, responde con un error HTTP en lugar de un `200` vacío.
  Future<Map<String, dynamic>> create(
      String tableName, Map<String, dynamic> data) async {
    final res = await _makeRequest(
      'POST',
      'insert-one',
      body: {'tableName': tableName, 'record': data},
    );

    if (res is Map) return Map<String, dynamic>.from(res);
    throw const RobleApiFormatException('No se pudo insertar el registro');
  }

  /// Inserta varios registros.
  ///
  /// El servidor responde `200` aunque rechace parte de los registros, así que
  /// el resultado expone [RobleInsertResult.skipped]. Revísalo siempre:
  ///
  /// ```dart
  /// final res = await db.createMany('usuarios', registros);
  /// if (res.hasSkipped) {
  ///   for (final s in res.skipped) {
  ///     print('Fila ${s.index} rechazada: ${s.reason}');
  ///   }
  /// }
  /// ```
  Future<RobleInsertResult> createMany(
    String tableName,
    List<Map<String, dynamic>> records, {
    bool strict = false,
  }) async {
    final res = await _makeRequest(
      'POST',
      'insert',
      body: {'tableName': tableName, 'records': records},
    );

    if (res is! Map) {
      throw const RobleApiFormatException(
          'Respuesta inesperada al insertar registros');
    }

    final result = RobleInsertResult.fromJson(res);

    // Con `strict` el rechazo parcial deja de ser algo que haya que recordar
    // mirar: se convierte en un error.
    if (strict && result.hasSkipped) {
      throw RoblePartialInsertException(result);
    }

    return result;
  }

  Future<List<Map<String, dynamic>>> read(String tableName,
      {Map<String, dynamic>? filters}) async {
    final queryParams = <String, String>{'tableName': tableName};
    if (filters != null) {
      filters.forEach((k, v) => queryParams[k] = v.toString());
    }

    final res = await _makeRequest('GET', 'read', queryParams: queryParams);
    if (res is List) return List<Map<String, dynamic>>.from(res);
    if (res is Map && res.containsKey('data')) {
      return List<Map<String, dynamic>>.from(res['data']);
    }
    return [];
  }

  Future<Map<String, dynamic>> update(
      String tableName, dynamic id, Map<String, dynamic> data) async {
    final updateData = Map<String, dynamic>.from(data)
      ..remove('_id')
      ..remove('id');

    final res = await _makeRequest(
      'PUT',
      'update',
      body: {
        'tableName': tableName,
        'idColumn': '_id',
        'idValue': id,
        'updates': updateData,
      },
    );
    return (res is Map) ? Map<String, dynamic>.from(res) : {};
  }

  Future<Map<String, dynamic>> delete(String tableName, dynamic id) async {
    final res = await _makeRequest(
      'DELETE',
      'delete',
      body: {
        'tableName': tableName,
        'idColumn': '_id',
        'idValue': id,
      },
    );
    return (res is Map) ? Map<String, dynamic>.from(res) : {};
  }

  /// Lee una tabla marcada como pública, sin autenticación.
  ///
  /// Un `403` significa que la tabla no está configurada como pública en la
  /// consola de Roble, no que el token sea inválido.
  Future<List<Map<String, dynamic>>> publicRead(String tableName,
      {Map<String, dynamic>? filters}) async {
    final queryParams = <String, String>{'tableName': tableName};
    if (filters != null) {
      filters.forEach((k, v) => queryParams[k] = v.toString());
    }

    final res = await _makeRequest(
      'GET',
      'public-read',
      queryParams: queryParams,
      skipAuth: true,
    );

    if (res is List) return List<Map<String, dynamic>>.from(res);
    if (res is Map && res['data'] is List) {
      return List<Map<String, dynamic>>.from(res['data'] as List);
    }
    return [];
  }

  /// Ejecuta una consulta guardada previamente en la consola de Roble.
  ///
  /// Es la vía para joins, agregados, ordenamiento y paginación: [read] solo
  /// admite filtros de igualdad. [id] es el UUID de la consulta guardada.
  Future<RobleQueryResult> executeQuery(String id,
      {List<dynamic>? params}) async {
    final res = await _makeRequest(
      'POST',
      'execute-query',
      body: {
        'id': id,
        if (params != null) 'params': params,
      },
    );

    if (res is Map) return RobleQueryResult.fromJson(res);
    throw const RobleApiFormatException(
        'Respuesta inesperada al ejecutar la consulta');
  }

  /// Ejecuta una consulta guardada por su **nombre** en vez de por su UUID.
  ///
  /// `POST /saved-queries/by-name/{name}/execute`. Hace lo mismo que
  /// [executeQuery], pero el nombre se lee en la consola de Roble y sobrevive
  /// a recrear la consulta, mientras que el UUID cambia.
  ///
  /// ```dart
  /// final res = await db.executeQueryByName('ranking_mensual');
  /// for (final fila in res.rows) print(fila);
  /// ```
  ///
  /// [name] se escapa solo, así que puede llevar espacios o acentos.
  ///
  /// Lanza [ArgumentError] si [name] está vacío, y
  /// [RobleApiHttpException] si el servidor no encuentra la consulta.
  Future<RobleQueryResult> executeQueryByName(String name,
      {List<dynamic>? params}) async {
    final limpio = name.trim();
    if (limpio.isEmpty) {
      throw ArgumentError.value(
        name,
        'name',
        'No puede estar vacío. Es el nombre que le diste a la consulta en la '
            'consola de Roble',
      );
    }

    final res = await _makeRequest(
      'POST',
      'saved-queries/by-name/${Uri.encodeComponent(limpio)}/execute',
      body: {
        if (params != null) 'params': params,
      },
    );

    if (res is Map) return RobleQueryResult.fromJson(res);
    throw const RobleApiFormatException(
        'Respuesta inesperada al ejecutar la consulta');
  }

  /// Devuelve el registro con ese `_id`, o `null` si no existe.
  ///
  /// ```dart
  /// final usuario = await db.getById('usuarios', 'customid1234');
  /// if (usuario == null) mostrarNoEncontrado();
  /// ```
  Future<Map<String, dynamic>?> getById(String tableName, dynamic id) async {
    final results = await read(tableName, filters: {'_id': id});
    return results.isNotEmpty ? results.first : null;
  }
}
