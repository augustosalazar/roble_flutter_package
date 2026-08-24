import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Par PKCE para el login social (RFC 7636).
///
/// El código que Roble devuelve al final del flujo es un valor al portador:
/// quien lo tenga puede canjearlo por una sesión. En móvil eso importa más que
/// en web, porque otra app puede registrar el mismo esquema de URL y quedarse
/// con el retorno. Con PKCE ese código no sirve de nada sin el `verifier`, que
/// nunca sale de este proceso.
///
/// No hace falta construirlo a mano: [RobleApiDataBase.startSocialLogin] lo
/// genera, lo guarda y lo consume solo.
class RoblePkce {
  /// El secreto que se queda aquí y viaja solo en el canje.
  final String verifier;

  /// `base64url(sha256(verifier))`, lo único que ve el proveedor.
  final String challenge;

  const RoblePkce({required this.verifier, required this.challenge});

  /// Caracteres «unreserved» de la RFC 7636, sección 4.1.
  static const _alfabeto =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  static final _aleatorio = Random.secure();

  /// Genera un par nuevo.
  ///
  /// [longitud] debe estar entre 43 y 128, como exige la especificación; un
  /// proveedor rechaza cualquier otra cosa.
  factory RoblePkce.generar({int longitud = 64}) {
    if (longitud < 43 || longitud > 128) {
      throw ArgumentError.value(
        longitud,
        'longitud',
        'El code_verifier debe tener entre 43 y 128 caracteres',
      );
    }

    // El alfabeto tiene 64 caracteres y divide 256 de forma exacta, así que
    // tomar el módulo no introduce sesgo.
    final verifier = List.generate(
      longitud,
      (_) => _alfabeto[_aleatorio.nextInt(_alfabeto.length)],
    ).join();

    return RoblePkce(verifier: verifier, challenge: derivarChallenge(verifier));
  }

  /// `base64url(sha256(verifier))`, sin relleno, que es lo que el servidor
  /// recalcula para comprobar el canje.
  static String derivarChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }
}
