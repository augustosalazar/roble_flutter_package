import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:roble/roble.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// Socket de mentira, igual que el de realtime_test pero solo con lo que este
/// fichero necesita.
class SocketFalso implements io.Socket {
  SocketFalso(this.url, this.options);

  final String url;
  final Map<String, dynamic> options;
  final _handlers = <String, List<dynamic Function(dynamic)>>{};
  final pendingAcks = <Function>[];

  @override
  bool connected = true;

  @override
  Function() on(String event, dynamic Function(dynamic) handler) {
    _handlers.putIfAbsent(event, () => []).add(handler);
    return () {};
  }

  @override
  void emit(String event, [dynamic data]) {}

  @override
  void emitWithAck(String event, dynamic data,
      {Function? ack, bool binary = false}) {
    if (ack != null) pendingAcks.add(ack);
  }

  @override
  io.Socket dispose() {
    connected = false;
    return this;
  }

  void entregar(String event, dynamic data) {
    for (final h in [...(_handlers[event] ?? [])]) {
      h(data);
    }
  }

  void aceptarSuscripcion(String id) =>
      pendingAcks.removeAt(0)({'type': 'subscription_created', 'subscriptionId': id});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Cambio tal como lo publica el modulo JSON: `path` empieza por la coleccion
/// y `new` trae solo lo escrito, no la coleccion entera.
Map<String, dynamic> cambioJson({
  required String subscriptionId,
  required List<String> path,
  Map<String, dynamic>? nuevo,
  String operation = 'INSERT',
}) =>
    {
      'eventId': 'e1',
      'subscriptionId': subscriptionId,
      'dbName': 'proyecto_ab12',
      'schema': 'public',
      'table': path.first,
      'path': path,
      'operation': operation,
      'commitTimestamp': '2026-08-25T12:00:00.000Z',
      'cursor': '',
      'primaryKey': const <String, dynamic>{},
      'old': null,
      'new': nuevo,
    };

void main() {
  late List<http.Request> peticiones;
  late SocketFalso socket;

  /// Cliente con un HTTP guionizado por una sola respuesta reutilizable.
  RobleApiDataBase construir(Object respuesta) {
    peticiones = [];
    return RobleApiDataBase(
      config: RobleApiConfig.fromContract(
        baseUrl: 'https://roble-api.test',
        contractId: 'proyecto_ab12',
      ),
      // Sesion ya iniciada: el socket lleva el access token, y sin el la
      // escucha falla antes de abrirse.
      storage: MemoriaStorage({
        'roble.session.proyecto_ab12':
            '{"accessToken":"at-1","refreshToken":"rt-1"}',
      }),
      client: MockClient((req) async {
        peticiones.add(req);
        return http.Response(jsonEncode(respuesta), 200,
            headers: {'content-type': 'application/json'});
      }),
      socketFactory: (url, options) => socket = SocketFalso(url, options),
    );
  }

  group('rutas', () {
    test('la coleccion y sus hijos van en la URL', () async {
      final db = construir({'ok': true});

      await db.json.read('mensajes/abc/texto');

      expect(peticiones.single.url.path,
          '/realtime/proyecto_ab12/mensajes/abc/texto');
    });

    test('escapa cada segmento por separado', () async {
      final db = construir({'ok': true});

      // Sin escapar, el `/` partiria la ruta en dos segmentos y el `?` se
      // llevaria por delante el resto de la URL.
      await db.json.read('mensajes/a b?c');

      expect(peticiones.single.url.path,
          '/realtime/proyecto_ab12/mensajes/a%20b%3Fc');
    });

    test('shallow viaja como query', () async {
      final db = construir({'ok': true});

      await db.json.read('mensajes', shallow: true);

      expect(peticiones.single.url.queryParameters['shallow'], 'true');
    });

    test('listar colecciones pega a la raiz del proyecto', () async {
      final db = construir(['mensajes', 'usuarios']);

      expect(await db.json.collections(), ['mensajes', 'usuarios']);
      // Sin barra final: es la ruta que la consola usa contra el mismo
      // endpoint, y no toda ruta tolera la barra de mas.
      expect(peticiones.single.url.path, '/realtime/proyecto_ab12');
    });
  });

  group('escritura', () {
    test('push devuelve la clave que genero el servidor', () async {
      final db = construir({'name': '-Nabc123'});

      final id = await db.json.push('mensajes', {'texto': 'hola'});

      expect(id, '-Nabc123');
      expect(peticiones.single.method, 'POST');
      expect(jsonDecode(peticiones.single.body), {'texto': 'hola'});
    });

    test('update usa PATCH, que respeta las claves que no vienen', () async {
      final db = construir({'ok': true});

      await db.json.update('mensajes/abc', {'leido': true});

      // Con PUT se perderia el texto del mensaje.
      expect(peticiones.single.method, 'PATCH');
    });

    test('write usa PUT', () async {
      final db = construir({'ok': true});
      await db.json.write('mensajes/abc', {'texto': 'hola'});
      expect(peticiones.single.method, 'PUT');
    });
  });

  group('escucha', () {
    /// Suscribe y devuelve lo que vaya llegando.
    Future<List<RobleChange>> escuchar(
      RobleApiDataBase db,
      String path,
      List<Map<String, dynamic>> eventos,
    ) async {
      await db.restoreSession(verify: false);
      final recibidos = <RobleChange>[];
      db.json.watch(path).listen(recibidos.add);
      await Future<void>.delayed(Duration.zero);
      socket.aceptarSuscripcion('s1');
      await Future<void>.delayed(Duration.zero);
      for (final e in eventos) {
        socket.entregar('data_change', e);
      }
      await Future<void>.delayed(Duration.zero);
      return recibidos;
    }

    test('un push a la coleccion llega con su clave y su contenido', () async {
      final db = construir({'ok': true});

      final recibidos = await escuchar(db, 'mensajes', [
        cambioJson(
          subscriptionId: 's1',
          path: ['mensajes'],
          nuevo: {'-Nabc': {'texto': 'hola'}},
        ),
      ]);

      expect(recibidos.single.path, ['mensajes']);
      expect(recibidos.single.record, {'-Nabc': {'texto': 'hola'}});
    });

    test('escuchando una rama no llega lo de una hermana', () async {
      final db = construir({'ok': true});

      final recibidos = await escuchar(db, 'salas/general', [
        cambioJson(subscriptionId: 's1', path: ['salas', 'general', 'm1']),
        cambioJson(subscriptionId: 's1', path: ['salas', 'privada', 'm2']),
      ]);

      // La suscripcion es por coleccion, asi que el servidor manda las dos
      // salas: la de al lado se descarta aqui.
      expect(recibidos.map((c) => c.path.last), ['m1']);
    });

    test('llega un cambio escrito por encima de la rama escuchada', () async {
      final db = construir({'ok': true});

      final recibidos = await escuchar(db, 'salas/general/mensajes', [
        cambioJson(subscriptionId: 's1', path: ['salas', 'general']),
      ]);

      // Reemplazar el padre cambia al hijo aunque nadie lo nombre; descartarlo
      // dejaria la pantalla mostrando algo que ya no existe.
      expect(recibidos, hasLength(1));
    });

    test('sin coleccion no hay nada que escuchar', () {
      final db = construir({'ok': true});

      expect(() => db.json.watch('/'), throwsArgumentError);
    });
  });
}

/// Almacen en memoria, para no tocar el llavero del sistema.
class MemoriaStorage implements RobleTokenStorage {
  MemoriaStorage([Map<String, String>? inicial])
      : _datos = {...?inicial};

  final Map<String, String> _datos;

  @override
  Future<String?> getItem(String key) async => _datos[key];

  @override
  Future<void> setItem(String key, String value) async => _datos[key] = value;

  @override
  Future<void> removeItem(String key) async => _datos.remove(key);
}
