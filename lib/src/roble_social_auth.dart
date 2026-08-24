/// Inicio de sesión con proveedores externos (Google y Microsoft).
///
/// En Roble el login social **también es registro**: un correo nuevo crea un
/// usuario ya verificado, y un correo existente enlaza la identidad del
/// proveedor con ese usuario. Por eso no hay un `signUpWithGoogle` aparte.
library;

/// Abre el proveedor y devuelve la URL de retorno con la que volvió.
///
/// Es el único paso del login social que depende de la plataforma, y el paquete
/// no lo decide por ti: en web trae una implementación con ventana emergente, y
/// en móvil o escritorio le pasas la tuya —con `flutter_web_auth_2`, con un
/// listener de deep links, con lo que uses— sin que `roble` herede ninguna
/// dependencia nativa.
///
/// Debe devolver la URL completa del retorno, la que trae `?code=…&provider=…`.
///
/// ```dart
/// await db.signInWithProvider(
///   RobleSocialProvider.google,
///   opener: (loginUrl, timeout) async => Uri.parse(
///     await FlutterWebAuth2.authenticate(
///       url: loginUrl.toString(),
///       callbackUrlScheme: 'miapp',
///     ),
///   ),
/// );
/// ```
typedef RobleSocialOpener = Future<Uri> Function(Uri loginUrl, Duration timeout);

/// Proveedores de identidad soportados.
///
/// El `name` de cada valor (`google`, `microsoft`) es el mismo identificador
/// que usan las rutas de la API y el parámetro `provider` de la URL de
/// retorno.
enum RobleSocialProvider { google, microsoft }

/// Estado de un proveedor en el proyecto, tal como lo devuelve
/// `GET /{provider}-config`.
///
/// Sirve para decidir si se pinta el botón de "Entrar con…" antes de iniciar
/// nada: si [enabled] es `false`, arrancar el flujo daría un `403`.
class RobleSocialConfig {
  /// `true` si el proveedor está configurado y activo en el proyecto.
  final bool enabled;

  /// Identificador de cliente registrado en la consola del proveedor.
  final String? clientId;

  /// Directorio de Microsoft. Siempre `null` en Google.
  final String? tenantId;

  const RobleSocialConfig({
    required this.enabled,
    this.clientId,
    this.tenantId,
  });

  factory RobleSocialConfig.fromJson(Map<dynamic, dynamic> json) {
    return RobleSocialConfig(
      enabled: json['enabled'] == true,
      clientId: json['clientId'] as String?,
      tenantId: json['tenantId'] as String?,
    );
  }

  @override
  String toString() =>
      'RobleSocialConfig(enabled: $enabled, clientId: $clientId, '
      'tenantId: $tenantId)';
}

/// Un proveedor habilitado en el proyecto, tal como lo devuelve
/// `GET /{contrato}/auth/providers`.
///
/// Es el reemplazo de [RobleSocialConfig]: una sola llamada devuelve todos los
/// proveedores activos, así que añadir uno nuevo en el servidor no obliga a
/// tocar la app. Tampoco expone el `clientId`, que la app nunca necesitó.
class RobleProviderInfo {
  /// Identificador estable: `google`, `microsoft`, `github`…
  final String name;

  /// Nombre para mostrar en el botón.
  final String displayName;

  /// `true` si el proveedor certifica que el correo está verificado.
  ///
  /// Cuando es `false`, entrar con ese proveedor usando un correo que ya tiene
  /// cuenta responde `409` ([RobleApiConflictException]) en vez de vincularse
  /// solo. Conviene avisarlo en la interfaz antes, no después.
  final bool autoLinkSupported;

  const RobleProviderInfo({
    required this.name,
    required this.displayName,
    required this.autoLinkSupported,
  });

  factory RobleProviderInfo.fromJson(Map<dynamic, dynamic> json) {
    return RobleProviderInfo(
      name: json['name'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      autoLinkSupported: json['autoLinkSupported'] == true,
    );
  }

  @override
  String toString() => 'RobleProviderInfo(name: $name, '
      'displayName: $displayName, autoLinkSupported: $autoLinkSupported)';
}
