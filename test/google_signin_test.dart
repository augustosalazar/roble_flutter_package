import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:roble/roble.dart';

/// Origen de `id_token` de mentira: apunta con qué lo llamaron y devuelve lo
/// que el test decida.
class GoogleFalso implements RobleIdTokenSource {
  @override
  final bool isSupported;
  final String? token;

  String? serverClientIdRecibido;
  String? nonceRecibido;
  int llamadas = 0;

  GoogleFalso._({required this.isSupported, required this.token});

  factory GoogleFalso({bool soportado = true, String? token = 'id-token-1'}) =>
      GoogleFalso._(isSupported: soportado, token: token);

  @override
  Future<String?> idToken({required String serverClientId, String? nonce}) async {
    llamadas++;
    serverClientIdRecibido = serverClientId;
    nonceRecibido = nonce;
    return token;
  }

  @override
  Future<void> signOut() async {}
}

/// Almacén en memoria, para no tocar el llavero del sistema.
class MemoriaStorage implements RobleTokenStorage {
  final _datos = <String, String>{};

  @override
  Future<String?> getItem(String key) async => _datos[key];

  @override
  Future<void> setItem(String key, String value) async => _datos[key] = value;

  @override
  Future<void> removeItem(String key) async => _datos.remove(key);
}

void main() {
  late List<http.Request> peticiones;

  http.Response json200(Object body) => http.Response(jsonEncode(body), 200,
      headers: {'content-type': 'application/json'});

  /// Cliente que responde a los dos endpoints en juego.
  RobleApiDataBase construir({
    required RobleIdTokenSource google,
    List<Map<String, dynamic>> proveedores = const [
      {'name': 'google', 'clientId': 'cid-web.apps.googleusercontent.com'},
    ],
  }) {
    peticiones = [];
    return RobleApiDataBase(
      config: RobleApiConfig.fromContract(
        baseUrl: 'https://roble-api.test',
        contractId: 'proyecto_ab12',
      ),
      storage: MemoriaStorage(),
      idTokenSource: google,
      client: MockClient((req) async {
        peticiones.add(req);
        if (req.url.path.endsWith('auth/providers')) return json200(proveedores);
        if (req.url.path.endsWith('auth/id-token')) {
          return json200({
            'accessToken': 'at',
            'refreshToken': 'rt',
            'user': {'email': 'ana@correo.com'},
          });
        }
        return json200({'ok': true});
      }),
    );
  }

  group('camino nativo', () {
    test('el clientId sale de Roble, no del build de la app', () async {
      final google = GoogleFalso();

      await construir(google: google).signInWithGoogle();

      // Cuando la app llevaba su propia copia, las dos podian separarse: el
      // token se emitia para una audiencia y el servidor esperaba otra, y eso
      // sale como un 401 que parece un problema del token.
      expect(google.serverClientIdRecibido, 'cid-web.apps.googleusercontent.com');
    });

    test('el nonce que va a Google es el que se manda a Roble', () async {
      final google = GoogleFalso();

      await construir(google: google).signInWithGoogle();

      final canje = peticiones.firstWhere((r) => r.url.path.endsWith('auth/id-token'));
      final enviado = jsonDecode(canje.body) as Map<String, dynamic>;

      // Es lo que impide reutilizar un id_token capturado: si no coinciden, el
      // servidor lo rechaza.
      expect(enviado['nonce'], google.nonceRecibido);
      expect(enviado['nonce'], isNotEmpty);
      expect(enviado['token'], 'id-token-1');
    });

    test('no abre ninguna ventana', () async {
      var abierta = false;

      await RobleApiDataBase(
        config: RobleApiConfig.fromContract(
          baseUrl: 'https://roble-api.test',
          contractId: 'proyecto_ab12',
        ),
        storage: MemoriaStorage(),
        idTokenSource: GoogleFalso(),
        socialOpener: (url, timeout) async {
          abierta = true;
          return Uri.parse('app://done?code=x');
        },
        client: MockClient((req) async {
          if (req.url.path.endsWith('auth/providers')) {
            return json200([
              {'name': 'google', 'clientId': 'cid'}
            ]);
          }
          return json200({
            'accessToken': 'at',
            'refreshToken': 'rt',
            'user': {'email': 'a@a.com'},
          });
        }),
      ).signInWithGoogle();

      // Es la razon de ser del camino nativo: sin navegador, sin esquema de URL
      // propio y sin retorno que enrutar.
      expect(abierta, isFalse);
    });
  });

  group('vuelta al navegador', () {
    /// Cliente cuyo opener apunta que se uso.
    (RobleApiDataBase, List<bool>) conVentana({
      required RobleIdTokenSource google,
      List<Map<String, dynamic>> proveedores = const [
        {'name': 'google', 'clientId': 'cid'}
      ],
    }) {
      final abierta = <bool>[];
      final db = RobleApiDataBase(
        config: RobleApiConfig.fromContract(
          baseUrl: 'https://roble-api.test',
          contractId: 'proyecto_ab12',
        ),
        storage: MemoriaStorage(),
        idTokenSource: google,
        socialOpener: (url, timeout) async {
          abierta.add(true);
          return Uri.parse('app://done?code=codigo');
        },
        client: MockClient((req) async {
          if (req.url.path.endsWith('auth/providers')) {
            return json200(proveedores);
          }
          // Arranque del flujo de ventana: el servidor devuelve a donde ir.
          if (req.url.path.endsWith('/start')) {
            return json200({'url': 'https://accounts.google.test/o/oauth2'});
          }
          return json200({
            'accessToken': 'at',
            'refreshToken': 'rt',
            'user': {'email': 'a@a.com'},
          });
        }),
      );
      return (db, abierta);
    }

    test('cuando la plataforma no trae SDK', () async {
      final (db, abierta) = conVentana(google: GoogleFalso(soportado: false));

      await db.signInWithGoogle();

      // Es el caso de web, donde el flujo de ventana ya funciona sin plugin.
      expect(abierta, [true]);
    });

    test('cuando el proyecto no tiene Google configurado', () async {
      final (db, abierta) = conVentana(
        google: GoogleFalso(),
        proveedores: const [],
      );

      await db.signInWithGoogle();

      expect(abierta, [true]);
    });
  });

  group('cancelar', () {
    test('avisa, y no abre una ventana que se acaba de rechazar', () async {
      final abierta = <bool>[];
      final db = RobleApiDataBase(
        config: RobleApiConfig.fromContract(
          baseUrl: 'https://roble-api.test',
          contractId: 'proyecto_ab12',
        ),
        storage: MemoriaStorage(),
        idTokenSource: GoogleFalso(token: null),
        socialOpener: (url, timeout) async {
          abierta.add(true);
          return Uri.parse('app://done?code=x');
        },
        client: MockClient((req) async => json200([
              {'name': 'google', 'clientId': 'cid'}
            ])),
      );

      await expectLater(
        db.signInWithGoogle(),
        throwsA(isA<RobleApiAuthException>()),
      );
      // Caer al navegador aqui abriria justo lo que la persona cerro.
      expect(abierta, isEmpty);
    });
  });

  group('nonce', () {
    test('no se repite', () {
      final vistos = {for (var i = 0; i < 50; i++) RobleApiDataBase.newNonce()};
      expect(vistos, hasLength(50));
    });

    test('viaja en una URL sin escapar', () {
      final nonce = RobleApiDataBase.newNonce();

      // base64 normal trae `+`, `/` y `=`, que en una URL significan otra cosa.
      expect(nonce, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    });
  });
}
