import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'roble_api_exception.dart';

/// Prefijo con el que la página de retorno marca su mensaje.
///
/// Sin él habría que fiarse de que ningún otro script del origen mande
/// cadenas por `postMessage`.
const _marca = 'roble-sso:';

/// Clave donde la página de retorno deja la URL como respaldo.
const _clave = 'roble-sso';

/// Abre [loginUrl] en un popup y espera la URL de retorno.
///
/// **Hay que llamarlo directamente desde el gesto del usuario.** Si antes se
/// hace cualquier `await`, el navegador considera que la ventana no la pidió
/// nadie y la bloquea.
///
/// El popup vuelve al destino configurado en Roble, donde el `index.html` de
/// la app deja la URL —por `postMessage` y en `localStorage`— y se cierra.
/// Como la app principal nunca se descarga, esta función puede devolver el
/// retorno de verdad.
Future<Uri> awaitSocialCallback(
  Uri loginUrl, Duration timeout) {
  // Restos de un intento anterior darían por bueno un código ya gastado.
  _olvidarRetorno();

  // Se abre en blanco y se navega después: así el `open` cae dentro del gesto
  // aunque construir la URL hubiera tardado.
  final popup = web.window.open('', 'roble_sso', 'popup=yes,width=480,height=680');
  if (popup == null || popup.closed) {
    throw const RobleApiAuthException(
      'El navegador bloqueó la ventana de inicio de sesión. Permite las '
      'ventanas emergentes para este sitio y vuelve a intentarlo.',
    );
  }
  popup.location.href = loginUrl.toString();

  final completer = Completer<Uri>();
  final origenPropio = web.window.location.origin;
  late final JSFunction escucha;
  Timer? vigilante;
  Timer? plazo;

  void terminar(void Function() accion) {
    if (completer.isCompleted) return;
    web.window.removeEventListener('message', escucha);
    vigilante?.cancel();
    plazo?.cancel();
    if (!popup.closed) popup.close();
    _olvidarRetorno();
    accion();
  }

  void lograr(Uri retorno) => terminar(() => completer.complete(retorno));
  void fallar(String motivo) =>
      terminar(() => completer.completeError(RobleApiAuthException(motivo)));

  escucha = ((web.MessageEvent evento) {
    // Solo se acepta lo que venga del propio origen: cualquier página puede
    // mandar mensajes a esta ventana.
    if (evento.origin != origenPropio) return;

    final dato = evento.data;
    if (!dato.isA<JSString>()) return;

    final texto = (dato as JSString).toDart;
    if (!texto.startsWith(_marca)) return;

    lograr(Uri.parse(texto.substring(_marca.length)));
  }).toJS;

  web.window.addEventListener('message', escucha);

  // Que la ventana esté cerrada no significa que el intento fracasara: la
  // página de retorno se cierra a sí misma justo después de dejar la URL. Por
  // eso, antes de dar el flujo por abandonado, se mira el respaldo.
  var cerradaDesde = 0;
  vigilante = Timer.periodic(const Duration(milliseconds: 400), (_) {
    final guardado = _leerRetorno();
    if (guardado != null) {
      lograr(Uri.parse(guardado));
      return;
    }

    if (!popup.closed) {
      cerradaDesde = 0;
      return;
    }

    // Un par de vueltas de gracia para que llegue lo que estuviera en camino.
    if (++cerradaDesde < 3) return;
    fallar('Se cerró la ventana antes de terminar de entrar.');
  });

  plazo = Timer(timeout, () {
    fallar('Se agotó el tiempo de espera del inicio de sesión.');
  });

  return completer.future;
}

/// Lee el respaldo que deja la página de retorno, si lo hay.
String? _leerRetorno() {
  try {
    final valor = web.window.localStorage.getItem(_clave);
    return (valor == null || valor.isEmpty) ? null : valor;
  } catch (_) {
    // Sin `localStorage` -modo privado, permisos- queda el `postMessage`.
    return null;
  }
}

void _olvidarRetorno() {
  try {
    web.window.localStorage.removeItem(_clave);
  } catch (_) {}
}
