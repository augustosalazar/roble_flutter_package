import 'roble_user.dart';

/// Por qué cambió la sesión.
///
/// Existe porque `null` no basta: quien escucha necesita distinguir «se fue»
/// de «se le cayó», y son dos pantallas distintas. Sin esto, la app tendría que
/// adivinarlo por su cuenta, que es lo que se hacía antes cazando
/// `RobleApiAuthException`.
enum RobleAuthReason {
  /// Acaba de entrar: por contraseña, por proveedor social o por id token.
  signedIn,

  /// Se recuperó al arrancar una sesión que ya estaba guardada.
  restored,

  /// Se cerró la sesión a propósito.
  signedOut,

  /// Se cayó sola: el servidor rechazó el token y el de refresco tampoco
  /// valía. A quien le pase no ha hecho nada; conviene decírselo.
  expired,
}

/// El estado de la sesión, tal como queda después de cada cambio.
class RobleAuthState {
  const RobleAuthState({required this.user, required this.reason});

  /// El perfil de quien entró, o `null` si no hay nadie.
  ///
  /// Ya convertido: quien escuche no tiene que saber cómo viene el `Map` del
  /// servidor ni qué campos pueden faltar.
  ///
  /// Puede ser `null` **con sesión iniciada**: `restoreSession(verify: false)`
  /// carga los tokens sin llamar al servidor, así que no hay perfil que dar.
  /// Para saber si hay sesión, [isSignedIn]; para pintar un nombre, comprueba
  /// esto o pide [RobleApiDataBase.currentUser].
  final RobleUser? user;

  final RobleAuthReason reason;

  /// Si hay sesión. Sale del motivo y no del perfil, porque una sesión
  /// recuperada sin verificar no trae perfil y sigue siendo una sesión.
  bool get isSignedIn =>
      reason == RobleAuthReason.signedIn || reason == RobleAuthReason.restored;

  /// La sesión se acabó sin que nadie la cerrara.
  bool get hasExpired => reason == RobleAuthReason.expired;

  @override
  String toString() => 'RobleAuthState(${reason.name}, '
      'user: ${user?.email ?? 'ninguno'})';
}
