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

/// El servidor entendió la petición y se negó a hacerla: `403`.
///
/// En Roble esto es casi siempre el modelo de permisos, no la sesión. Desde que
/// los permisos son por tabla, un rol puede leer `pedidos` y no poder borrarla,
/// así que el mismo token vale para una cosa y no para la otra. También sale al
/// borrar una colección entera del árbol JSON, que es cosa de administradores,
/// y al suscribirse a una colección que no se puede leer.
///
/// Extiende [RobleApiHttpException] a propósito: quien ya capturaba el `403`
/// por código sigue capturándolo igual.
class RobleApiForbiddenException extends RobleApiHttpException {
  const RobleApiForbiddenException(String message, {Object? code})
      : super(403, message, code: code);
}

/// No hay nada ahí que puedas tocar: `404`.
///
/// Con la propiedad por fila activada, el servidor responde lo mismo para «no
/// existe» que para «no es tuya», y es deliberado: si respondiera distinto,
/// probar identificadores diría cuáles existen y de quién son.
///
/// Ojo con el borrado: antes borrar un `_id` que ya no estaba devolvía `200`.
/// Ahora devuelve `404`, así que un reintento de un borrado que sí funcionó
/// llega aquí. Si tu app reintenta borrados, trátalo como éxito.
class RobleApiNotFoundException extends RobleApiHttpException {
  const RobleApiNotFoundException(String message, {Object? code})
      : super(404, message, code: code);
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

/// La clave publicable no puede hacer eso, y lo dice **este** paquete.
///
/// Una clave `roble_anon_` sólo inserta, y sólo en las tablas que lo declaren.
/// El servidor ya lo rechaza, pero se rechaza también aquí para que el fallo
/// llegue en la línea que lo causó y diga qué credencial estás usando, en vez
/// de un `401` a mitad de una pantalla que parece una sesión caducada.
///
/// No extiende [RobleApiHttpException]: no hubo petición. Si esto te llega,
/// ninguna llamada salió a la red.
class RobleAnonKeyScopeException extends RobleApiException {
  /// El método que se intentó llamar, para que el mensaje no sea un adivina.
  final String attempted;

  RobleAnonKeyScopeException(this.attempted)
      : super(
          'Una clave publicable sólo puede insertar: `$attempted` no está '
              'permitido. Si necesitas leer, actualizar o borrar, el cliente '
              'tiene que iniciar sesión (`login` o `signInAnonymously`) en vez '
              'de usar `anonKey`.',
          code: 'ANON_KEY_SCOPE',
        );
}

/// El proyecto no admite invitados, o no como está configurado ahora mismo.
///
/// Dos casos, y conviene distinguirlos por [code] porque se arreglan distinto:
///
/// - `ANON_AUTH_DISABLED` (403): falta encender el acceso anónimo del proyecto.
/// - `ANON_REQUIRES_ROW_OWNERSHIP` (409): está encendido, pero ninguna tabla
///   aplica propiedad por fila. El servidor se niega a dar una sesión de
///   invitado que escribiría filas que puede tocar cualquiera. Se arregla en la
///   consola, activando la propiedad en las tablas donde el invitado escriba.
class RobleAnonymousAuthException extends RobleApiHttpException {
  const RobleAnonymousAuthException(int statusCode, String message,
      {Object? code})
      : super(statusCode, message, code: code);
}

/// Ya hay una cuenta con ese correo: `409`, `ANON_UPGRADE_EMAIL_TAKEN`.
///
/// El invitado **no** se convirtió y no se tocó nada; sigue siendo invitado y
/// sus filas siguen siendo suyas. Roble no fusiona dos cuentas en una a
/// escondidas, porque así es como se pierden datos. Lo que toca es ofrecer
/// iniciar sesión con esa cuenta, sabiendo que lo escrito como invitado se
/// queda en la sesión de invitado.
class RobleAnonUpgradeEmailTakenException extends RobleApiHttpException {
  const RobleAnonUpgradeEmailTakenException(String message)
      : super(409, message, code: 'ANON_UPGRADE_EMAIL_TAKEN');
}

/// Convierte una respuesta HTTP fallida en la excepción que le toca.
///
/// Un solo sitio decide esto para que no acabe cada llamada clasificando el
/// mismo `403` a su manera.
RobleApiHttpException robleHttpError(
  int statusCode,
  String message, {
  Object? code,
}) {
  // Los del acceso anónimo van por `code` y no por estado: el 403 de
  // `ANON_AUTH_DISABLED` es un problema de configuración del proyecto, no del
  // rol de quien llama, y mezclarlo con los 403 de permisos manda a quien
  // depura a mirar la tabla equivocada.
  if (code == 'ANON_UPGRADE_EMAIL_TAKEN') {
    return RobleAnonUpgradeEmailTakenException(message);
  }
  if (code == 'ANON_AUTH_DISABLED' || code == 'ANON_REQUIRES_ROW_OWNERSHIP') {
    return RobleAnonymousAuthException(statusCode, message, code: code);
  }

  return switch (statusCode) {
    403 => RobleApiForbiddenException(message, code: code),
    404 => RobleApiNotFoundException(message, code: code),
    _ => RobleApiHttpException(statusCode, message, code: code),
  };
}
