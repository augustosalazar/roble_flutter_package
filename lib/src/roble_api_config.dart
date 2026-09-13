/// Configuración del cliente Roble.
///
/// Se crea siempre con [RobleApiConfig.fromContract], que compone las rutas
/// `/auth` y `/database` a partir del host y del identificador del contrato:
///
/// ```dart
/// final config = RobleApiConfig.fromContract(
///   baseUrl: 'https://roble-api.test-openlab.uninorte.edu.co',
///   contractId: 'tu_contrato',
/// );
/// ```
class RobleApiConfig {
  /// URL base para endpoints de autenticación (login, signup, refresh, etc.).
  final String authUrl;

  /// URL base para endpoints de datos (CRUD, tablas, etc.).
  final String dataUrl;

  /// URL base del servicio Realtime (`{host}/realtime/{contractId}`).
  ///
  /// Reservada: el servicio Realtime todavía no forma parte de la API pública.
  final String realtimeUrl;

  /// Tiempo máximo de espera por petición. Por defecto 30 segundos.
  final Duration timeout;

  /// Timeout usado cuando no se especifica ninguno.
  static const Duration defaultTimeout = Duration(seconds: 30);

  /// Clave publicable del proyecto (`roble_anon_…`): el modo sin sesión.
  ///
  /// Con esto el cliente **sólo puede insertar**, y sólo en las tablas que el
  /// proyecto haya marcado. Todo lo demás —leer, actualizar, borrar, el árbol
  /// JSON, los archivos, el tiempo real, iniciar sesión— falla en el cliente
  /// con [RobleAnonKeyScopeException], sin salir a la red.
  ///
  /// Está pensada para ir dentro de la app: un formulario de contacto, un
  /// buzón de sugerencias, una encuesta. **Es pública por diseño** — quien
  /// desensamble el binario la va a ver, y eso no es una filtración. Lo que la
  /// hace segura es que no puede leer nada.
  ///
  /// Las filas que escribe no tienen dueño, así que nadie con alcance `own`
  /// podrá editarlas ni borrarlas después.
  final String? anonKey;

  const RobleApiConfig._({
    required this.authUrl,
    required this.dataUrl,
    required this.realtimeUrl,
    required this.timeout,
    this.anonKey,
  });

  /// Crea la configuración a partir del host y del identificador del contrato.
  ///
  /// | Parámetro | Descripción |
  /// | --- | --- |
  /// | [baseUrl] | Host de la API. Una barra final se ignora. |
  /// | [contractId] | Identificador del contrato. |
  /// | [realtimeBaseUrl] | Host del servicio Realtime. Reservado para cuando Realtime pase a ser público; si se omite se usa [baseUrl]. |
  /// | [timeout] | Tiempo máximo por petición. |
  ///
  /// ```dart
  /// final config = RobleApiConfig.fromContract(
  ///   baseUrl: 'https://roble-api.test-openlab.uninorte.edu.co',
  ///   contractId: 'tu_contrato',
  ///   realtimeBaseUrl: 'https://roble-realtime.test-openlab.uninorte.edu.co',
  /// );
  /// // authUrl     -> https://roble-api…/auth/tu_contrato
  /// // dataUrl     -> https://roble-api…/database/tu_contrato
  /// // realtimeUrl -> https://roble-realtime…/realtime/tu_contrato
  /// ```
  /// Lanza [ArgumentError] si [baseUrl] no es una URL o si [contractId] está
  /// vacío o sigue siendo un valor de ejemplo.
  factory RobleApiConfig.fromContract({
    required String baseUrl,
    required String contractId,
    String? realtimeBaseUrl,
    Duration timeout = defaultTimeout,
    String? anonKey,
  }) {
    // Fallar aquí, y no con un 500 críptico en la primera petición.
    if (!baseUrl.startsWith('http')) {
      throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        'Debe empezar por http:// o https://',
      );
    }

    final id = contractId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(
        contractId,
        'contractId',
        'No puede estar vacío. Es el identificador del proyecto en la consola '
            'de Roble, algo como "miproyecto_ab12cd34ef"',
      );
    }
    if (id == 'tu_contrato' || id == 'mi_contrato' || id.contains(' ')) {
      throw ArgumentError.value(
        contractId,
        'contractId',
        'No parece un contrato real. Cópialo de la consola de Roble',
      );
    }

    final key = anonKey?.trim();
    if (key != null) {
      // Pegar aquí un token de sesión o un PAT es el error previsible, y el
      // síntoma sería un 401 en la primera inserción. Se dice al construir.
      if (key.startsWith('roble_pat_')) {
        throw ArgumentError.value(
          anonKey,
          'anonKey',
          'Es un token de acceso de proyecto (roble_pat_…): un secreto de '
              'servidor que no debe ir en una app. La clave publicable empieza '
              'por roble_anon_ y se emite en la consola del proyecto.',
        );
      }
      if (!RegExp(r'^roble_anon_[0-9a-f]{16}_[A-Za-z0-9_-]{43}$').hasMatch(key)) {
        throw ArgumentError.value(
          anonKey,
          'anonKey',
          'No tiene la forma de una clave publicable de Roble '
              '(roble_anon_<id>_<secreto>). Cópiala de la consola del proyecto.',
        );
      }
    }

    String trim(String url) =>
        url.endsWith('/') ? url.substring(0, url.length - 1) : url;

    final host = trim(baseUrl);
    final realtimeHost = trim(realtimeBaseUrl ?? baseUrl);

    return RobleApiConfig._(
      authUrl: '$host/auth/$contractId',
      dataUrl: '$host/database/$contractId',
      realtimeUrl: '$realtimeHost/realtime/$contractId',
      timeout: timeout,
      anonKey: key,
    );
  }

  @override
  String toString() =>
      'RobleApiConfig(authUrl: $authUrl, dataUrl: $dataUrl, '
      'realtimeUrl: $realtimeUrl, timeout: $timeout)';
}
