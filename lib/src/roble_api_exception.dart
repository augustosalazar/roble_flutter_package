/// Excepciones personalizadas para el paquete `roble`.
///
/// Este archivo define una jerarquía simple de excepciones
/// para representar errores comunes durante la comunicación
/// con la API Roble.
///
/// Ejemplo:
/// ```dart
/// try {
///   await api.read('users');
/// } on RobleApiNetworkException catch (e) {
///   print('Error de red: ${e.message}');
/// } on RobleApiException catch (e) {
///   print('Error genérico: ${e.message}');
/// }
/// ```

import 'roble_models.dart';

/// Excepción base para todos los errores del cliente Roble API.
///
/// Contiene un mensaje descriptivo, un posible código de error
/// y (opcionalmente) el stacktrace original para debugging.
class RobleApiException implements Exception {
  /// Mensaje de error descriptivo.
  final String message;

  /// Código de error opcional (por ejemplo: 404, 'timeout', 'invalid_token').
  final Object? code;

  /// Stacktrace opcional para propósitos de depuración.
  final StackTrace? stackTrace;

  const RobleApiException(this.message, {this.code, this.stackTrace});

  @override
  String toString() {
    final codeInfo = code != null ? ' (code: $code)' : '';
    return 'RobleApiException$codeInfo: $message';
  }
}

/// Error de red (por ejemplo, sin conexión o DNS no resuelto).
class RobleApiNetworkException extends RobleApiException {
  const RobleApiNetworkException(String message, {Object? code})
      : super(message, code: code);
}

/// Error cuando el servidor devuelve un código HTTP no exitoso.
class RobleApiHttpException extends RobleApiException {
  final int statusCode;

  const RobleApiHttpException(
    this.statusCode,
    String message, {
    Object? code,
  }) : super(message, code: code);

  @override
  String toString() => 'RobleApiHttpException($statusCode): $message';
}

/// Error cuando la respuesta tiene un formato inválido o no se puede parsear.
class RobleApiFormatException extends RobleApiException {
  const RobleApiFormatException(String message) : super(message);
}

/// Error cuando el tiempo de espera expira.
class RobleApiTimeoutException extends RobleApiException {
  const RobleApiTimeoutException(String message) : super(message);
}

/// Error cuando las credenciales son inválidas o el token expira.
class RobleApiAuthException extends RobleApiException {
  const RobleApiAuthException(String message) : super(message);
}

/// El servidor aceptó la petición pero rechazó parte de los registros.
///
/// Solo la lanza `createMany(..., strict: true)`. Conserva el resultado
/// completo para poder saber **qué sí se escribió**, algo necesario si hay que
/// deshacer la operación.
class RoblePartialInsertException extends RobleApiException {
  /// Filas insertadas y rechazadas, tal cual las devolvió el servidor.
  final RobleInsertResult result;

  RoblePartialInsertException(this.result)
      : super('El servidor rechazó ${result.skipped.length} de '
            '${result.inserted.length + result.skipped.length} registros: '
            '${result.skipped.map((s) => 'fila ${s.index} (${s.reason})').join('; ')}');
}

/// El proveedor social no pudo vincularse solo con una cuenta que ya existe.
///
/// Roble responde `409` cuando el proveedor no certifica que el correo esté
/// verificado y ese correo ya pertenece a una cuenta. Es deliberado: sin esa
/// prueba, quien controle un tenant del proveedor podría fijar el correo de
/// otra persona y heredar su cuenta. Le pasa sobre todo a Microsoft, porque la
/// mayoría de registros de Entra de un solo tenant no emiten `email_verified`.
///
/// No es un fallo recuperable reintentando: el usuario entra con el método que
/// ya tiene y vincula el proveedor desde los ajustes de su cuenta.
/// Extiende [RobleApiHttpException] a propósito: quien ya capturaba el `409`
/// por código sigue capturándolo igual.
class RobleApiConflictException extends RobleApiHttpException {
  const RobleApiConflictException(String message) : super(409, message);
}
