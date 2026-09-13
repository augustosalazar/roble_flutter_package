import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:roble/roble.dart';

const baseUrl = 'https://roble-api.test';
const contractId = 'proyecto_ab12';
final anonKey = 'roble_anon_0123456789abcdef_${'a' * 43}';

RobleApiConfig configCon({String? anonKey}) => RobleApiConfig.fromContract(
      baseUrl: baseUrl,
      contractId: contractId,
      anonKey: anonKey,
    );

http.Response json200(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

http.Response jsonErr(int code, String message, {String? codigo}) =>
    http.Response(
        jsonEncode({'message': message, if (codigo != null) 'code': codigo}),
        code,
        headers: {'content-type': 'application/json'});

class MemoriaStorage implements RobleTokenStorage {
  final Map<String, String> datos = {};

  @override
  Future<String?> getItem(String key) async => datos[key];

  @override
  Future<void> setItem(String key, String value) async => datos[key] = value;

  @override
  Future<void> removeItem(String key) async => datos.remove(key);
}

String token(Map<String, dynamic> payload) => [
      'cabecera',
      base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', ''),
      'firma',
    ].join('.');

void main() {
  late List<http.Request> enviadas;
  late http.Response Function(http.Request) responder;

  RobleApiDataBase cliente({String? anonKey}) => RobleApiDataBase(
        config: configCon(anonKey: anonKey),
        client: MockClient((req) async {
          enviadas.add(req);
          return responder(req);
        }),
        storage: MemoriaStorage(),
      );

  setUp(() {
    enviadas = [];
    responder = (_) => json200({});
  });

  // ==========================================================
  group('sesión de invitado', () {
    Future<RobleApiDataBase> comoInvitado() async {
      final db = cliente();
      responder = (req) => req.url.path.endsWith('/signin-anonymous')
          ? json200({
              'accessToken': token({'sub': 'guest-1', 'isAnonymous': true}),
              'refreshToken': 'rt-1',
            })
          : json200({
              'userId': 'guest-1',
              'email': 'anon_abc@anonymous.invalid',
              'name': 'Guest',
              'isAnonymous': true,
            });
      await db.signInAnonymously();
      return db;
    }

    test('abre sesión sin credenciales', () async {
      final db = await comoInvitado();

      expect(db.isLoggedIn, isTrue);
      expect(db.currentUserId, 'guest-1');
      final llamada =
          enviadas.firstWhere((r) => r.url.path.endsWith('/signin-anonymous'));
      expect(llamada.body, isEmpty);
    });

    test('isAnonymous sale del token, sin ir al servidor', () async {
      final db = await comoInvitado();
      final antes = enviadas.length;

      expect(db.isAnonymous, isTrue);
      expect(enviadas.length, antes);
    });

    test('sin sesión no es anónimo', () {
      expect(cliente().isAnonymous, isFalse);
    });

    test('el perfil trae isAnonymous', () async {
      final user = RobleUser.fromJson({
        'userId': 'g1',
        'email': 'anon_x@anonymous.invalid',
        'name': 'Guest',
        'isAnonymous': true,
      });
      expect(user.isAnonymous, isTrue);
      // Un perfil normal no lo trae y no debe inventárselo.
      expect(RobleUser.fromJson({'userId': 'u1'}).isAnonymous, isFalse);
    });

    // Los dos motivos se arreglan en sitios distintos, así que tienen que
    // llegar distinguibles.
    test('ANON_AUTH_DISABLED llega tipado', () async {
      final db = cliente();
      responder = (_) => jsonErr(403, 'no', codigo: 'ANON_AUTH_DISABLED');

      await expectLater(
        db.signInAnonymously(),
        throwsA(isA<RobleAnonymousAuthException>()
            .having((e) => e.code, 'code', 'ANON_AUTH_DISABLED')),
      );
    });

    test('ANON_REQUIRES_ROW_OWNERSHIP llega tipado', () async {
      final db = cliente();
      responder =
          (_) => jsonErr(409, 'no', codigo: 'ANON_REQUIRES_ROW_OWNERSHIP');

      await expectLater(
        db.signInAnonymously(),
        throwsA(isA<RobleAnonymousAuthException>()
            .having((e) => e.code, 'code', 'ANON_REQUIRES_ROW_OWNERSHIP')),
      );
    });
  });

  // ==========================================================
  group('ascenso a cuenta', () {
    Future<RobleApiDataBase> conInvitado() async {
      final db = cliente();
      responder = (req) => req.url.path.endsWith('/signin-anonymous')
          ? json200({
              'accessToken': token({'sub': 'guest-1', 'isAnonymous': true}),
              'refreshToken': 'rt-1',
            })
          : json200({'userId': 'guest-1'});
      await db.signInAnonymously();
      enviadas.clear();
      return db;
    }

    test('sin verify usa upgrade-direct, con verify usa upgrade', () async {
      final db = await conInvitado();
      responder = (_) => json200({'ok': true});

      await db.upgradeAccount(email: 'a@b.co', password: 'secreta');
      expect(enviadas.any((r) => r.url.path.endsWith('/me/upgrade-direct')),
          isTrue);

      enviadas.clear();
      await db.upgradeAccount(
          email: 'a@b.co', password: 'secreta', verify: true);
      expect(enviadas.any((r) => r.url.path.endsWith('/me/upgrade')), isTrue);
    });

    // Lo importante: tras ascender la pantalla no puede seguir ofreciendo
    // «guarda tu cuenta». El token viejo todavía dice que es invitado.
    test('refresca el token para que isAnonymous deje de ser true', () async {
      final db = await conInvitado();
      expect(db.isAnonymous, isTrue);

      responder = (req) => req.url.path.endsWith('/refresh-token')
          ? json200({
              'accessToken': token({'sub': 'guest-1', 'isAnonymous': false}),
              'refreshToken': 'rt-2',
            })
          : json200({'ok': true});

      await db.upgradeAccount(email: 'a@b.co', password: 'secreta');

      expect(db.isAnonymous, isFalse);
      expect(db.currentUserId, 'guest-1'); // el mismo id: nada se movió
    });

    test('correo ya tomado sale tipado y sigue siendo invitado', () async {
      final db = await conInvitado();
      responder =
          (_) => jsonErr(409, 'ya existe', codigo: 'ANON_UPGRADE_EMAIL_TAKEN');

      await expectLater(
        db.upgradeAccount(email: 'a@b.co', password: 'x'),
        throwsA(isA<RobleAnonUpgradeEmailTakenException>()),
      );
      expect(db.isAnonymous, isTrue);
    });
  });

  // ==========================================================
  group('modo clave publicable', () {
    test('manda la clave como Bearer y deja insertar', () async {
      final db = cliente(anonKey: anonKey);
      responder = (_) => json200({'_id': 'x'});

      await db.create('sugerencias', {'texto': 'hola'});

      expect(db.isAnonKeyMode, isTrue);
      expect(enviadas.last.headers['Authorization'], 'Bearer $anonKey');
      expect(enviadas.last.url.path, endsWith('/insert-one'));
    });

    // El corazón de la función: falla aquí, no en la red.
    test('leer, actualizar y borrar fallan sin salir a la red', () async {
      final db = cliente(anonKey: anonKey);

      for (final accion in <Future<void> Function()>[
        () => db.read('sugerencias'),
        () => db.update('sugerencias', 'id', {'a': 1}),
        () => db.delete('sugerencias', 'id'),
        () => db.currentUser(),
        () => db.login(email: 'a@b.co', password: 'x'),
        () => db.signInAnonymously(),
        () => db.logout(),
      ]) {
        await expectLater(accion(), throwsA(isA<RobleAnonKeyScopeException>()));
      }

      expect(enviadas, isEmpty);
    });

    test('el mensaje dice qué hacer en su lugar', () async {
      final db = cliente(anonKey: anonKey);
      final err = await db.read('x').then<Object?>((_) => null, onError: (e) => e);

      expect('$err', contains('sólo puede insertar'));
      expect('$err', contains('signInAnonymously'));
    });

    test('un cliente normal no está en ese modo', () async {
      final db = cliente();
      responder = (_) => json200([]);

      expect(db.isAnonKeyMode, isFalse);
      await expectLater(db.read('sugerencias'), completes);
    });
  });

  // ==========================================================
  group('validación de la clave al construir', () {
    test('rechaza un PAT, que es el error previsible', () {
      expect(
        () => configCon(anonKey: 'roble_pat_0123456789abcdef_${'a' * 43}'),
        throwsA(isA<ArgumentError>()
            .having((e) => '${e.message}', 'mensaje', contains('servidor'))),
      );
    });

    test('rechaza una clave mal formada', () {
      for (final mala in ['', 'abc', 'eyJhbGciOi.eyJzdWIi.firma']) {
        expect(() => configCon(anonKey: mala), throwsA(isA<ArgumentError>()));
      }
    });

    test('acepta una bien formada', () {
      expect(configCon(anonKey: anonKey).anonKey, anonKey);
    });
  });
}
