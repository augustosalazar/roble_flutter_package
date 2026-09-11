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

http.Response json200(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

http.Response jsonErr(int code, String message) =>
    http.Response(jsonEncode({'message': message}), code,
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

/// Un JWT de mentira: solo importa el payload, que nadie verifica la firma.
String token(Map<String, dynamic> payload) => [
      'cabecera',
      base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', ''),
      'firma',
    ].join('.');

void main() {
  late List<http.Request> enviadas;
  late http.Response Function(http.Request) responder;

  RobleApiDataBase cliente() => RobleApiDataBase(
        config: config,
        client: MockClient((req) async {
          enviadas.add(req);
          return responder(req);
        }),
        storage: MemoriaStorage(),
      );

  /// Cliente con sesión abierta, con [sub] dentro del token.
  Future<RobleApiDataBase> conSesion(String sub) async {
    final db = cliente();
    responder = (req) => req.url.path.endsWith('/login')
        ? json200({'accessToken': token({'sub': sub}), 'refreshToken': 'rt-1'})
        : json200({'userId': sub, 'email': 'ana@correo.com', 'name': 'Ana'});
    await db.login(email: 'ana@correo.com', password: 'secreto');
    responder = (_) => json200({});
    return db;
  }

  Map<String, dynamic> cuerpo() =>
      jsonDecode(enviadas.last.body) as Map<String, dynamic>;

  setUp(() {
    enviadas = [];
    responder = (_) => json200({});
  });

  group('propiedad de la fila', () {
    test('robleOwnerOf lee la columna, y da null si no viene', () {
      expect(robleOwnerOf({robleOwnerColumn: 'u1'}), 'u1');
      // Una tabla puede ocultarla; ahi no se puede saber de quien es.
      expect(robleOwnerOf({'texto': 'hola'}), isNull);
      expect(robleOwnerOf(null), isNull);
    });

    test('currentUserId sale del token, sin ir al servidor', () async {
      final db = await conSesion('u-ana');
      final antes = enviadas.length;

      expect(db.currentUserId, 'u-ana');
      expect(enviadas.length, antes);
    });

    test('isMine compara la fila con la sesion', () async {
      final db = await conSesion('u-ana');

      expect(db.isMine({robleOwnerColumn: 'u-ana'}), isTrue);
      expect(db.isMine({robleOwnerColumn: 'u-bob'}), isFalse);
      // Sin la columna no se sabe: decir que si seria peor que decir que no.
      expect(db.isMine({'texto': 'hola'}), isFalse);
    });

    test('sin sesion no hay id ni fila propia', () {
      final db = cliente();

      expect(db.currentUserId, isNull);
      expect(db.isMine({robleOwnerColumn: 'u-ana'}), isFalse);
    });

    test('_owner no se envia al crear: lo sella el servidor', () async {
      responder = (_) => json200({'_id': '1'});

      await cliente()
          .create('autos', {'placa': 'ABC', robleOwnerColumn: 'u-bob'});

      expect(cuerpo()['record'], {'placa': 'ABC'});
    });

    test('createMany lo quita de cada fila', () async {
      responder = (_) => json200({'inserted': [], 'skipped': []});

      await cliente().createMany('autos', [
        {'placa': 'A', robleOwnerColumn: 'u-bob'},
        {'placa': 'B'},
      ]);

      expect(cuerpo()['records'], [
        {'placa': 'A'},
        {'placa': 'B'},
      ]);
    });

    test('al actualizar tampoco viaja, asi leer-cambiar-escribir vale',
        () async {
      final fila = {
        '_id': '1',
        'placa': 'ABC',
        robleOwnerColumn: 'u-ana',
      };

      await cliente().update('autos', '1', {...fila, 'placa': 'XYZ'});

      expect(cuerpo()['updates'], {'placa': 'XYZ'});
    });
  });

  group('errores del modelo de permisos', () {
    test('un 403 llega como RobleApiForbiddenException', () async {
      responder =
          (_) => jsonErr(403, 'No tienes permisos para DELETE sobre autos');

      await expectLater(
        cliente().delete('autos', '1'),
        throwsA(isA<RobleApiForbiddenException>()),
      );
    });

    test('un 404 llega como RobleApiNotFoundException', () async {
      responder = (_) => jsonErr(404, 'No se encontró un registro con _id=1.');

      await expectLater(
        cliente().delete('autos', '1'),
        // Quien lo capturaba por statusCode lo sigue capturando igual.
        throwsA(isA<RobleApiNotFoundException>()
            .having((e) => e.statusCode, 'statusCode', 404)),
      );
    });

    test('los demas codigos siguen siendo el error de siempre', () async {
      responder = (_) => jsonErr(500, 'boom');

      await expectLater(
        cliente().read('autos'),
        throwsA(isA<RobleApiHttpException>()
            .having((e) => e is RobleApiForbiddenException, 'es 403', isFalse)),
      );
    });
  });

  group('roles', () {
    test('editor_own es el rol de editar lo tuyo', () {
      expect(RobleRole.editorOwn, 'editor_own');
      expect(RobleRole.editor, 'editor');
    });
  });
}
