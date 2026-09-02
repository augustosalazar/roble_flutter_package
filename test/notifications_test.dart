import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:roble/roble.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// Socket de mentira: apunta lo emitido y deja al test entregar eventos.
class SocketFalso implements io.Socket {
  SocketFalso(this.url, this.options);

  final String url;
  final Map<String, dynamic> options;

  final emitidos = <({String event, dynamic data})>[];
  final _handlers = <String, List<dynamic Function(dynamic)>>{};
  bool disposed = false;

  @override
  bool connected = true;

  @override
  Function() on(String event, dynamic Function(dynamic) handler) {
    _handlers.putIfAbsent(event, () => []).add(handler);
    return () {};
  }

  void onConnect(dynamic Function(dynamic) handler) => on('connect', handler);

  void onDisconnect(dynamic Function(dynamic) handler) =>
      on('disconnect', handler);

  @override
  void emit(String event, [dynamic data]) {
    emitidos.add((event: event, data: data));
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

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> notificacionJson({
  String id = 'n-1',
  String recipientId = 'user-1',
  String title = 'Hola',
  String? readAt,
}) =>
    {
      'id': id,
      'dbName': 'proyecto_ab12',
      'recipientId': recipientId,
      'senderId': 'user-2',
      'topic': 'chat',
      'title': title,
      'body': 'Cuerpo',
      'data': {'chatId': '42'},
      'readAt': readAt,
      'createdAt': '2026-09-02T10:00:00.000Z',
      'expiresAt': null,
    };

http.Response json200(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {
      'content-type': 'application/json',
    });

void main() {
  late List<SocketFalso> creados;

  RobleNotificationsClient construir({String? token = 'at-1'}) {
    creados = [];
    return RobleNotificationsClient(
      origin: 'https://roble-api.test',
      dbName: 'proyecto_ab12',
      accessToken: () => token,
      socketFactory: (url, options) {
        final s = SocketFalso(url, options);
        creados.add(s);
        return s;
      },
    );
  }

  group('conexion', () {
    test('va al namespace de notificaciones, no al de datos', () async {
      final client = construir();
      client.watch().listen((_) {});
      await Future<void>.delayed(Duration.zero);

      expect(creados, hasLength(1));
      expect(creados.first.url, 'https://roble-api.test/notifications');
      expect(creados.first.options['query'],
          {'token': 'at-1', 'dbName': 'proyecto_ab12'});
    });

    test('no manda ningun subscribe: conectarse es todo el protocolo',
        () async {
      final client = construir();
      client.watch().listen((_) {});
      await Future<void>.delayed(Duration.zero);

      creados.first.entregar('connect', null);
      expect(creados.first.emitidos, isEmpty);
    });

    test('sin sesion avisa por el stream en vez de abrir socket', () async {
      final client = construir(token: null);
      final errores = <Object>[];
      client.watch().listen((_) {}, onError: errores.add);
      await Future<void>.delayed(Duration.zero);

      expect(creados, isEmpty);
      expect(errores.single, isA<RobleApiAuthException>());
    });

    test('un solo socket aunque haya varios oyentes', () async {
      final client = construir();
      client.watch().listen((_) {});
      client.watch().listen((_) {});
      await Future<void>.delayed(Duration.zero);

      expect(creados, hasLength(1));
    });

    test('el socket se suelta cuando se va el ultimo oyente', () async {
      final client = construir();
      final a = client.watch().listen((_) {});
      final b = client.watch().listen((_) {});
      await Future<void>.delayed(Duration.zero);

      await a.cancel();
      expect(creados.first.disposed, isFalse);

      await b.cancel();
      expect(creados.first.disposed, isTrue);
    });
  });

  group('entrega', () {
    test('reparte la notificacion a todos los oyentes', () async {
      final client = construir();
      final a = <RobleNotificationEvent>[];
      final b = <RobleNotificationEvent>[];
      client.watch().listen(a.add);
      client.watch().listen(b.add);
      await Future<void>.delayed(Duration.zero);

      creados.first.entregar('notification', {
        'type': 'created',
        'notification': notificacionJson(),
      });
      await Future<void>.delayed(Duration.zero);

      expect(a, hasLength(1));
      expect(b, hasLength(1));
      expect(a.first.type, RobleNotificationEventType.created);
      expect(a.first.notification.title, 'Hola');
      expect(a.first.notification.data, {'chatId': '42'});
      expect(a.first.notification.isUnread, isTrue);
    });

    test('un tipo desconocido no tira el stream', () async {
      final client = construir();
      final recibidas = <RobleNotificationEvent>[];
      final errores = <Object>[];
      client.watch().listen(recibidas.add, onError: errores.add);
      await Future<void>.delayed(Duration.zero);

      creados.first.entregar('notification', {
        'type': 'inventado',
        'notification': notificacionJson(),
      });
      creados.first.entregar('notification', {
        'type': 'created',
        'notification': notificacionJson(),
      });
      await Future<void>.delayed(Duration.zero);

      expect(errores, isEmpty);
      expect(recibidas, hasLength(1));
    });

    test('el contador llega al conectar, sin pedirlo', () async {
      final client = construir();
      final contadores = <int>[];
      client.unreadCount.listen(contadores.add);
      client.watch().listen((_) {});
      await Future<void>.delayed(Duration.zero);

      creados.first.entregar('connected', {'unread': 4});
      await Future<void>.delayed(Duration.zero);

      expect(client.unread, 4);
      expect(contadores, [4]);
    });

    test('un error del servidor llega a quien escucha', () async {
      final client = construir();
      final errores = <Object>[];
      client.watch().listen((_) {}, onError: errores.add);
      await Future<void>.delayed(Duration.zero);

      creados.first.entregar('error', {
        'code': 'NOTIFICATIONS_UNAUTHORIZED',
        'message': 'Token invalido o expirado',
      });
      await Future<void>.delayed(Duration.zero);

      expect(errores.single, isA<RobleApiAuthException>());
    });
  });

  group('API REST', () {
    late List<http.Request> peticiones;

    RobleApiDataBase cliente(List<http.Response Function(http.Request)> guion) {
      peticiones = [];
      return RobleApiDataBase(
        config: RobleApiConfig.fromContract(
          baseUrl: 'https://roble-api.test',
          contractId: 'proyecto_ab12',
        ),
        client: MockClient((req) async {
          peticiones.add(req);
          return guion.removeAt(0)(req);
        }),
      );
    }

    test('cuelgan de /realtime/notifications, no del arbol JSON', () async {
      final db = cliente([(_) => json200([notificacionJson()])]);

      await db.notifications.list();

      expect(peticiones.single.url.path,
          '/realtime/notifications/proyecto_ab12');
    });

    test('enviar a una sola persona la manda como lista', () async {
      final db = cliente([(_) => json200([notificacionJson()])]);

      await db.notifications.send(to: 'user-1', title: 'Hola');

      final body = jsonDecode(peticiones.single.body) as Map;
      expect(body['recipients'], ['user-1']);
      expect(body['title'], 'Hola');
    });

    test('el comodin manda a todo el proyecto', () async {
      final db = cliente([
        (_) => json200([notificacionJson(recipientId: '*')])
      ]);

      final creadas = await db.notifications.send(
        to: robleNotificationEveryone,
        title: 'Aviso',
      );

      final body = jsonDecode(peticiones.single.body) as Map;
      expect(body['recipients'], ['*']);
      expect(creadas.single.isForEveryone, isTrue);
    });

    test('unread viaja como cadena, que es lo que lee el servidor', () async {
      final db = cliente([(_) => json200([])]);

      await db.notifications.list(unread: true, topic: 'chat', limit: 10);

      expect(peticiones.single.url.queryParameters,
          {'unread': 'true', 'topic': 'chat', 'limit': '10'});
    });

    test('el contador vuelve como numero', () async {
      final db = cliente([(_) => json200({'count': 5})]);
      expect(await db.notifications.unreadCount(), 5);
    });

    test('marcar todas dice cuantas cambiaron', () async {
      final db = cliente([(_) => json200({'marked': 3})]);
      expect(await db.notifications.markAllRead(), 3);
    });

    test('el id va escapado en la ruta', () async {
      final db = cliente([(_) => json200(notificacionJson())]);

      await db.notifications.markRead('a/b');

      expect(peticiones.single.url.path,
          '/realtime/notifications/proyecto_ab12/a%2Fb/read');
    });
  });
}
