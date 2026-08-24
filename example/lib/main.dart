import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:roble/roble.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const RobleExampleApp());
}

class RobleExampleApp extends StatefulWidget {
  const RobleExampleApp({super.key});

  @override
  State<RobleExampleApp> createState() => _RobleExampleAppState();
}

/// 👇 Cámbialo por el identificador de tu proyecto en la consola de Roble,
/// o pásalo al vuelo sin tocar el fuente:
///
///     flutter run -d chrome --web-port 8080 ///       --dart-define=ROBLE_CONTRACT_ID=miproyecto_ab12cd34ef
const kContractId = String.fromEnvironment(
  'ROBLE_CONTRACT_ID',
  defaultValue: 'tu_contrato',
);
/// Destino de retorno del login social, tal como lo diste de alta en la
/// consola. Vacío usa el llamado `default`.
const kSsoRedirect = String.fromEnvironment('ROBLE_SSO_REDIRECT');
const kBaseUrl = String.fromEnvironment(
  'ROBLE_BASE_URL',
  defaultValue: 'https://roble-api.test-openlab.uninorte.edu.co',
);

class _RobleExampleAppState extends State<RobleExampleApp> {
  RobleApiDataBase? _db;
  String? _errorConfig;

  StreamSubscription<Uri>? _deepLinks;

  String? _lastEmail;
  String _log = '';
  bool _recordarme = true;

  static const _tabla = 'usuarios_test';

  RobleApiDataBase get db => _db!;

  @override
  void initState() {
    super.initState();

    // fromContract avisa si el contrato no está configurado.
    try {
      _db = RobleApiDataBase(
        config: RobleApiConfig.fromContract(
          baseUrl: kBaseUrl,
          contractId: kContractId,
        ),
      );
    } on ArgumentError catch (e) {
      _errorConfig = '${e.message}\n\nEdita kContractId en example/lib/main.dart';
      return;
    }

    _arrancar();
  }

  /// Roble devuelve al usuario a la app tras el proveedor, y cómo llega el
  /// retorno depende de la plataforma:
  ///
  /// - **web**: la app se recarga en la URL de retorno, con `?code=` en
  ///   `Uri.base`.
  /// - **móvil y escritorio**: la app ya está viva y se la *reanuda* con un
  ///   deep link, así que `Uri.base` no sirve y hay que escuchar el stream.
  Future<void> _arrancar() async {
    _escucharDeepLinks();

    if (Uri.base.queryParameters.containsKey('code')) {
      await _terminarLoginSocial(Uri.base);
      return;
    }
    await _restaurarSesion();
  }

  /// Deep links de vuelta del proveedor (no-op en web).
  void _escucharDeepLinks() {
    final links = AppLinks();

    _deepLinks = links.uriLinkStream.listen(
      (uri) {
        if (uri.queryParameters.containsKey('code')) {
          _terminarLoginSocial(uri);
        }
      },
      onError: (Object e) => _appendLog('Deep link inválido: $e'),
    );
  }

  @override
  void dispose() {
    _deepLinks?.cancel();
    super.dispose();
  }

  /// Al arrancar: si hay sesión guardada y sigue siendo válida, se reutiliza.
  Future<void> _restaurarSesion() async {
    try {
      final activa = await db.restoreSession();
      _appendLog(activa
          ? 'Sesión restaurada: ${(await db.currentUser())['email']}'
          : 'No hay sesión guardada.');
    } on RobleApiNetworkException {
      _appendLog('Sin conexión: no se pudo verificar la sesión.');
    }
  }

  void _appendLog(String text) {
    if (!mounted) return;
    setState(() => _log = '$_log$text\n');
  }

  // === AUTENTICACIÓN ===

  Future<void> _registrar() async {
    final email = 'test_${DateTime.now().millisecondsSinceEpoch}@mail.com';
    _appendLog('Registrando $email…');

    try {
      // autoLogin deja la sesión iniciada y devuelve el perfil.
      final user = await db.register(
        email: email,
        password: 'Password123!',
        name: 'Usuario Prueba',
        extra: {'origen': 'ejemplo-flutter'},
        autoLogin: true,
        persistSession: _recordarme,
      );
      _lastEmail = email;
      _appendLog('Registrado y dentro: ${user['name']} (${user['userId']})');
    } catch (e) {
      _appendLog('Error registrando: $e');
    }
  }

  Future<void> _login() async {
    if (_lastEmail == null) {
      _appendLog('Primero crea un usuario.');
      return;
    }

    try {
      final user = await db.login(
        email: _lastEmail!,
        password: 'Password123!',
        persistSession: _recordarme,
      );
      _appendLog('Sesión iniciada como ${user['name']}');
    } catch (e) {
      if (db.isLoggedIn) {
        _appendLog('Sesión iniciada, pero falló el perfil: $e');
      } else {
        _appendLog('Credenciales incorrectas: $e');
      }
    }
  }

  Future<void> _logout() async {
    if (!db.isLoggedIn) {
      _appendLog('No hay sesión activa.');
      return;
    }
    try {
      await db.logout();
      _appendLog('Sesión cerrada.');
    } catch (e) {
      _appendLog('Error cerrando sesión: $e');
    }
  }

  Future<void> _quienSoy() async {
    try {
      final user = await db.currentUser();
      _appendLog('${user['name']} · ${user['email']} · extra: ${user['extra']}');
    } catch (e) {
      _appendLog('Error: $e');
    }
  }

  // === DATOS ===

  Future<void> _probarCrud() async {
    if (!db.isLoggedIn) {
      _appendLog('Inicia sesión antes de probar el CRUD.');
      return;
    }

    try {
      final creado = await db.create(_tabla, {'nombre': 'Ana', 'rol': 'admin'});
      _appendLog('Creado: ${creado['_id']}');

      final todos = await db.read(_tabla);
      _appendLog('Leídos: ${todos.length} registros');

      await db.update(_tabla, creado['_id'], {'rol': 'editor'});
      _appendLog('Actualizado.');

      final uno = await db.getById(_tabla, creado['_id']);
      _appendLog('getById: ${uno?['rol']}');

      await db.delete(_tabla, creado['_id']);
      _appendLog('Eliminado.');
    } catch (e) {
      _appendLog('Error en CRUD: $e');
    }
  }

  Future<void> _insertarVarios() async {
    if (!db.isLoggedIn) {
      _appendLog('Inicia sesión antes de insertar.');
      return;
    }

    try {
      final res = await db.createMany(_tabla, [
        {'nombre': 'Uno', 'rol': 'admin'},
        {'nombre': 'Dos', 'columna_inexistente': 1},
      ]);

      _appendLog('Insertados: ${res.inserted.length}');
      if (res.hasSkipped) {
        for (final s in res.skipped) {
          _appendLog('  Fila ${s.index} rechazada: ${s.reason}');
        }
      }
    } catch (e) {
      _appendLog('Error insertando: $e');
    }
  }

  // === LOGIN SOCIAL ===

  /// Consulta qué proveedores están activos en el proyecto. No necesita
  /// sesión, así que se puede llamar antes de pintar los botones.
  Future<void> _estadoProveedores() async {
    for (final proveedor in RobleSocialProvider.values) {
      try {
        final cfg = await db.socialConfig(proveedor);
        _appendLog(cfg.enabled
            ? '${proveedor.name}: activo (clientId ${cfg.clientId})'
            : '${proveedor.name}: apagado en este proyecto');
      } on RobleApiException catch (e) {
        _appendLog('${proveedor.name}: ${e.message}');
      }
    }
  }

  /// Paso 1: navegar a la URL del proveedor. El paquete solo la construye.
  Future<void> _entrarCon(RobleSocialProvider proveedor) async {
    try {
      final cfg = await db.socialConfig(proveedor);
      if (!cfg.enabled) {
        _appendLog('${proveedor.name} no está activo: actívalo en la consola '
            'de Roble antes de probar.');
        return;
      }

      // 'redirect' elige el destino de retorno configurado en la consola.
      // Sin destinos dados de alta, Roble responde 400 y no arranca.
      final url = db.socialLoginUrl(
        proveedor,
        extra: {'origen': 'ejemplo-flutter'},
        redirect: kSsoRedirect.isEmpty ? null : kSsoRedirect,
      );
      _appendLog('Abriendo ${url.origin}…');

      // En web se navega en la misma pestaña; en móvil hay que salir al
      // navegador del sistema para que la sesión del proveedor se comparta.
      if (!await launchUrl(
        url,
        webOnlyWindowName: '_self',
        mode: LaunchMode.externalApplication,
      )) {
        _appendLog('No se pudo abrir el navegador.');
      }
    } on RobleApiException catch (e) {
      _appendLog('Error: ${e.message}');
    }
  }

  /// Paso 3: canjear el código con el que Roble nos devolvió aquí.
  Future<void> _terminarLoginSocial(Uri retorno) async {
    _appendLog('Volviendo de ${retorno.queryParameters['provider']}…');
    try {
      final user = await db.completeSocialLogin(
        retorno,
        persistSession: _recordarme,
      );
      _lastEmail = user['email'] as String?;
      _appendLog('Dentro como ${user['name']} (${user['email']})');
    } on RobleApiHttpException catch (e) {
      // Lo habitual al recargar la página de retorno: el código es de un
      // solo uso y dura 60 segundos.
      _appendLog('No se pudo completar (${e.statusCode}): ${e.message}');
    } on RobleApiException catch (e) {
      _appendLog('No se pudo completar: ${e.message}');
    }
  }

  // === UI ===

  @override
  Widget build(BuildContext context) {
    if (_errorConfig != null) {
      return MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('Roble · configuración')),
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Text(_errorConfig!)),
          ),
        ),
      );
    }

    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Roble · ejemplo')),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  ElevatedButton(
                    onPressed: _registrar,
                    child: const Text('Registrar + entrar'),
                  ),
                  ElevatedButton(
                    onPressed: _login,
                    child: const Text('Iniciar sesión'),
                  ),
                  ElevatedButton(
                    onPressed: _quienSoy,
                    child: const Text('¿Quién soy?'),
                  ),
                  ElevatedButton(
                    onPressed: _logout,
                    child: const Text('Cerrar sesión'),
                  ),
                  ElevatedButton(
                    onPressed: () => _entrarCon(RobleSocialProvider.google),
                    child: const Text('Entrar con Google'),
                  ),
                  ElevatedButton(
                    onPressed: () => _entrarCon(RobleSocialProvider.microsoft),
                    child: const Text('Entrar con Microsoft'),
                  ),
                  ElevatedButton(
                    onPressed: _estadoProveedores,
                    child: const Text('¿Qué proveedores hay?'),
                  ),
                  ElevatedButton(
                    onPressed: _probarCrud,
                    child: const Text('Probar CRUD'),
                  ),
                  ElevatedButton(
                    onPressed: _insertarVarios,
                    child: const Text('Insertar varios'),
                  ),
                ],
              ),
              CheckboxListTile(
                value: _recordarme,
                onChanged: (v) => setState(() => _recordarme = v ?? true),
                title: const Text('Recordarme (persistSession)'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const Text('Log de operaciones:'),
              const SizedBox(height: 5),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: Text(_log, style: const TextStyle(fontSize: 13)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
