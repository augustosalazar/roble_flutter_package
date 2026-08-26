import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import 'roble_social_auth.dart';

/// Abre el proveedor en la pestana de navegador del sistema y espera el retorno.
///
/// Es el [RobleSocialOpener] que hace falta fuera de web. En web no se usa: el
/// paquete trae su propia ventana emergente, que no necesita plugin ni
/// configuracion nativa.
///
/// [callbackScheme] es el esquema propio de la app, el mismo que esta declarado
/// en `AndroidManifest.xml` / `Info.plist` y registrado como destino de retorno
/// en la consola de Roble. Es lo unico que el paquete no puede saber, porque es
/// de la app.
///
/// ```dart
/// RobleApiDataBase(
///   config: config,
///   socialOpener: kIsWeb ? null : robleNativeOpener('com.ejemplo.miapp'),
/// );
/// ```
RobleSocialOpener robleNativeOpener(String callbackScheme) {
  return (Uri loginUrl, Duration timeout) async {
    final retorno = await FlutterWebAuth2.authenticate(
      url: loginUrl.toString(),
      callbackUrlScheme: callbackScheme,
    ).timeout(timeout);

    return Uri.parse(retorno);
  };
}
