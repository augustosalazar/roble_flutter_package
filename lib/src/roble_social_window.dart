/// Espera del retorno del proveedor sin descargar la app.
///
/// La implementación real solo existe en web (popup + `postMessage`); en el
/// resto de plataformas hace falta una pestaña de navegador embebida, que
/// todavía no está implementada.
library;

export 'roble_social_window_stub.dart'
    if (dart.library.js_interop) 'roble_social_window_web.dart';
