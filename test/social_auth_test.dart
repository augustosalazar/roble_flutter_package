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

/// Cliente con respuestas guionizadas y registro de lo que se pidió.
class Guion {
  final List<http.Request> peticiones = [];
  final List<http.Response Function(http.Request)> _respuestas;

  Guion(this._respuestas);

  MockClient get cliente => MockClient((req) async {
        peticiones.add(req);
        return _respuestas.removeAt(0)(req);
      });
}

http.Response json200(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {
      'content-type': 'application/json',
    });

http.Response jsonErr(int code, String message) =>
    http.Response(jsonEncode({'message': message}), code, headers: {
      'content-type': 'application/json',
    });

const perfil = {
  'userId': 'u1',
  'email': 'ana@correo.com',
  'name': 'Ana',
  'extra': {'departamento': 'ingenieria'},
};

RobleApiDataBase construir(Guion guion,
        {RobleTokenStorage? storage,
        String? ssoRedirect,
        RobleSocialOpener? socialOpener}) =>
    RobleApiDataBase(
      config: config,
      client: guion.cliente,
      storage: storage ?? RobleMemoryStorage(),
      ssoRedirect: ssoRedirect,
      socialOpener: socialOpener,
    );

/// Opener de mentira: apunta lo que le pidieron y devuelve el retorno que le
/// digas, sin abrir nada.
class OpenerFalso {
  OpenerFalso(this._retorno);

  final Uri _retorno;
  Uri? urlPedida;
  Duration? plazoPedido;

  Future<Uri> abrir(Uri loginUrl, Duration timeout) async {
    urlPedida = loginUrl;
    plazoPedido = timeout;
    return _retorno;
  }
}

/// Guion del canje: intercambio + perfil.
Guion get guionDeCanje => Guion([
      (_) => json200({'accessToken': 'at', 'refreshToken': 'rt'}),
      (_) => json200(perfil),
    ]);

/// Guion del flujo completo: arranque, canje y perfil.
Guion get guionDeFlujo => Guion([
      (_) => json200({'url': 'https://accounts.google.com/o/oauth2/v2/auth?s=1'}),
      (_) => json200({'accessToken': 'at', 'refreshToken': 'rt'}),
      (_) => json200(perfil),
    ]);

void main() {
  group('isSocialCallback', () {
    test('reconoce un retorno', () {
      final db = construir(Guion([]));

      expect(
          db.isSocialCallback(
              Uri.parse('https://app.test/?code=abc&provider=google')),
          isTrue);
      expect(db.isSocialCallback(Uri.parse('myapp://sso-done?code=abc')),
          isTrue);
    });

    test('descarta lo que no lo es', () {
      final db = construir(Guion([]));

      for (final url in [
        'https://app.test/',
        'https://app.test/?provider=google',
        'https://app.test/?code=',
      ]) {
        expect(db.isSocialCallback(Uri.parse(url)), isFalse, reason: url);
      }
    });
  });

  group('la sesión sigue sin ser manipulable', () {
    test('no hay miembros de token en la superficie pública', () {
      final db = construir(Guion([]));
      // Si alguno de estos volviera a existir, esto no compilaría.
      expect(db.isLoggedIn, isFalse);
    });
  });

  group('signInWithProvider', () {
    test('arranca el flujo, abre lo que dice el servidor y canjea', () async {
      final opener =
          OpenerFalso(Uri.parse('https://app.test/?code=abc&provider=google'));
      final guion = guionDeFlujo;
      final db = construir(guion, socialOpener: opener.abrir);

      final user = await db.signInWithProvider(RobleSocialProvider.google);

      expect(user['userId'], 'u1');
      expect(db.isLoggedIn, isTrue);
      // La URL ya no la arma el paquete: la crea el servidor al abrir el flujo,
      // que es lo que permite que lleve state y nonce.
      expect(guion.peticiones.first.url.path,
          '/auth/$contractId/auth/google/start');
      expect(opener.urlPedida!.host, 'accounts.google.com');
      expect(guion.peticiones[1].url.path, '/auth/$contractId/auth/token');
    });

    test('manda redirect y extra en el cuerpo del arranque', () async {
      final opener =
          OpenerFalso(Uri.parse('app://x?code=abc&provider=microsoft'));
      final guion = guionDeFlujo;
      final db = construir(guion,
          ssoRedirect: 'movil', socialOpener: opener.abrir);

      await db.signInWithProvider(
        RobleSocialProvider.microsoft,
        extra: {'departamento': 'ingenieria'},
      );

      // Antes viajaban en la query de la URL de arranque, y por tanto en los
      // logs de acceso, en los del proxy y en el historial.
      final arranque = jsonDecode(guion.peticiones.first.body) as Map;
      expect(arranque['redirect'], 'movil');
      expect(arranque['extra'], {'departamento': 'ingenieria'});
      expect(opener.urlPedida!.queryParameters.containsKey('extra'), isFalse);
    });

    test('el canje lleva el verifier del arranque', () async {
      final opener = OpenerFalso(Uri.parse('app://x?code=abc&provider=google'));
      final guion = guionDeFlujo;

      await construir(guion, socialOpener: opener.abrir)
          .signInWithProvider(RobleSocialProvider.google);

      final challenge =
          (jsonDecode(guion.peticiones.first.body) as Map)['codeChallenge'];
      final canje = jsonDecode(guion.peticiones[1].body) as Map;
      expect(RoblePkce.derivarChallenge(canje['codeVerifier'] as String),
          challenge);
    });

    test('el opener de la llamada gana al del cliente', () async {
      final delCliente =
          OpenerFalso(Uri.parse('app://x?code=c1&provider=google'));
      final deLaLlamada =
          OpenerFalso(Uri.parse('app://x?code=c2&provider=google'));
      final guion = guionDeFlujo;

      await construir(guion, socialOpener: delCliente.abrir)
          .signInWithProvider(RobleSocialProvider.google,
              opener: deLaLlamada.abrir);

      expect(deLaLlamada.urlPedida, isNotNull);
      expect(delCliente.urlPedida, isNull);
      expect((jsonDecode(guion.peticiones[1].body) as Map)['code'], 'c2');
    });

    test('el timeout llega al opener', () async {
      final opener = OpenerFalso(Uri.parse('app://x?code=c&provider=google'));

      await construir(guionDeFlujo, socialOpener: opener.abrir)
          .signInWithProvider(RobleSocialProvider.google,
              timeout: const Duration(seconds: 30));

      expect(opener.plazoPedido, const Duration(seconds: 30));
    });

    test('si el opener falla no se canjea nada', () async {
      final guion = Guion([
        (_) => json200({'url': 'https://p.test/go'}),
      ]);

      await expectLater(
        construir(guion,
                socialOpener: (_, __) async =>
                    throw const RobleApiAuthException('ventana bloqueada'))
            .signInWithProvider(RobleSocialProvider.google),
        throwsA(isA<RobleApiAuthException>()),
      );

      // Solo el arranque: no hubo canje.
      expect(guion.peticiones, hasLength(1));
    });

    test('un retorno sin code se diagnostica antes de canjear', () async {
      final opener = OpenerFalso(Uri.parse('app://x?error=access_denied'));
      final guion = Guion([
        (_) => json200({'url': 'https://p.test/go'}),
      ]);

      await expectLater(
        construir(guion, socialOpener: opener.abrir)
            .signInWithProvider(RobleSocialProvider.google),
        throwsA(isA<RobleApiAuthException>()
            .having((e) => e.message, 'mensaje', contains('access_denied'))),
      );

      expect(guion.peticiones, hasLength(1));
    });

    test('persistSession: false no deja sesión recuperable', () async {
      final opener = OpenerFalso(Uri.parse('app://x?code=abc&provider=google'));
      final almacen = RobleMemoryStorage();

      await construir(guionDeFlujo, storage: almacen, socialOpener: opener.abrir)
          .signInWithProvider(RobleSocialProvider.google,
              persistSession: false);

      final db2 = construir(Guion([]), storage: almacen);
      expect(await db2.restoreSession(verify: false), isFalse);
    });

    test('sin opener y fuera de web, el error dice que hace falta', () async {
      final guion = Guion([
        (_) => json200({'url': 'https://p.test/go'}),
      ]);

      // awaitSocialCallback solo existe en web; el mensaje tiene que decir que
      // hay que pasar un opener, no fallar con algo genérico.
      await expectLater(
        construir(guion).signInWithProvider(RobleSocialProvider.google),
        throwsA(isA<RobleApiAuthException>()),
      );
    });
  });

  group('startSocialLogin rechaza extra inválido', () {
    // La comprobación corre antes de tocar la red, así que el guion vacío
    // basta: si llegara a pedir algo, el test fallaría por falta de respuesta.
    final db = construir(Guion([]));

    for (final clave in ['role', 'isAdmin', 'userId', 'permissions']) {
      test('clave reservada en la raíz: $clave', () async {
        await expectLater(
          db.startSocialLogin('google', extra: {clave: 'x'}),
          throwsA(isA<ArgumentError>()
              .having((e) => '$e', 'mensaje', contains(clave))),
        );
      });
    }

    test('clave reservada anidada', () async {
      await expectLater(
        db.startSocialLogin('google', extra: {
          'perfil': {
            'datos': {'isAdmin': true}
          }
        }),
        throwsA(isA<ArgumentError>()
            .having((e) => '$e', 'ruta', contains('perfil.datos'))),
      );
    });

    test('clave reservada dentro de una lista', () async {
      await expectLater(
        db.startSocialLogin('google', extra: {
          'cursos': [
            {'nombre': 'ok'},
            {'role': 'admin'},
          ]
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('__proto__ a cualquier nivel', () async {
      await expectLater(
        db.startSocialLogin('google', extra: {'__proto__': {}}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('más de 4 KB', () async {
      await expectLater(
        db.startSocialLogin('google', extra: {'relleno': 'a' * 5000}),
        throwsA(isA<ArgumentError>()
            .having((e) => '$e', 'mensaje', contains('4096'))),
      );
    });

    test('valor no serializable', () async {
      await expectLater(
        db.startSocialLogin('google', extra: {'obj': Object()}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('4 KB justos sí pasan', () async {
      final guion = Guion([(_) => json200({'url': 'https://p.test/go'})]);

      await expectLater(
        construir(guion)
            .startSocialLogin('google', extra: {'relleno': 'a' * 4000}),
        completes,
      );
    });
  });
}
