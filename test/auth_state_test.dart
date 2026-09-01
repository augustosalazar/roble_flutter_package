import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:roble/roble.dart';

const baseUrl = 'https://roble-api.test';
const contractId = 'proyecto_ab12';

RobleApiConfig get config => RobleApiConfig.fromContract(
      baseUrl: baseUrl,
      contractId: contractId,
    );

/// Cliente con respuestas guionizadas. La última se repite, para no tener que
/// adivinar cuántas llamadas hace el paquete por dentro.
class Guion {
  Guion(this._respuestas);

  final List<http.Response Function(http.Request)> _respuestas;

  MockClient get cliente => MockClient((req) async {
        final responder = _respuestas.length > 1
            ? _respuestas.removeAt(0)
            : _respuestas.first;
        return responder(req);
      });

  void reescribir(List<http.Response Function(http.Request)> nuevas) {
    _respuestas
      ..clear()
      ..addAll(nuevas);
  }
}

http.Response json200(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

http.Response jsonErr(int code, String message) =>
    http.Response(jsonEncode({'message': message}), code,
        headers: {'content-type': 'application/json'});

const perfil = {'userId': 'u1', 'email': 'ana@correo.com', 'name': 'Ana'};
const sesion = {'accessToken': 'at-1', 'refreshToken': 'rt-1'};

class MemoriaStorage implements RobleTokenStorage {
  MemoriaStorage([Map<String, String>? inicial]) {
    if (inicial != null) datos.addAll(inicial);
  }

  final Map<String, String> datos = {};

  @override
  Future<String?> getItem(String key) async => datos[key];

  @override
  Future<void> setItem(String key, String value) async => datos[key] = value;

  @override
  Future<void> removeItem(String key) async => datos.remove(key);
}

/// Lo que dejó guardado una sesión anterior, para las pruebas de arranque.
Map<String, String> sesionGuardada() => {
      'roble.session.$contractId':
          jsonEncode({'accessToken': 'at-viejo', 'refreshToken': 'rt-viejo'}),
    };

List<http.Response Function(http.Request)> entrar() => [
      (_) => json200(sesion),
      (_) => json200(perfil),
    ];

void main() {
  RobleApiDataBase clienteCon(Guion guion, {Map<String, String>? almacen}) =>
      RobleApiDataBase(
        config: config,
        client: guion.cliente,
        storage: MemoriaStorage(almacen),
      );

  group('estado inicial', () {
    test('quien se suscribe recibe el de ahora, sin esperar a nada', () async {
      final db = clienteCon(Guion([(_) => json200({})]));

      final estado = await db.authStateChanges.first;

      expect(estado.isSignedIn, isFalse);
      expect(estado.reason, RobleAuthReason.signedOut);
    });

    test('y se puede mirar sin suscribirse', () {
      final db = clienteCon(Guion([(_) => json200({})]));

      expect(db.authState.isSignedIn, isFalse);
    });
  });

  group('entrar', () {
    test('emite signedIn con el perfil', () async {
      final guion = Guion(entrar());
      final db = clienteCon(guion);

      final estados = <RobleAuthState>[];
      db.authStateChanges.listen(estados.add);

      await db.login(email: 'ana@correo.com', password: 'secreto');
      await Future<void>.delayed(Duration.zero);

      // El primero es el estado inicial que se reparte al suscribirse.
      expect(estados.map((e) => e.reason),
          [RobleAuthReason.signedOut, RobleAuthReason.signedIn]);
      expect(estados.last.user?.email, 'ana@correo.com');
      expect(estados.last.isSignedIn, isTrue);
    });

    test('el login social emite lo mismo', () async {
      final guion = Guion([
        (_) => json200({'accessToken': 'at-1', 'refreshToken': 'rt-1'}),
        (_) => json200(perfil),
      ]);
      final db = clienteCon(guion);

      final estados = <RobleAuthState>[];
      db.authStateChanges.listen(estados.add);

      await db.signInWithIdToken(provider: 'google', idToken: 'tok');
      await Future<void>.delayed(Duration.zero);

      expect(estados.last.reason, RobleAuthReason.signedIn);
      expect(estados.last.user?.email, 'ana@correo.com');
    });
  });

  group('arrancar con una sesión guardada', () {
    test('emite restored, no signedIn: no ha entrado nadie ahora', () async {
      // La diferencia importa para la pantalla: «bienvenida» al entrar, nada
      // al recuperar una sesión que ya estaba.
      final guion = Guion([
        (_) => json200({'accessToken': 'at-2'}),
        (_) => json200(perfil),
      ]);
      final db = clienteCon(guion, almacen: sesionGuardada());

      final estados = <RobleAuthState>[];
      db.authStateChanges.listen(estados.add);

      expect(await db.restoreSession(), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(estados.last.reason, RobleAuthReason.restored);
      expect(estados.last.user?.email, 'ana@correo.com');
    });

    test('sin verificar hay sesión pero todavía no hay perfil', () async {
      final db = clienteCon(Guion([(_) => json200({})]),
          almacen: sesionGuardada());

      final estados = <RobleAuthState>[];
      db.authStateChanges.listen(estados.add);

      expect(await db.restoreSession(verify: false), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(estados.last.isSignedIn, isTrue);
      expect(estados.last.user, isNull);
    });

    test('una sesión guardada que ya no vale no es una caída', () async {
      // Nadie estaba dentro: decirle a quien abre la app que «su sesión
      // caducó» antes de enseñarle nada no ayuda.
      final db = clienteCon(Guion([(_) => jsonErr(401, 'Token revocado')]),
          almacen: sesionGuardada());

      final caidas = <void>[];
      db.onSessionExpired.listen(caidas.add);
      final estados = <RobleAuthState>[];
      db.authStateChanges.listen(estados.add);

      expect(await db.restoreSession(), isFalse);
      await Future<void>.delayed(Duration.zero);

      expect(caidas, isEmpty);
      expect(estados.map((e) => e.reason), [RobleAuthReason.signedOut]);
    });
  });

  group('salir', () {
    test('emite signedOut sin perfil', () async {
      final guion = Guion(entrar());
      final db = clienteCon(guion);
      await db.login(email: 'ana@correo.com', password: 'secreto');

      final estados = <RobleAuthState>[];
      db.authStateChanges.listen(estados.add);

      guion.reescribir([(_) => json200({})]);
      await db.logout();
      await Future<void>.delayed(Duration.zero);

      expect(estados.last.reason, RobleAuthReason.signedOut);
      expect(estados.last.user, isNull);
      expect(estados.last.isSignedIn, isFalse);
    });

    test('salir de donde no se estaba no emite nada', () async {
      // Pasa al arrancar sin sesión guardada; repetirlo haría que una app
      // pintara la entrada dos veces.
      final db = clienteCon(Guion([(_) => json200({})]));

      final estados = <RobleAuthState>[];
      db.authStateChanges.skip(1).listen(estados.add);

      await expectLater(db.logout(), throwsA(isA<RobleApiAuthException>()));
      await Future<void>.delayed(Duration.zero);

      expect(estados, isEmpty);
    });
  });

  group('caerse sola', () {
    test('emite expired, que no es lo mismo que signedOut', () async {
      final guion = Guion([
        ...entrar(),
        (_) => jsonErr(401, 'Unauthorized'),
        (_) => jsonErr(401, 'Refresh token inválido'),
      ]);
      final db = clienteCon(guion);
      await db.login(email: 'ana@correo.com', password: 'secreto');

      final estados = <RobleAuthState>[];
      db.authStateChanges.skip(1).listen(estados.add);

      await expectLater(db.read('productos'), throwsA(isA<Exception>()));
      await Future<void>.delayed(Duration.zero);

      expect(estados.single.reason, RobleAuthReason.expired);
      expect(estados.single.hasExpired, isTrue);
      expect(estados.single.isSignedIn, isFalse);
    });

    test('onSessionExpired es un filtro de esto, no otro mecanismo', () async {
      final guion = Guion([
        ...entrar(),
        (_) => jsonErr(401, 'Unauthorized'),
        (_) => jsonErr(401, 'Refresh token inválido'),
      ]);
      final db = clienteCon(guion);
      await db.login(email: 'ana@correo.com', password: 'secreto');

      final caidas = <void>[];
      db.onSessionExpired.listen(caidas.add);

      await expectLater(db.read('productos'), throwsA(isA<Exception>()));
      await Future<void>.delayed(Duration.zero);

      expect(caidas, hasLength(1));
    });

    test('quien llega tarde no se encuentra la caída de antes', () async {
      // `authStateChanges` reparte el estado actual al suscribirse, pero
      // `onSessionExpired` es un aviso: repetirlo mandaría a la entrada a
      // alguien que ya está en ella.
      final guion = Guion([
        ...entrar(),
        (_) => jsonErr(401, 'Unauthorized'),
        (_) => jsonErr(401, 'Refresh token inválido'),
      ]);
      final db = clienteCon(guion);
      await db.login(email: 'ana@correo.com', password: 'secreto');
      await expectLater(db.read('productos'), throwsA(isA<Exception>()));

      final caidas = <void>[];
      db.onSessionExpired.listen(caidas.add);
      await Future<void>.delayed(Duration.zero);

      expect(caidas, isEmpty);
      // Pero el estado sí sigue estando disponible para quien lo pregunte.
      expect(db.authState.hasExpired, isTrue);
    });
  });
}
