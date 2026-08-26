import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_sign_in/google_sign_in.dart';

/// Obtiene un `id_token` de Google para canjearlo en Roble.
///
/// Detras de una interfaz porque no habla con Roble: su unico trabajo es
/// conseguir la credencial que Roble valida despues. Asi se sustituye por un
/// doble en pruebas sin tocar nada nativo.
abstract class RobleIdTokenSource {
  /// `true` si esta plataforma puede pedir el token de forma nativa.
  bool get isSupported;

  /// Abre el selector de cuentas y devuelve el `id_token`.
  ///
  /// Devuelve `null` si la persona cancela, que no es un error.
  ///
  /// [serverClientId] es el Client ID **web** configurado en la consola de
  /// Roble: es la audiencia para la que Google emite el token y la que el
  /// servidor comprueba al validarlo.
  ///
  /// [nonce] viaja hasta Google y vuelve dentro del token; quien lo llame debe
  /// mandarle a Roble el mismo valor.
  Future<String?> idToken({required String serverClientId, String? nonce});

  /// Olvida la cuenta elegida, para que el proximo intento vuelva a preguntar.
  Future<void> signOut();
}

/// Implementacion con `google_sign_in`, el SDK nativo de Google.
///
/// El Client ID **web** no se configura aqui: lo trae Roble en `listProviders`,
/// asi que la consola es el unico sitio donde se define el proveedor. Cuando la
/// app llevaba su propia copia, las dos podian separarse: el token se emitia
/// para una audiencia y Roble esperaba otra, y eso sale como un 401 que parece
/// un problema del token y no de la configuracion.
class RobleGoogleSignIn implements RobleIdTokenSource {
  RobleGoogleSignIn({this.iosClientId});

  /// Client ID de iOS. En Android se deja `null`: alli lo resuelve el propio
  /// SDK a partir de la firma del paquete. Roble no guarda este, que es por
  /// plataforma, asi que es lo unico de Google que sigue en manos de la app.
  final String? iosClientId;

  bool _initialized = false;

  @override
  bool get isSupported {
    if (kIsWeb) return false;

    try {
      return GoogleSignIn.instance.supportsAuthenticate();
    } on UnimplementedError {
      // Linux y Windows no tienen implementacion del plugin, y ahi
      // supportsAuthenticate lanza en vez de devolver false. Sin este catch el
      // boton reventaria en escritorio en lugar de caer al flujo de navegador,
      // que si funciona.
      return false;
    }
  }

  /// `initialize` es idempotente, pero el nonce y el servidor solo se pueden
  /// pasar aqui, asi que se rehace en cada intento.
  Future<void> _initialize(String serverClientId, String? nonce) async {
    await GoogleSignIn.instance.initialize(
      clientId: iosClientId,
      serverClientId: serverClientId,
      nonce: nonce,
    );
    _initialized = true;
  }

  @override
  Future<String?> idToken({
    required String serverClientId,
    String? nonce,
  }) async {
    if (!isSupported) return null;

    await _initialize(serverClientId, nonce);

    try {
      // `authenticate` es el que abre el selector de cuentas. El SDK tambien
      // trae `attemptLightweightAuthentication`, que es silencioso y devuelve
      // null si no hay sesion previa: sirve para entrar solo al arrancar, no
      // para responder a un boton.
      final account = await GoogleSignIn.instance.authenticate();
      return account.authentication.idToken;
    } on GoogleSignInException catch (error) {
      // Cancelar no es un fallo: la persona cerro el selector y la interfaz
      // solo tiene que volver a como estaba.
      if (error.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  @override
  Future<void> signOut() async {
    if (!_initialized) return;
    await GoogleSignIn.instance.signOut();
  }
}
