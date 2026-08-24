import 'roble_api_exception.dart';

/// Fuera de web no hay ventana que abrir.
///
/// Se lanza en vez de devolver `null` para que el error diga qué hacer en vez
/// de aparecer más tarde como un retorno que nunca llega.
Future<Uri> awaitSocialCallback(
  Uri loginUrl, Duration timeout) async {
  throw const RobleApiAuthException(
    'El inicio de sesión en ventana solo está implementado en web. En móvil y '
    'escritorio usa socialLoginUrl() + completeSocialLogin() con un esquema '
    'propio y un listener de deep links.',
  );
}
