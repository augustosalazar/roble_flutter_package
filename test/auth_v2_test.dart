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
};

const sesion = {'accessToken': 'at-1', 'refreshToken': 'rt-1'};

/// Almacén en memoria, para no tocar el llavero del sistema en pruebas.
class MemoriaStorage implements RobleTokenStorage {
  final Map<String, String> datos = {};

  @override
  Future<String?> getItem(String key) async => datos[key];

  @override
  Future<void> setItem(String key, String value) async => datos[key] = value;

  @override
  Future<void> removeItem(String key) async => datos.remove(key);
}

RobleApiDataBase clienteCon(Guion guion, {String? ssoRedirect}) =>
    RobleApiDataBase(
      config: config,
      client: guion.cliente,
      storage: MemoriaStorage(),
      ssoRedirect: ssoRedirect,
    );

void main() {
  group('signInWithIdToken', () {
    test('manda provider y token al endpoint genérico', () async {
      final guion = Guion([(_) => json200(sesion), (_) => json200(perfil)]);
      final db = clienteCon(guion);

      final user = await db.signInWithIdToken(
        provider: 'google',
        idToken: 'el-id-token',
      );

      final peticion = guion.peticiones.first;
      expect(peticion.method, 'POST');
      expect(peticion.url.path, '/auth/$contractId/auth/id-token');
      final enviado = jsonDecode(peticion.body) as Map;
      expect(enviado['provider'], 'google');
      expect(enviado['token'], 'el-id-token');
      expect(user['email'], 'ana@correo.com');
    });

    test('no manda Authorization: aún no hay sesión', () async {
      final guion = Guion([(_) => json200(sesion), (_) => json200(perfil)]);

      await clienteCon(guion)
          .signInWithIdToken(provider: 'google', idToken: 't');

      expect(guion.peticiones.first.headers.containsKey('Authorization'),
          isFalse);
    });

    test('incluye el nonce solo si se pasa', () async {
      final conNonce = Guion([(_) => json200(sesion), (_) => json200(perfil)]);
      await clienteCon(conNonce)
          .signInWithIdToken(provider: 'google', idToken: 't', nonce: 'n-1');
      expect((jsonDecode(conNonce.peticiones.first.body) as Map)['nonce'], 'n-1');

      final sinNonce = Guion([(_) => json200(sesion), (_) => json200(perfil)]);
      await clienteCon(sinNonce)
          .signInWithIdToken(provider: 'google', idToken: 't');
      // Mandar nonce: null haría fallar la comprobación del servidor.
      expect(
        (jsonDecode(sinNonce.peticiones.first.body) as Map).containsKey('nonce'),
        isFalse,
      );
    });

    test('guarda la sesión devuelta', () async {
      final guion = Guion([(_) => json200(sesion), (_) => json200(perfil)]);
      final db = clienteCon(guion);

      await db.signInWithIdToken(provider: 'google', idToken: 't');

      expect(db.isLoggedIn, isTrue);
      expect(guion.peticiones.last.headers['Authorization'], 'Bearer at-1');
    });

    test('rechaza un idToken vacío sin llamar al servidor', () async {
      final guion = Guion([]);
      final db = clienteCon(guion);

      expect(
        () => db.signInWithIdToken(provider: 'google', idToken: ''),
        throwsA(isA<ArgumentError>()),
      );
      expect(guion.peticiones, isEmpty);
    });

    test('traduce el 409 a RobleApiConflictException', () async {
      final guion = Guion([
        (_) => jsonErr(409, 'Ya existe una cuenta con este correo.'),
      ]);

      // Es el caso de Microsoft sin email_verified: no se arregla
      // reintentando, así que merece un tipo propio.
      await expectLater(
        clienteCon(guion)
            .signInWithIdToken(provider: 'microsoft', idToken: 't'),
        throwsA(isA<RobleApiConflictException>()),
      );
    });

    test('el conflicto sigue siendo capturable como error HTTP', () async {
      final guion = Guion([(_) => jsonErr(409, 'Ya existe una cuenta')]);

      // Quien ya capturaba RobleApiHttpException no se entera del cambio.
      await expectLater(
        clienteCon(guion).signInWithIdToken(provider: 'google', idToken: 't'),
        throwsA(isA<RobleApiHttpException>()),
      );
    });
  });

  group('listProviders', () {
    test('lee la lista del endpoint genérico', () async {
      final guion = Guion([
        (_) => json200([
              {
                'name': 'google',
                'displayName': 'Google',
                'autoLinkSupported': true,
                'clientId': 'web-client-id',
              },
              {
                'name': 'github',
                'displayName': 'GitHub',
                'autoLinkSupported': false,
              },
            ]),
      ]);

      final proveedores = await clienteCon(guion).listProviders();

      expect(guion.peticiones.first.url.path, '/auth/$contractId/auth/providers');
      // Con el clientId aqui, la app puede configurar su SDK nativo sin llevar
      // una segunda copia que se desincronice.
      expect(proveedores.first.clientId, 'web-client-id');
      // Un servidor anterior no lo manda; eso no debe reventar el parseo.
      expect(proveedores.last.clientId, isNull);
      // Un proveedor que el paquete no conoce se devuelve igual: por eso deja
      // de hacer falta publicar una versión para añadir uno.
      expect(proveedores.map((p) => p.name), ['google', 'github']);
      expect(proveedores.last.autoLinkSupported, isFalse);
    });
  });

  group('startSocialLogin', () {
    test('manda el challenge, no el verifier', () async {
      final guion = Guion([
        (_) => json200({'url': 'https://accounts.google.com/o/oauth2/v2/auth?x=1'}),
      ]);

      final url = await clienteCon(guion).startSocialLogin('google');

      final enviado = jsonDecode(guion.peticiones.first.body) as Map;
      expect(guion.peticiones.first.url.path,
          '/auth/$contractId/auth/google/start');
      expect(enviado['codeChallenge'], isNotEmpty);
      // El verifier es justo lo que no debe salir de aquí.
      expect(enviado.containsKey('codeVerifier'), isFalse);
      expect(url.host, 'accounts.google.com');
    });

    test('manda extra en el cuerpo, nunca en la URL', () async {
      final guion = Guion([(_) => json200({'url': 'https://p.test/go'})]);

      await clienteCon(guion)
          .startSocialLogin('google', extra: {'departamento': 'ingenieria'});

      final peticion = guion.peticiones.first;
      // En el flujo antiguo viajaba en la query, así que quedaba en los logs
      // de acceso, en los del proxy y en el historial.
      expect(peticion.url.query, isEmpty);
      expect((jsonDecode(peticion.body) as Map)['extra'],
          {'departamento': 'ingenieria'});
    });

    test('usa el ssoRedirect del cliente si la llamada no trae uno', () async {
      final guion = Guion([(_) => json200({'url': 'https://p.test/go'})]);

      await clienteCon(guion, ssoRedirect: 'movil').startSocialLogin('google');

      expect((jsonDecode(guion.peticiones.first.body) as Map)['redirect'],
          'movil');
    });
  });

  group('exchangeSocialCode', () {
    test('manda el verifier del flujo que arrancó', () async {
      final guion = Guion([
        (_) => json200({'url': 'https://p.test/go'}),
        (_) => json200(sesion),
        (_) => json200(perfil),
      ]);
      final db = clienteCon(guion);

      await db.startSocialLogin('google');
      final challenge =
          (jsonDecode(guion.peticiones.first.body) as Map)['codeChallenge'];
      await db.exchangeSocialCode('el-codigo');

      final canje = jsonDecode(guion.peticiones[1].body) as Map;
      expect(guion.peticiones[1].url.path, '/auth/$contractId/auth/token');
      expect(canje['code'], 'el-codigo');
      // El servidor recalcula el challenge desde este verifier, así que tienen
      // que ser el par que se generó junto.
      expect(RoblePkce.derivarChallenge(canje['codeVerifier'] as String),
          challenge);
    });

    test('consume el verifier: un segundo canje ya no lo manda', () async {
      final guion = Guion([
        (_) => json200({'url': 'https://p.test/go'}),
        (_) => json200(sesion),
        (_) => json200(perfil),
        (_) => json200(sesion),
        (_) => json200(perfil),
      ]);
      final db = clienteCon(guion);

      await db.startSocialLogin('google');
      await db.exchangeSocialCode('c1');
      await db.exchangeSocialCode('c2');

      // Si sobreviviera al intento, un código robado podría canjearse después.
      expect((jsonDecode(guion.peticiones[3].body) as Map)
          .containsKey('codeVerifier'), isFalse);
    });

    test('no guarda verifier si el arranque falló', () async {
      final guion = Guion([
        (_) => jsonErr(400, 'No hay destinos configurados'),
        (_) => json200(sesion),
        (_) => json200(perfil),
      ]);
      final db = clienteCon(guion);

      await expectLater(db.startSocialLogin('google'),
          throwsA(isA<RobleApiHttpException>()));
      await db.exchangeSocialCode('c1');

      // Un verifier huérfano haría fallar el canje del intento siguiente.
      expect((jsonDecode(guion.peticiones[1].body) as Map)
          .containsKey('codeVerifier'), isFalse);
    });
  });

  group('RoblePkce', () {
    test('el verifier respeta la longitud de la RFC 7636', () {
      expect(RoblePkce.generar().verifier.length, inInclusiveRange(43, 128));
      expect(() => RoblePkce.generar(longitud: 42), throwsArgumentError);
      expect(() => RoblePkce.generar(longitud: 129), throwsArgumentError);
    });

    test('usa solo caracteres unreserved', () {
      expect(RoblePkce.generar(longitud: 128).verifier,
          matches(RegExp(r'^[A-Za-z0-9\-._~]{128}$')));
    });

    test('es distinto cada vez', () {
      final vistos = {for (var i = 0; i < 50; i++) RoblePkce.generar().verifier};
      expect(vistos.length, 50);
    });

    test('el challenge es base64url sin relleno', () {
      final challenge = RoblePkce.generar().challenge;
      expect(challenge, isNot(contains('=')));
      expect(challenge, isNot(matches(RegExp(r'[+/]'))));
    });

    test('deriva el challenge del verifier de forma estable', () {
      // Vector fijo, para que esto compruebe la transformación y no se limite
      // a repetir la implementación.
      expect(
        RoblePkce.derivarChallenge('a' * 64),
        '_-BU_nrgy23GXDr5th1SCfQ5hR20PQulmXM33xVGaOs',
      );
    });
  });
}
