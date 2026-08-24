import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'roble_api_config.dart';
import 'roble_api_exception.dart';
import 'roble_models.dart';
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

  late final String _storageKey =
      'roble.session.${config.authUrl.split('/').last}';

  /// Destino de retorno del login social al que vuelve **esta** app, por su
  /// nombre en la consola de Roble. `null` usa el llamado `default`.
  ///
  /// Es una constante de la app, no de cada llamada: la versión web siempre
  /// vuelve al destino web y la de móvil al de móvil. Se fija una vez aquí y
  /// [socialLoginUrl] lo usa solo.
  final String? ssoRedirect;

  /// Cómo se abre el proveedor en el login social. `null` usa la ventana
  /// emergente de web, que fuera de web lanza pidiendo que pongas la tuya.
  ///
  /// Se fija una vez aquí, como [ssoRedirect], porque es una constante de la
  /// app: cada plataforma abre el proveedor siempre igual.
  final RobleSocialOpener? socialOpener;

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
  })  : _client = client ?? http.Client(),
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
    return Uri.parse('$baseUrl/$endpoint')
        .replace(queryParameters: queryParams);
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

  /// `{host}/auth`, sin el contrato: los endpoints de intercambio cuelgan de
  /// ahí, porque Roble deduce el proyecto del `state` de OAuth.
  String get _authBaseUrl =>
      config.authUrl.substring(0, config.authUrl.lastIndexOf('/'));

  /// Consulta si un proveedor está disponible en este proyecto.
  ///
  /// El endpoint es público: no hace falta sesión. Úsalo para ocultar o
  /// deshabilitar el botón antes de que el usuario lo pulse, porque arrancar
  /// el flujo con un proveedor apagado responde `403`.
  ///
  /// ```dart
  /// final google = await db.socialConfig(RobleSocialProvider.google);
  /// if (google.enabled) mostrarBotonGoogle();
  /// ```
  Future<RobleSocialConfig> socialConfig(RobleSocialProvider provider) async {
    final res = await _makeRequest(
      'GET',
      '${provider.name}-config',
      isAuthRequest: true,
      skipAuth: true,
    );

    if (res is Map) return RobleSocialConfig.fromJson(res);
    throw const RobleApiFormatException(
        'Respuesta inesperada al consultar la configuración del proveedor.');
  }

  /// URL con la que arranca el inicio de sesión de [provider].
  ///
  /// **No es una petición HTTP**: hay que *navegar* a ella. En web, cambiando
  /// la ubicación del documento; en móvil y escritorio, abriéndola en el
  /// navegador del sistema. El paquete no la abre por ti para no imponerte
  /// una dependencia de `url_launcher`.
  ///
  /// ```dart
  /// final url = db.socialLoginUrl(RobleSocialProvider.google);
  /// await launchUrl(url, mode: LaunchMode.externalApplication);
  /// ```
  ///
  /// [redirect] elige a cuál de los **destinos de retorno** configurados en la
  /// consola debe volver el usuario, por su nombre. Normalmente no se pasa: se
  /// fija una vez con `ssoRedirect` al crear el cliente, y esto es solo para
  /// desviar una llamada concreta. Si no hay ninguno de los dos, Roble usa el
  /// destino llamado `default`.
  ///
  /// Un proyecto sin destinos configurados no puede arrancar el flujo:
  /// responde `400`.
  ///
  /// [extra] son campos adicionales que se guardan en el perfil del usuario
  /// (los existentes se conservan; los que coincidan se sobrescriben). Viaja
  /// **en la URL**, así que no pongas nada secreto ahí.
  ///
  /// Lanza [ArgumentError] si [redirect] está vacío, si [extra] pasa de 4 KB
  /// serializado, si no es convertible a JSON, o si usa alguna clave reservada
  /// por Roble —`role`, `isAdmin`, `userId`, `permissions`…— a cualquier nivel
  /// de anidamiento.
  Uri socialLoginUrl(
    RobleSocialProvider provider, {
    Map<String, dynamic>? extra,
    String? redirect,
  }) {
    final uri = Uri.parse('${config.authUrl}/${provider.name}');
    final query = <String, String>{};

    // El de la llamada manda; si no, el de la app.
    final destino = _validarRedirect(redirect, 'redirect') ?? ssoRedirect;
    if (destino != null) query['redirect'] = destino;

    if (extra != null && extra.isNotEmpty) {
      query['extra'] = _encodeSocialExtra(extra);
    }

    return query.isEmpty ? uri : uri.replace(queryParameters: query);
  }

  /// Inicia sesión con [provider] en una ventana, sin descargar la app.
  ///
  /// Es el camino corto: abre el proveedor, espera el retorno y devuelve el
  /// perfil, igual que [login]. No hay que tocar la URL de arranque ni el
  /// enrutado, porque la app principal nunca se recarga.
  ///
  /// ```dart
  /// ElevatedButton(
  ///   onPressed: () async {
  ///     final user = await db.signInWithProvider(RobleSocialProvider.google);
  ///   },
  ///   child: const Text('Entrar con Google'),
  /// )
  /// ```
  ///
  /// **Llámalo directamente desde el gesto del usuario.** Si haces cualquier
  /// `await` antes, el navegador bloquea la ventana y esto lanza
  /// [RobleApiAuthException] diciéndolo.
  ///
  /// Requiere que el destino de retorno devuelva la URL a la ventana que abrió
  /// el proceso; el README trae el fragmento de `index.html` que lo hace.
  ///
  /// [extra] y [persistSession] hacen lo mismo que en [socialLoginUrl] y
  /// [login]. [timeout] es lo que se espera antes de rendirse.
  ///
  /// **Fuera de web hay que dar [opener]** —o fijarlo una vez como
  /// `socialOpener` al crear el cliente—, porque ahí no hay ventana emergente
  /// que valga. Sin él lanza [RobleApiAuthException] explicándolo. Así el
  /// paquete no obliga a nadie a cargar con un plugin nativo: ver
  /// [RobleSocialOpener].
  ///
  /// Lanza [RobleApiAuthException] si la ventana se bloquea, si el usuario la
  /// cierra o si se agota [timeout]; y lo mismo que [completeSocialLogin] si
  /// el canje falla.
  Future<Map<String, dynamic>> signInWithProvider(
    RobleSocialProvider provider, {
    Map<String, dynamic>? extra,
    bool persistSession = true,
    Duration timeout = const Duration(minutes: 5),
    RobleSocialOpener? opener,
  }) async {
    // El de la llamada manda; si no, el de la app; si no, la ventana de web.
    final abrir = opener ?? socialOpener ?? awaitSocialCallback;

    final callback = await abrir(socialLoginUrl(provider, extra: extra), timeout);

    return completeSocialLogin(callback, persistSession: persistSession);
  }

  /// `true` si [url] es un retorno del login social.
  ///
  /// Para no repartir por la app el conocimiento de que el retorno se
  /// reconoce por un `?code=`:
  ///
  /// ```dart
  /// // Al arrancar, en web.
  /// if (db.isSocialCallback(Uri.base)) {
  ///   await db.completeSocialLogin(Uri.base);
  /// }
  /// ```
  ///
  /// Solo mira que haya `code`, no que el retorno sea válido del todo: un
  /// `provider` ausente o desconocido lo diagnostica [completeSocialLogin] con
  /// un mensaje concreto, que es más útil que ignorar la URL en silencio.
  bool isSocialCallback(Uri url) =>
      url.queryParameters['code']?.isNotEmpty ?? false;

  /// Termina el inicio de sesión a partir de la URL de retorno.
  ///
  /// Cuando el proveedor acaba, Roble redirige el navegador al `doneUrl` del
  /// proyecto con `?code=…&provider=…`. Pásale esa URL entera y este método
  /// canjea el código, guarda la sesión y devuelve el perfil, igual que
  /// [login].
  ///
  /// ```dart
  /// // En Flutter web, al arrancar la app:
  /// if (Uri.base.queryParameters.containsKey('code')) {
  ///   final user = await db.completeSocialLogin(Uri.base);
  /// }
  /// ```
  ///
  /// [persistSession] hace lo mismo que en [login].
  ///
  /// **El código dura 60 segundos y es de un solo uso.** Reutilizarlo o
  /// tardar más devuelve [RobleApiHttpException] con `400` y el mensaje
  /// «Código inválido o expirado»; en ese caso hay que rehacer el flujo desde
  /// [socialLoginUrl].
  ///
  /// Lanza [RobleApiAuthException] si la URL no trae `code`, o si `provider`
  /// falta o no es uno de los soportados.
  Future<Map<String, dynamic>> completeSocialLogin(
    Uri callbackUrl, {
    bool persistSession = true,
  }) async {
    final code = callbackUrl.queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw const RobleApiAuthException(
          'La URL de retorno no trae el parámetro "code". Compruébala: debe '
          'ser la que Roble abrió tras el proveedor, con ?code=…&provider=…');
    }

    final providerName = callbackUrl.queryParameters['provider'];
    final provider = RobleSocialProvider.values.firstWhere(
      (p) => p.name == providerName,
      orElse: () => throw RobleApiAuthException(
        'Proveedor no soportado en la URL de retorno: '
        '${providerName ?? 'ninguno'}. Se esperaba "google" o "microsoft"',
      ),
    );

    // El intercambio no lleva bearer y cuelga de /auth, sin el contrato.
    final res = await _makeRequest(
      'POST',
      '${provider.name}/exchange',
      body: {'code': code},
      baseUrlOverride: _authBaseUrl,
      skipAuth: true,
    );

    _persistTokens = persistSession;
    // Si esta vez no se quiere recordar la sesión, se borra la anterior.
    if (!persistSession) await _forgetStoredSession();

    if (res is Map) {
      _refreshToken = res['refreshToken'] as String?;
      _updateAccessToken(res['accessToken'] as String?);
    }

    if (!isLoggedIn) {
      throw const RobleApiFormatException(
          'El intercambio no devolvió un access token.');
    }

    // Se pide el perfil a /me para devolver la misma forma que login().
    return await currentUser();
  }

  /// Serializa `extra` comprobando antes lo que el servidor va a rechazar.
  ///
  /// Vale más fallar aquí, con el nombre de la clave culpable, que enterarse
  /// por un `400` a mitad del flujo de OAuth.
  String _encodeSocialExtra(Map<String, dynamic> extra) {
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

    final bytes = utf8.encode(encoded).length;
    if (bytes > _extraMaxBytes) {
      throw ArgumentError.value(
        extra,
        'extra',
        'Ocupa $bytes bytes serializado y el máximo son $_extraMaxBytes',
      );
    }

    return encoded;
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
