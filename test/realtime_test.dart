import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:roble/roble.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// Cliente HTTP con respuestas guionizadas, para las politicas.
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

/// Socket de mentira: apunta lo que se emitio y deja al test entregar lo que
/// entregaria el servidor.
class SocketFalso implements io.Socket {
  SocketFalso(this.url, this.options);

  final String url;
  final Map<String, dynamic> options;

  final emitidos = <({String event, dynamic data})>[];
  final _handlers = <String, List<dynamic Function(dynamic)>>{};
  final pendingAcks = <Function>[];
  bool disposed = false;

  @override
  bool connected = true;

  @override
  Function() on(String event, dynamic Function(dynamic) handler) {
    _handlers.putIfAbsent(event, () => []).add(handler);
    return () {};
  }

  // No estan en la interfaz Socket, sino puestos por el emisor de eventos,
  // asi que no llevan @override.
  void onConnect(dynamic Function(dynamic) handler) => on('connect', handler);

  void onDisconnect(dynamic Function(dynamic) handler) =>
      on('disconnect', handler);

  @override
  void emit(String event, [dynamic data]) {
    emitidos.add((event: event, data: data));
  }

  @override
  void emitWithAck(
    String event,
    dynamic data, {
    Function? ack,
    bool binary = false,
  }) {
    emitidos.add((event: event, data: data));
    if (ack != null) pendingAcks.add(ack);
  }

  @override
  io.Socket dispose() {
    disposed = true;
    connected = false;
    return this;
  }

  /// Lo que hace el servidor cuando manda algo.
  void entregar(String event, dynamic data) {
    for (final h in [...(_handlers[event] ?? [])]) {
      h(data);
    }
  }

  /// Acepta la ultima suscripcion pedida.
  void aceptarSuscripcion(String id) {
    final ack = pendingAcks.removeAt(0);
    ack({'type': 'subscription_created', 'subscriptionId': id});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> cambio({
  required String subscriptionId,
  String operation = 'INSERT',
  String table = 'products',
  Map<String, dynamic>? nuevo,
  Map<String, dynamic>? viejo,
}) =>
    {
      'eventId': 'e1',
      'subscriptionId': subscriptionId,
      'dbName': 'proyecto_ab12',
      'schema': 'public',
      'table': table,
      'operation': operation,
      'commitTimestamp': '2026-08-25T12:00:00.000Z',
      'cursor': 'c1',
      'primaryKey': {'_id': 'r1'},
      'old': viejo,
      'new': nuevo,
    };

void main() {
  late SocketFalso socket;
  late List<SocketFalso> creados;

  RobleRealtimeClient construir({
    String? token = 'at-1',
    String? Function()? tokenFn,
    Duration subscribeTimeout = const Duration(seconds: 10),
  }) {
    creados = [];
    return RobleRealtimeClient(
      origin: 'https://roble-api.test',
      dbName: 'proyecto_ab12',
      accessToken: tokenFn ?? () => token,
      subscribeTimeout: subscribeTimeout,
      socketFactory: (url, options) {
        socket = SocketFalso(url, options);
        creados.add(socket);
        return socket;
      },
    );
  }

  group('conexion', () {
    test('se conecta al namespace /stream con token y proyecto', () async {
      final client = construir();

      client.watch('products').listen((_) {});
      await Future<void>.delayed(Duration.zero);

      expect(socket.url, 'https://roble-api.test/stream');
      expect(socket.options['query'],
          {'token': 'at-1', 'dbName': 'proyecto_ab12'});
      // Sin respaldo de long-polling no hacen falta sesiones pegajosas cuando
      // el servidor corre con varios workers.
      expect(socket.options['transports'], ['websocket']);
    });

    test('no abre socket hasta que alguien escucha', () async {
      final client = construir();

      final stream = client.watch('products');
      await Future<void>.delayed(Duration.zero);
      expect(client.isConnected, isFalse);

      stream.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(client.isConnected, isTrue);
    });

    test('sin sesion avisa en vez de conectar', () async {
      final client = construir(token: null);

      await expectLater(
        client.watch('products'),
        emitsError(isA<RobleApiAuthException>()),
      );
    });
  });

  group('suscripcion', () {
    test('pide la tabla con las tres operaciones por omision', () async {
      final client = construir();
      client.watch('products').listen((_) {});
      await Future<void>.delayed(Duration.zero);

      final sub = socket.emitidos.single;
      expect(sub.event, 'subscribe');
      expect(sub.data['table'], 'products');
      expect(sub.data['events'], ['INSERT', 'UPDATE', 'DELETE']);
    });

    test('limita las operaciones cuando se piden', () async {
      final client = construir();
      client
          .watch('products', events: [RobleChangeType.insert])
          .listen((_) {});
      await Future<void>.delayed(Duration.zero);

      expect(socket.emitidos.single.data['events'], ['INSERT']);
    });

    test('manda los filtros para que el servidor descarte antes de enviar',
        () async {
      final client = construir();
      client.watch('products', filters: [
        const RobleFilter.equals('_id', 'r1'),
      ]).listen((_) {});
      await Future<void>.delayed(Duration.zero);

      // Plano: envuelto en `simple` el servidor no ve el operador y su
      // `default` deja pasar todo, que es peor que rechazar.
      expect(socket.emitidos.single.data['filters'], [
        {'column': '_id', 'operator': 'eq', 'value': 'r1'}
      ]);
    });

    test('avisa por el stream si el servidor rechaza la suscripcion', () async {
      final client = construir();
      final stream = client.watch('products');
      final errores = <Object>[];
      stream.listen((_) {}, onError: errores.add);
      await Future<void>.delayed(Duration.zero);

      socket.pendingAcks.removeAt(0)({'message': 'Cuota superada'});
      await Future<void>.delayed(Duration.zero);

      expect(errores.single.toString(), contains('Cuota superada'));
    });
  });

  group('entrega', () {
    test('convierte un cambio del servidor en RobleChange', () async {
      final client = construir();
      final vistos = <RobleChange>[];
      client.watch('products').listen(vistos.add);
      await Future<void>.delayed(Duration.zero);
      socket.aceptarSuscripcion('s1');

      socket.entregar(
        'data_change',
        cambio(subscriptionId: 's1', nuevo: {'_id': 'r1', 'name': 'Café'}),
      );
      await Future<void>.delayed(Duration.zero);

      expect(vistos.single.type, RobleChangeType.insert);
      expect(vistos.single.record, {'_id': 'r1', 'name': 'Café'});
      expect(vistos.single.id, 'r1');
      expect(vistos.single.table, 'products');
    });

    test('acepta una lista, que es lo que llega cuando se agrupan', () async {
      final client = construir();
      final vistos = <RobleChange>[];
      client.watch('products').listen(vistos.add);
      await Future<void>.delayed(Duration.zero);
      socket.aceptarSuscripcion('s1');

      socket.entregar('data_change', [
        cambio(subscriptionId: 's1', nuevo: {'_id': 'r1'}),
        cambio(subscriptionId: 's1', operation: 'DELETE', viejo: {'_id': 'r1'}),
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(vistos, hasLength(2));
      expect(vistos.last.type, RobleChangeType.delete);
      expect(vistos.last.record, isNull);
    });

    test('cada stream recibe solo lo suyo', () async {
      final client = construir();
      final productos = <RobleChange>[];
      final pedidos = <RobleChange>[];
      client.watch('products').listen(productos.add);
      client.watch('orders').listen(pedidos.add);
      await Future<void>.delayed(Duration.zero);
      socket.aceptarSuscripcion('s-products');
      socket.aceptarSuscripcion('s-orders');

      socket.entregar('data_change',
          cambio(subscriptionId: 's-orders', table: 'orders'));
      await Future<void>.delayed(Duration.zero);

      // Un solo socket sirve a todas las suscripciones, asi que separarlas por
      // subscriptionId es lo unico que impide mezclar tablas.
      expect(productos, isEmpty);
      expect(pedidos, hasLength(1));
    });

    test('una operacion desconocida no tumba el stream', () async {
      final client = construir();
      final vistos = <RobleChange>[];
      final errores = <Object>[];
      client.watch('products').listen(vistos.add, onError: errores.add);
      await Future<void>.delayed(Duration.zero);
      socket.aceptarSuscripcion('s1');

      socket.entregar('data_change',
          cambio(subscriptionId: 's1', operation: 'TRUNCATE'));
      await Future<void>.delayed(Duration.zero);

      expect(vistos, isEmpty);
      expect(errores, isEmpty);
    });
  });

  group('reconexion', () {
    test('vuelve a pedir las suscripciones al reconectar', () async {
      final client = construir();
      client.watch('products').listen((_) {});
      await Future<void>.delayed(Duration.zero);
      socket.aceptarSuscripcion('s1');
      socket.emitidos.clear();

      socket.entregar('connect', null);
      await Future<void>.delayed(Duration.zero);

      // El servidor no recuerda las suscripciones de un socket caido. Sin
      // rehacerlas queda un stream abierto que ya no recibe nada, que es peor
      // que un error.
      expect(socket.emitidos.single.event, 'subscribe');
      expect(socket.emitidos.single.data['table'], 'products');
    });

    test('usa el subscriptionId nuevo tras reconectar', () async {
      final client = construir();
      final vistos = <RobleChange>[];
      client.watch('products').listen(vistos.add);
      await Future<void>.delayed(Duration.zero);
      socket.aceptarSuscripcion('s1');

      socket.entregar('connect', null);
      await Future<void>.delayed(Duration.zero);
      socket.aceptarSuscripcion('s2');

      socket.entregar('data_change', cambio(subscriptionId: 's2'));
      await Future<void>.delayed(Duration.zero);

      expect(vistos, hasLength(1));
    });
  });

  group('cancelacion', () {
    test('avisa al servidor y cierra el socket al irse el ultimo oyente',
        () async {
      final client = construir();
      final sub = client.watch('products').listen((_) {});
      await Future<void>.delayed(Duration.zero);
      socket.aceptarSuscripcion('s1');
      socket.emitidos.clear();

      await sub.cancel();
      await Future<void>.delayed(Duration.zero);

      expect(socket.emitidos.single.event, 'unsubscribe');
      expect(socket.emitidos.single.data['subscriptionId'], 's1');
      // El servidor desconecta igualmente a quien no tiene suscripciones.
      expect(socket.disposed, isTrue);
    });

    test('mantiene el socket mientras quede otra suscripcion', () async {
      final client = construir();
      final sub = client.watch('products').listen((_) {});
      client.watch('orders').listen((_) {});
      await Future<void>.delayed(Duration.zero);
      socket.aceptarSuscripcion('s1');
      socket.aceptarSuscripcion('s2');

      await sub.cancel();
      await Future<void>.delayed(Duration.zero);

      expect(socket.disposed, isFalse);
    });
  });

  group('fallos del servidor', () {
    test('un subscribe rechazado llega al stream, no se queda mudo', () async {
      final client = construir();
      final errores = <Object>[];
      client.watch('products').listen((_) {}, onError: errores.add);
      await Future<void>.delayed(Duration.zero);

      // El servidor rechaza con WsException, que Nest manda por `exception` y
      // no por el ack ni por `error`. Sin escucharlo, la suscripcion se
      // quedaba pendiente para siempre y el stream abierto sin recibir nada.
      socket.entregar('exception', {
        'code': 'REALTIME_QUOTA_EXCEEDED',
        'message': 'Cuota superada',
      });
      await Future<void>.delayed(Duration.zero);

      expect(errores.single.toString(), contains('Cuota superada'));
    });

    test('atribuye el fallo a la suscripcion mas antigua sin responder',
        () async {
      final client = construir();
      final primero = <Object>[];
      final segundo = <Object>[];
      client.watch('products').listen((_) {}, onError: primero.add);
      client.watch('orders').listen((_) {}, onError: segundo.add);
      await Future<void>.delayed(Duration.zero);

      socket.entregar('exception', {'message': 'no'});
      await Future<void>.delayed(Duration.zero);

      // El `exception` no dice a cual se refiere y el servidor los atiende en
      // orden, asi que le toca al primero.
      expect(primero, hasLength(1));
      expect(segundo, isEmpty);
    });

    test('un silencio del servidor acaba en error y no en espera eterna',
        () async {
      final client = construir(
        subscribeTimeout: const Duration(milliseconds: 20),
      );
      final errores = <Object>[];
      client.watch('products').listen((_) {}, onError: errores.add);
      await Future<void>.delayed(Duration.zero);

      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(errores.single, isA<RobleApiTimeoutException>());
    });

    test('distingue una cuota de un problema de sesion', () async {
      final client = construir();
      final errores = <Object>[];
      client.watch('products').listen((_) {}, onError: errores.add);
      await Future<void>.delayed(Duration.zero);

      socket.entregar('error', {
        'code': 'REALTIME_SERVER_FULL',
        'message': 'Server at max capacity',
      });
      await Future<void>.delayed(Duration.zero);

      // Todo salia como error de autenticacion, lo que mandaba a cerrar sesion
      // por algo que no lo era.
      expect(errores.single, isNot(isA<RobleApiAuthException>()));
      expect(errores.single.toString(), contains('max capacity'));
    });
  });

  group('identificador de peticion', () {
    test('se genera sin reventar y es distinto cada vez', () async {
      final guion = Guion([
        for (var i = 0; i < 5; i++) (_) => json200({'url': 'https://p.test/go'}),
      ]);
      final client = construir();
      final vistos = <String>{};

      for (var i = 0; i < 5; i++) {
        client.watch('t$i').listen((_) {});
        await Future<void>.delayed(Duration.zero);
        vistos.add(socket.emitidos.last.data['requestId'] as String);
      }

      // En web el limite `1 << 32` hacia que nextInt lanzara RangeError justo
      // antes de emitir el subscribe: el socket conectaba y no se suscribia
      // nadie.
      expect(vistos, hasLength(5));
      expect(guion.peticiones, isEmpty);
    });
  });

  group('politicas de tiempo real', () {
    late Guion guion;
    RobleApiDataBase cliente(Guion g) => RobleApiDataBase(
          config: RobleApiConfig.fromContract(
            baseUrl: 'https://roble-api.test',
            contractId: 'proyecto_ab12',
          ),
          client: g.cliente,
          storage: RobleMemoryStorage(),
        );

    test('lista las politicas del proyecto', () async {
      guion = Guion([(_) => json200([_politica])]);

      final politicas = await cliente(guion).realtimePolicies();

      // La configuracion cuelga de /realtime/config, no de /realtime/{contrato}.
      expect(guion.peticiones.first.url.path,
          '/realtime/config/proyecto_ab12/policies');
      expect(politicas.single.table, 'orders');
      expect(politicas.single.access, RobleRealtimeAccess.ownerOnly);
      expect(politicas.single.events,
          [RobleChangeType.insert, RobleChangeType.update]);
      expect(politicas.single.includeOldRecord, isFalse);
    });

    test('lee la de una tabla', () async {
      guion = Guion([(_) => json200(_politica)]);

      final politica = await cliente(guion).realtimePolicy('orders');

      expect(guion.peticiones.first.url.path,
          '/realtime/config/proyecto_ab12/policies/public/orders');
      expect(politica!.allowedFilterColumns, ['status']);
      expect(politica.rowPolicy, {'column': 'user_id'});
    });

    test('una tabla sin politica devuelve null, no un error', () async {
      guion = Guion([(_) => http.Response('', 200)]);

      // Sin politica la tabla emite igual: no tenerla no es un fallo.
      expect(await cliente(guion).realtimePolicy('orders'), isNull);
    });

    test('guarda la politica con la tabla en la ruta', () async {
      guion = Guion([(_) => json200(_politica)]);

      await cliente(guion).setRealtimePolicy(const RobleTablePolicy(
        table: 'orders',
        enabled: true,
        events: [RobleChangeType.insert],
        access: RobleRealtimeAccess.roleBased,
      ));

      final peticion = guion.peticiones.first;
      expect(peticion.method, 'PUT');
      expect(peticion.url.path,
          '/realtime/config/proyecto_ab12/policies/public/orders');
      final cuerpo = jsonDecode(peticion.body) as Map;
      expect(cuerpo['allowedEvents'], ['INSERT']);
      // El servidor escribe los niveles con guion bajo.
      expect(cuerpo['accessLevel'], 'role_based');
      expect(cuerpo.containsKey('tableName'), isFalse);
    });

    test('deshabilitar usa DELETE', () async {
      guion = Guion([(_) => json200({'success': true})]);

      await cliente(guion).disableRealtime('orders');

      expect(guion.peticiones.first.method, 'DELETE');
      expect(guion.peticiones.first.url.path,
          '/realtime/config/proyecto_ab12/policies/public/orders');
    });

    test('manda el bearer: la configuracion no es publica', () async {
      guion = Guion([(_) => json200([])]);
      final almacen = RobleMemoryStorage();
      await almacen.setItem(
        'roble.session.proyecto_ab12',
        jsonEncode({'accessToken': 'at-1', 'refreshToken': 'rt-1'}),
      );
      final db = RobleApiDataBase(
        config: RobleApiConfig.fromContract(
          baseUrl: 'https://roble-api.test',
          contractId: 'proyecto_ab12',
        ),
        client: guion.cliente,
        storage: almacen,
      );
      await db.restoreSession(verify: false);

      await db.realtimePolicies();

      expect(guion.peticiones.first.headers.containsKey('Authorization'),
          isTrue);
    });
  });

  group('token al reconectar', () {
    test('rehace el socket con el token vigente', () async {
      var token = 'viejo';
      final client = construir(tokenFn: () => token);
      client.watch('products').listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(creados.single.options['query']['token'], 'viejo');

      // El access token dura quince minutos. socket.io reintentaria con las
      // opciones originales, asi que tras caducar todos sus reintentos irian
      // con el token viejo y el servidor los rechazaria uno tras otro.
      token = 'nuevo';
      socket.entregar('disconnect', null);
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(creados, hasLength(2));
      expect(creados.last.options['query']['token'], 'nuevo');
    });

    test('deja que este cliente lleve la reconexion', () async {
      final client = construir();
      client.watch('products').listen((_) {});
      await Future<void>.delayed(Duration.zero);

      expect(socket.options['reconnection'], isFalse);
    });

    test('no reconecta despues de cerrar', () async {
      final client = construir();
      client.watch('products').listen((_) {});
      await Future<void>.delayed(Duration.zero);

      await client.close();
      socket.entregar('disconnect', null);
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(creados, hasLength(1));
    });
  });
}

// ---------------------------------------------------------------------------
// CRUD de las politicas de tiempo real (la configuracion, no los datos).
// ---------------------------------------------------------------------------

const _politica = {
  'id': 'p1',
  'dbName': 'proyecto_ab12',
  'schemaName': 'public',
  'tableName': 'orders',
  'enabled': true,
  'allowedEvents': ['INSERT', 'UPDATE'],
  'accessLevel': 'owner_only',
  'includeOldRecord': false,
  'allowedFilterColumns': ['status'],
  'rowPolicy': {'column': 'user_id'},
};
