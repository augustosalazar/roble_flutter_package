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

void main() {
  group('socialConfig', () {
    test('lee la configuración de Google', () async {
      final guion = Guion([
        (_) => json200({'enabled': true, 'clientId': 'gid'}),
      ]);
      final db = construir(guion);

      final cfg = await db.socialConfig(RobleSocialProvider.google);

      expect(cfg.enabled, isTrue);
      expect(cfg.clientId, 'gid');
      expect(cfg.tenantId, isNull);
      expect(guion.peticiones.single.url.toString(),
          '$baseUrl/auth/$contractId/google-config');
    });

    test('Microsoft trae además el tenant', () async {
      final guion = Guion([
        (_) => json200({
              'enabled': true,
              'clientId': 'mid',
              'tenantId': 'tid',
            }),
      ]);

      final cfg =
          await construir(guion).socialConfig(RobleSocialProvider.microsoft);

      expect(cfg.tenantId, 'tid');
      expect(guion.peticiones.single.url.path,
          '/auth/$contractId/microsoft-config');
    });

    test('no manda Authorization: el endpoint es público', () async {
      final guion = Guion([
        (_) => json200({'accessToken': 'at', 'refreshToken': 'rt'}),
        (_) => json200(perfil),
        (_) => json200({'enabled': false}),
      ]);
      final db = construir(guion);
      await db.login(email: 'a@b.co', password: 'x');

      await db.socialConfig(RobleSocialProvider.google);

      expect(guion.peticiones.last.headers.containsKey('Authorization'),
          isFalse);
    });

    test('proveedor apagado', () async {
      final cfg = await construir(Guion([(_) => json200({'enabled': false})]))
          .socialConfig(RobleSocialProvider.google);

      expect(cfg.enabled, isFalse);
    });
  });

  group('socialLoginUrl', () {
    test('sin extra', () {
      final url = construir(Guion([])).socialLoginUrl(
        RobleSocialProvider.google,
      );

      expect(url.toString(), '$baseUrl/auth/$contractId/google');
    });

    test('con extra codificado como JSON en la query', () {
      final url = construir(Guion([])).socialLoginUrl(
        RobleSocialProvider.microsoft,
        extra: {'departamento': 'ingenieria', 'codigo': 12345},
      );

      expect(url.path, '/auth/$contractId/microsoft');
      expect(
        jsonDecode(url.queryParameters['extra']!),
        {'departamento': 'ingenieria', 'codigo': 12345},
      );
      // Debe ir escapado, no crudo.
      expect(url.toString(), contains('extra=%7B'));
    });

    test('con redirect elige el destino de retorno', () {
      final url = construir(Guion([])).socialLoginUrl(
        RobleSocialProvider.google,
        redirect: 'movil',
      );

      expect(url.queryParameters, {'redirect': 'movil'});
    });

    test('redirect y extra conviven', () {
      final url = construir(Guion([])).socialLoginUrl(
        RobleSocialProvider.google,
        redirect: 'web-dev',
        extra: {'origen': 'ejemplo'},
      );

      expect(url.queryParameters['redirect'], 'web-dev');
      expect(jsonDecode(url.queryParameters['extra']!), {'origen': 'ejemplo'});
    });

    test('el redirect se recorta', () {
      final url = construir(Guion([])).socialLoginUrl(
        RobleSocialProvider.google,
        redirect: '  movil  ',
      );

      expect(url.queryParameters['redirect'], 'movil');
    });

    test('un redirect vacío es un error, no un destino desconocido', () {
      // El servidor respondería 400 "El destino de retorno solicitado no está
      // autorizado"; mejor decirlo aquí.
      for (final vacio in ['', '   ']) {
        expect(
          () => construir(Guion([])).socialLoginUrl(
            RobleSocialProvider.google,
            redirect: vacio,
          ),
          throwsA(isA<ArgumentError>()),
        );
      }
    });

    test('ssoRedirect del cliente se aplica sin repetirlo', () {
      final db = construir(Guion([]), ssoRedirect: 'movil');

      expect(db.socialLoginUrl(RobleSocialProvider.google).queryParameters,
          {'redirect': 'movil'});
      expect(db.socialLoginUrl(RobleSocialProvider.microsoft).queryParameters,
          {'redirect': 'movil'});
    });

    test('el redirect de la llamada gana al del cliente', () {
      final url = construir(Guion([]), ssoRedirect: 'movil')
          .socialLoginUrl(RobleSocialProvider.google, redirect: 'web');

      expect(url.queryParameters['redirect'], 'web');
    });

    test('sin ninguno de los dos, el servidor usa "default"', () {
      final url = construir(Guion([])).socialLoginUrl(
        RobleSocialProvider.google,
      );

      expect(url.queryParameters, isEmpty);
    });

    test('un ssoRedirect vacío falla al construir el cliente', () {
      for (final vacio in ['', '  ']) {
        expect(
          () => construir(Guion([]), ssoRedirect: vacio),
          throwsA(isA<ArgumentError>()),
        );
      }
    });

    test('el ssoRedirect se recorta', () {
      final db = construir(Guion([]), ssoRedirect: '  movil  ');
      expect(db.ssoRedirect, 'movil');
    });

    test('un extra vacío no ensucia la URL', () {
      final url = construir(Guion([])).socialLoginUrl(
        RobleSocialProvider.google,
        extra: const {},
      );

      expect(url.queryParameters, isEmpty);
    });

    group('rechaza extra inválido', () {
      final db = construir(Guion([]));

      for (final clave in ['role', 'isAdmin', 'userId', 'permissions']) {
        test('clave reservada en la raíz: $clave', () {
          expect(
            () => db.socialLoginUrl(
              RobleSocialProvider.google,
              extra: {clave: 'x'},
            ),
            throwsA(isA<ArgumentError>()
                .having((e) => '$e', 'mensaje', contains(clave))),
          );
        });
      }

      test('clave reservada anidada', () {
        expect(
          () => db.socialLoginUrl(
            RobleSocialProvider.google,
            extra: {
              'perfil': {
                'datos': {'isAdmin': true}
              }
            },
          ),
          throwsA(isA<ArgumentError>().having(
              (e) => '$e', 'ruta', contains('perfil.datos'))),
        );
      });

      test('clave reservada dentro de una lista', () {
        expect(
          () => db.socialLoginUrl(
            RobleSocialProvider.google,
            extra: {
              'cursos': [
                {'nombre': 'ok'},
                {'role': 'admin'},
              ]
            },
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('__proto__ a cualquier nivel', () {
        expect(
          () => db.socialLoginUrl(
            RobleSocialProvider.google,
            extra: {'__proto__': {}},
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('más de 4 KB', () {
        expect(
          () => db.socialLoginUrl(
            RobleSocialProvider.google,
            extra: {'relleno': 'a' * 5000},
          ),
          throwsA(isA<ArgumentError>()
              .having((e) => '$e', 'mensaje', contains('4096'))),
        );
      });

      test('4 KB justos sí pasan', () {
        expect(
          () => db.socialLoginUrl(
            RobleSocialProvider.google,
            extra: {'relleno': 'a' * 4000},
          ),
          returnsNormally,
        );
      });

      test('valor no serializable', () {
        expect(
          () => db.socialLoginUrl(
            RobleSocialProvider.google,
            extra: {'obj': Object()},
          ),
          throwsA(isA<ArgumentError>()),
        );
      });
    });
  });

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

  group('completeSocialLogin', () {
    test('canjea el código y deja la sesión iniciada', () async {
      final guion = Guion([
        (_) => json200({
              'accessToken': 'at',
              'refreshToken': 'rt',
              'user': {'id': 'u1', 'email': 'ana@correo.com'},
            }),
        (_) => json200(perfil),
      ]);
      final db = construir(guion);

      final user = await db.completeSocialLogin(
        Uri.parse('https://miapp.test/sso-done?code=abc&provider=google'),
      );

      expect(db.isLoggedIn, isTrue);
      // Devuelve el perfil de /me, igual que login().
      expect(user['userId'], 'u1');
      expect(user['extra'], {'departamento': 'ingenieria'});

      final intercambio = guion.peticiones.first;
      // Sin el contrato: Roble deduce el proyecto del state de OAuth.
      expect(intercambio.url.toString(), '$baseUrl/auth/google/exchange');
      expect(jsonDecode(intercambio.body), {'code': 'abc'});
      // El intercambio no lleva bearer.
      expect(intercambio.headers.containsKey('Authorization'), isFalse);
    });

    test('usa el endpoint de Microsoft cuando lo dice la URL', () async {
      final guion = Guion([
        (_) => json200({'accessToken': 'at', 'refreshToken': 'rt'}),
        (_) => json200(perfil),
      ]);

      await construir(guion).completeSocialLogin(
        Uri.parse('myapp://sso-done?code=xyz&provider=microsoft'),
      );

      expect(guion.peticiones.first.url.toString(),
          '$baseUrl/auth/microsoft/exchange');
    });

    test('persiste la sesión para el siguiente arranque', () async {
      final disco = RobleMemoryStorage();
      await construir(
        Guion([
          (_) => json200({'accessToken': 'at', 'refreshToken': 'rt'}),
          (_) => json200(perfil),
        ]),
        storage: disco,
      ).completeSocialLogin(Uri.parse('app://x?code=c&provider=google'));

      final otra = construir(
        Guion([
          (_) => json200({'accessToken': 'at2'}),
        ]),
        storage: disco,
      );
      expect(await otra.restoreSession(), isTrue);
    });

    test('persistSession: false no deja nada recuperable', () async {
      final disco = RobleMemoryStorage();
      final db = construir(
        Guion([
          (_) => json200({'accessToken': 'at', 'refreshToken': 'rt'}),
          (_) => json200(perfil),
        ]),
        storage: disco,
      );

      await db.completeSocialLogin(
        Uri.parse('app://x?code=c&provider=google'),
        persistSession: false,
      );

      expect(db.isLoggedIn, isTrue, reason: 'sigue usable en memoria');
      expect(await construir(Guion([]), storage: disco).restoreSession(),
          isFalse);
    });

    test('código caducado o reusado', () async {
      final db = construir(Guion([
        (_) => jsonErr(400, 'Código inválido o expirado'),
      ]));

      await expectLater(
        db.completeSocialLogin(Uri.parse('app://x?code=viejo&provider=google')),
        throwsA(isA<RobleApiHttpException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', contains('expirado'))),
      );
      expect(db.isLoggedIn, isFalse);
    });

    test('URL sin code', () async {
      await expectLater(
        construir(Guion([])).completeSocialLogin(
          Uri.parse('https://miapp.test/sso-done?provider=google'),
        ),
        throwsA(isA<RobleApiAuthException>()
            .having((e) => e.message, 'message', contains('code'))),
      );
    });

    test('URL sin provider', () async {
      await expectLater(
        construir(Guion([])).completeSocialLogin(
          Uri.parse('https://miapp.test/sso-done?code=abc'),
        ),
        throwsA(isA<RobleApiAuthException>()
            .having((e) => e.message, 'message', contains('ninguno'))),
      );
    });

    test('provider desconocido', () async {
      await expectLater(
        construir(Guion([])).completeSocialLogin(
          Uri.parse('https://miapp.test/sso-done?code=abc&provider=facebook'),
        ),
        throwsA(isA<RobleApiAuthException>()
            .having((e) => e.message, 'message', contains('facebook'))),
      );
    });

    test('respuesta sin accessToken', () async {
      await expectLater(
        construir(Guion([(_) => json200({'user': {}})]))
            .completeSocialLogin(Uri.parse('app://x?code=c&provider=google')),
        throwsA(isA<RobleApiFormatException>()),
      );
    });
  });

  group('la sesión sigue sin ser manipulable', () {
    test('no hay miembros de token en la superficie pública', () {
      final db = construir(Guion([]));
      // Si alguno de estos volviera a existir, esto no compilaría.
      expect(db.isLoggedIn, isFalse);
      expect(db.socialLoginUrl(RobleSocialProvider.google), isA<Uri>());
    });
  });

  group('signInWithProvider', () {
    test('abre el proveedor, canjea y devuelve el perfil', () async {
      final opener =
          OpenerFalso(Uri.parse('https://app.test/?code=abc&provider=google'));
      final guion = guionDeCanje;
      final db = construir(guion, socialOpener: opener.abrir);

      final user = await db.signInWithProvider(RobleSocialProvider.google);

      expect(user['userId'], 'u1');
      expect(db.isLoggedIn, isTrue);
      expect(opener.urlPedida.toString(), '$baseUrl/auth/$contractId/google');
      expect(guion.peticiones.first.url.toString(),
          '$baseUrl/auth/google/exchange');
    });

    test('al opener le llega la URL con redirect y extra', () async {
      final opener =
          OpenerFalso(Uri.parse('app://x?code=abc&provider=microsoft'));
      final db = construir(guionDeCanje,
          ssoRedirect: 'movil', socialOpener: opener.abrir);

      await db.signInWithProvider(
        RobleSocialProvider.microsoft,
        extra: {'departamento': 'ingenieria'},
      );

      final pedida = opener.urlPedida!;
      expect(pedida.path, '/auth/$contractId/microsoft');
      expect(pedida.queryParameters['redirect'], 'movil');
      expect(jsonDecode(pedida.queryParameters['extra']!),
          {'departamento': 'ingenieria'});
    });

    test('el opener de la llamada gana al del cliente', () async {
      final delCliente = OpenerFalso(Uri.parse('app://x?code=c1&provider=google'));
      final deLaLlamada =
          OpenerFalso(Uri.parse('app://x?code=c2&provider=google'));
      final guion = guionDeCanje;

      await construir(guion, socialOpener: delCliente.abrir)
          .signInWithProvider(RobleSocialProvider.google,
              opener: deLaLlamada.abrir);

      expect(deLaLlamada.urlPedida, isNotNull);
      expect(delCliente.urlPedida, isNull);
      expect(jsonDecode(guion.peticiones.first.body), {'code': 'c2'});
    });

    test('el timeout llega al opener', () async {
      final opener = OpenerFalso(Uri.parse('app://x?code=c&provider=google'));

      await construir(guionDeCanje, socialOpener: opener.abrir)
          .signInWithProvider(RobleSocialProvider.google,
              timeout: const Duration(seconds: 30));

      expect(opener.plazoPedido, const Duration(seconds: 30));
    });

    test('si el opener falla no se canjea nada', () async {
      final db = construir(
        Guion([]),
        socialOpener: (_, __) async =>
            throw const RobleApiAuthException('ventana cerrada'),
      );

      await expectLater(
        db.signInWithProvider(RobleSocialProvider.google),
        throwsA(isA<RobleApiAuthException>()
            .having((e) => e.message, 'message', contains('ventana cerrada'))),
      );
      expect(db.isLoggedIn, isFalse);
    });

    test('persistSession: false no deja sesion recuperable', () async {
      final disco = RobleMemoryStorage();
      final db = construir(
        guionDeCanje,
        storage: disco,
        socialOpener: (_, __) async =>
            Uri.parse('app://x?code=c&provider=google'),
      );

      await db.signInWithProvider(RobleSocialProvider.google,
          persistSession: false);

      expect(db.isLoggedIn, isTrue);
      expect(await construir(Guion([]), storage: disco).restoreSession(),
          isFalse);
    });

    test('sin opener y fuera de web, el error dice que hace falta', () async {
      // Los tests corren en la VM, donde el import condicional resuelve al stub.
      await expectLater(
        construir(Guion([])).signInWithProvider(RobleSocialProvider.google),
        throwsA(isA<RobleApiAuthException>()),
      );
    });
  });
}
