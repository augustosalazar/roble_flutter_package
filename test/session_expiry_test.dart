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
        // La última respuesta se repite: así una prueba no tiene que adivinar
        // cuántas llamadas hará el paquete por dentro.
        final responder =
            _respuestas.length > 1 ? _respuestas.removeAt(0) : _respuestas.first;
        return responder(req);
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

const perfil = {'userId': 'u1', 'email': 'ana@correo.com', 'name': 'Ana'};
const sesion = {'accessToken': 'at-1', 'refreshToken': 'rt-1'};

class MemoriaStorage implements RobleTokenStorage {
  final Map<String, String> datos = {};

  @override
  Future<String?> getItem(String key) async => datos[key];

  @override
  Future<void> setItem(String key, String value) async => datos[key] = value;

  @override
  Future<void> removeItem(String key) async => datos.remove(key);
}

void main() {
  /// Un cliente con la sesión ya iniciada y el guion listo para lo que venga
  /// después del login.
  Future<RobleApiDataBase> conSesion(Guion guion) async {
    final db = RobleApiDataBase(
      config: config,
      client: guion.cliente,
      storage: MemoriaStorage(),
    );
    await db.login(email: 'ana@correo.com', password: 'secreto');
    return db;
  }

  /// El login gasta dos respuestas: los tokens y el perfil.
  List<http.Response Function(http.Request)> login() => [
        (_) => json200(sesion),
        (_) => json200(perfil),
      ];

  test('avisa cuando el refresco falla', () async {
    final guion = Guion([
      ...login(),
      // La llamada de verdad: el access token ya no vale.
      (_) => jsonErr(401, 'Unauthorized'),
      // El intento de refresco: el refresh token tampoco.
      (_) => jsonErr(401, 'Refresh token inválido'),
    ]);
    final db = await conSesion(guion);

    final avisos = <void>[];
    db.onSessionExpired.listen(avisos.add);

    await expectLater(
      db.read('productos'),
      throwsA(isA<RobleApiAuthException>()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(avisos, hasLength(1));
  });

  test('con la sesión ya descartada cuando avisa', () async {
    // Quien escucha va a mandar a la persona a la pantalla de entrada; si el
    // paquete todavía se creyera dentro, esa pantalla arrancaría con una
    // sesión muerta guardada.
    final guion = Guion([
      ...login(),
      (_) => jsonErr(401, 'Unauthorized'),
      (_) => jsonErr(401, 'Refresh token inválido'),
    ]);
    final db = await conSesion(guion);
    expect(db.isLoggedIn, isTrue);

    bool estabaDentro = true;
    db.onSessionExpired.listen((_) => estabaDentro = db.isLoggedIn);

    await expectLater(db.read('productos'), throwsA(isA<Exception>()));
    await Future<void>.delayed(Duration.zero);

    expect(estabaDentro, isFalse);
    expect(db.isLoggedIn, isFalse);
  });

  test('una sola vez aunque fallen varias llamadas a la vez', () async {
    // Una app pide la lista, el perfil y el chat al entrar. Las tres fallan
    // con el mismo 401 y no hay que avisar tres veces.
    final guion = Guion([
      ...login(),
      (_) => jsonErr(401, 'Unauthorized'),
    ]);
    final db = await conSesion(guion);

    final avisos = <void>[];
    db.onSessionExpired.listen(avisos.add);

    Future<void> sinReventar(Future<Object?> peticion) async {
      try {
        await peticion;
      } catch (_) {}
    }

    await Future.wait([
      sinReventar(db.read('productos')),
      sinReventar(db.read('pedidos')),
      sinReventar(db.read('clientes')),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(avisos, hasLength(1));
  });

  test('no avisa al cerrar sesión a propósito', () async {
    final guion = Guion([...login(), (_) => json200({})]);
    final db = await conSesion(guion);

    final avisos = <void>[];
    db.onSessionExpired.listen(avisos.add);

    await db.logout();
    await Future<void>.delayed(Duration.zero);

    expect(avisos, isEmpty);
  });

  test('no avisa mientras el refresco funcione', () async {
    final guion = Guion([
      ...login(),
      (_) => jsonErr(401, 'Unauthorized'),
      // El refresco sí sale bien...
      (_) => json200({'accessToken': 'at-2', 'refreshToken': 'rt-2'}),
      // ...y la llamada se reintenta con éxito.
      (_) => json200([]),
    ]);
    final db = await conSesion(guion);

    final avisos = <void>[];
    db.onSessionExpired.listen(avisos.add);

    await db.read('productos');
    await Future<void>.delayed(Duration.zero);

    expect(avisos, isEmpty);
    expect(db.isLoggedIn, isTrue);
  });

  test('una sesión nueva vuelve a armar el aviso', () async {
    final guion = Guion([
      ...login(),
      (_) => jsonErr(401, 'Unauthorized'),
      (_) => jsonErr(401, 'Refresh token inválido'),
    ]);
    final db = await conSesion(guion);

    final avisos = <void>[];
    db.onSessionExpired.listen(avisos.add);

    await expectLater(db.read('productos'), throwsA(isA<Exception>()));
    await Future<void>.delayed(Duration.zero);
    expect(avisos, hasLength(1));

    // Se vuelve a entrar y se vuelve a caer: el segundo aviso tiene que salir.
    guion._respuestas
      ..clear()
      ..addAll([
        ...login(),
        (_) => jsonErr(401, 'Unauthorized'),
        (_) => jsonErr(401, 'Refresh token inválido'),
      ]);
    await db.login(email: 'ana@correo.com', password: 'secreto');

    await expectLater(db.read('productos'), throwsA(isA<Exception>()));
    await Future<void>.delayed(Duration.zero);

    expect(avisos, hasLength(2));
  });
}
