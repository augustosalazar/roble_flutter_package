import 'dart:async';
import 'dart:math';

import 'package:socket_io_client/socket_io_client.dart' as io;

import 'roble_api_exception.dart';
import 'roble_realtime.dart';

/// Como se abre el socket. Existe para poder sustituirlo en pruebas.
typedef RobleSocketFactory = io.Socket Function(
    String url, Map<String, dynamic> options);

io.Socket _defaultSocketFactory(String url, Map<String, dynamic> options) =>
    io.io(url, options);

/// Una suscripcion viva, con lo necesario para volver a pedirla.
class _Watch {
  _Watch({
    required this.table,
    required this.schema,
    required this.events,
    required this.filters,
    required this.controller,
  });

  final String table;
  final String schema;
  final List<RobleChangeType> events;
  final List<RobleFilter> filters;
  final StreamController<RobleChange> controller;

  /// Lo asigna el servidor al aceptar la suscripcion. Cambia al reconectar.
  String? subscriptionId;

  /// Corre mientras se espera respuesta a un `subscribe`.
  Timer? pendingTimeout;

  void fail(Object error) {
    if (!controller.isClosed) controller.addError(error);
  }
}

/// Mantiene el socket y las suscripciones abiertas contra el servicio Realtime.
///
/// Un solo socket sirve a todas las suscripciones: el servidor las distingue
/// por `subscriptionId` y limita cuantas admite por cliente, asi que abrir uno
/// por tabla se quedaria corto enseguida.
class RobleRealtimeClient {
  RobleRealtimeClient({
    required this.origin,
    required this.dbName,
    required String? Function() accessToken,
    RobleSocketFactory? socketFactory,
    this.subscribeTimeout = const Duration(seconds: 10),
  })  : _accessToken = accessToken,
        _socketFactory = socketFactory ?? _defaultSocketFactory;

  /// Host del servicio, sin ruta: el namespace se le pega aparte.
  final String origin;

  /// Contrato del proyecto. El servidor comprueba que coincida con el del token.
  final String dbName;

  /// Cuanto se espera a que el servidor acepte o rechace una suscripcion.
  final Duration subscribeTimeout;

  final String? Function() _accessToken;
  final RobleSocketFactory _socketFactory;

  io.Socket? _socket;
  final _watches = <_Watch>[];

  /// Suscripciones pedidas y sin respuesta, en el orden en que se pidieron.
  ///
  /// El servidor rechaza una suscripcion con un `exception` que no dice a cual
  /// se refiere, y las procesa en orden, asi que la mas antigua sin responder
  /// es la que fallo.
  final _pending = <_Watch>[];

  final _random = Random();
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _closing = false;

  bool get isConnected => _socket?.connected ?? false;

  /// Escucha los cambios de [table].
  ///
  /// La suscripcion se pide cuando alguien empieza a escuchar y se cancela
  /// cuando se va el ultimo oyente, asi que un stream que nadie usa no cuesta
  /// nada en el servidor.
  Stream<RobleChange> watch(
    String table, {
    List<RobleChangeType>? events,
    List<RobleFilter> filters = const [],
    String schema = 'public',
  }) {
    late final StreamController<RobleChange> controller;
    late final _Watch watch;

    controller = StreamController<RobleChange>.broadcast(
      onListen: () => _start(watch),
      onCancel: () => _stop(watch),
    );

    watch = _Watch(
      table: table,
      schema: schema,
      events: events ?? RobleChangeType.values,
      filters: filters,
      controller: controller,
    );

    return controller.stream;
  }

  /// Cierra el socket y todos los streams.
  ///
  /// Lo llama el cliente al cerrar sesion: el socket lleva el access token de
  /// esa sesion y no tiene por que sobrevivirla.
  Future<void> close() async {
    _closing = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    for (final watch in [..._watches]) {
      watch.pendingTimeout?.cancel();
      await watch.controller.close();
    }
    _watches.clear();
    _pending.clear();
    _socket?.dispose();
    _socket = null;
    _closing = false;
  }

  /// Alias de [close], para quien espere el nombre habitual.
  Future<void> dispose() => close();

  // ----------------------------------------------------------------- interno

  void _start(_Watch watch) {
    if (!_watches.contains(watch)) _watches.add(watch);
    _ensureSocket();
    if (isConnected) _sendSubscribe(watch);
  }

  void _stop(_Watch watch) {
    watch.pendingTimeout?.cancel();
    _pending.remove(watch);

    final id = watch.subscriptionId;
    if (id != null) {
      _socket?.emit('unsubscribe', {'type': 'unsubscribe', 'subscriptionId': id});
      watch.subscriptionId = null;
    }
    _watches.remove(watch);

    // Sin suscripciones no hay razon para sostener el socket, y el servidor
    // desconecta igualmente a quien no crea ninguna.
    if (_watches.isEmpty) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _socket?.dispose();
      _socket = null;
    }
  }

  void _ensureSocket() {
    if (_socket != null) return;

    final token = _accessToken();
    if (token == null || token.isEmpty) {
      _failAll(const RobleApiAuthException(
        'Hay que iniciar sesion antes de escuchar cambios en tiempo real.',
      ));
      return;
    }

    // La reconexion la lleva este cliente y no socket.io a proposito. socket.io
    // reutilizaria las opciones con las que se creo el socket, incluido el
    // token: cuando caduca —a los quince minutos— todos sus reintentos irian
    // con el token viejo y el servidor los rechazaria uno tras otro. Rehacer el
    // socket obliga a leer el token de nuevo.
    final socket = _socketFactory('$origin/stream', {
      'transports': ['websocket'],
      'autoConnect': true,
      'reconnection': false,
      'query': {'token': token, 'dbName': dbName},
    });

    socket.onConnect((_) {
      _reconnectAttempt = 0;
      // El servidor no recuerda las suscripciones de un socket que se cayo,
      // asi que se vuelven a pedir. Sin esto, una reconexion deja streams
      // abiertos que ya no reciben nada.
      for (final watch in _watches) {
        watch.subscriptionId = null;
        _sendSubscribe(watch);
      }
    });

    socket.onDisconnect((_) => _scheduleReconnect());

    socket.on('data_change', (data) {
      // El servidor manda un evento suelto, o una lista cuando varios cayeron
      // en la misma ventana de agrupacion.
      if (data is List) {
        for (final item in data) {
          _dispatch(item);
        }
      } else {
        _dispatch(data);
      }
    });

    // El servidor usa `error` para los problemas de conexion y `exception`
    // para lo que rechaza un mensaje concreto, que es como llegan los fallos
    // de `subscribe`. Sin escuchar ambos, una suscripcion rechazada dejaba el
    // stream abierto sin recibir nada y sin decir por que.
    socket.on('error', (data) => _failAll(_toException(data)));
    socket.on('exception', _handleException);

    _socket = socket;
  }

  void _scheduleReconnect() {
    if (_closing || _watches.isEmpty || _reconnectTimer != null) return;

    _socket?.dispose();
    _socket = null;

    // Espera creciente hasta medio minuto, para no martillear un servidor que
    // ya esta en apuros.
    final seconds = min(30, 1 << min(_reconnectAttempt, 5));
    _reconnectAttempt++;

    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      _reconnectTimer = null;
      if (_closing || _watches.isEmpty) return;
      _ensureSocket();
    });
  }

  void _sendSubscribe(_Watch watch) {
    final socket = _socket;
    if (socket == null) return;

    _pending.add(watch);
    watch.pendingTimeout?.cancel();
    watch.pendingTimeout = Timer(subscribeTimeout, () {
      if (!_pending.remove(watch)) return;
      watch.fail(const RobleApiTimeoutException(
        'El servidor no respondio a la suscripcion.',
      ));
    });

    socket.emitWithAck(
      'subscribe',
      {
        'type': 'subscribe',
        'requestId': _requestId(),
        'table': watch.table,
        'schema': watch.schema,
        'events': watch.events.map((e) => e.wire).toList(),
        if (watch.filters.isNotEmpty)
          'filters': watch.filters.map((f) => f.toJson()).toList(),
      },
      ack: (response) {
        watch.pendingTimeout?.cancel();
        _pending.remove(watch);

        if (response is Map && response['subscriptionId'] != null) {
          watch.subscriptionId = response['subscriptionId'].toString();
          return;
        }
        watch.fail(_toException(response));
      },
    );
  }

  /// Un `exception` no dice a que mensaje corresponde, y el servidor los
  /// atiende en orden, asi que le toca al mas antiguo sin responder.
  void _handleException(dynamic data) {
    if (_pending.isEmpty) {
      _failAll(_toException(data));
      return;
    }

    final watch = _pending.removeAt(0);
    watch.pendingTimeout?.cancel();
    watch.fail(_toException(data));
  }

  void _dispatch(Object? data) {
    if (data is! Map) return;

    final subscriptionId = data['subscriptionId']?.toString();
    final RobleChange change;
    try {
      change = RobleChange.fromJson(data);
    } on FormatException {
      // Una operacion que este cliente no conoce no debe tirar el stream.
      return;
    }

    for (final watch in _watches) {
      // Por subscriptionId cuando el servidor lo manda; si no, por tabla, que
      // es lo unico con lo que se puede desempatar.
      final mine = subscriptionId != null
          ? watch.subscriptionId == subscriptionId
          : watch.table == change.table && watch.schema == change.schema;

      if (mine && !watch.controller.isClosed) {
        watch.controller.add(change);
      }
    }
  }

  void _failAll(Object error) {
    for (final watch in _watches) {
      watch.fail(error);
    }
  }

  /// Traduce lo que manda el servidor al tipo que le corresponde.
  ///
  /// Todo salia como error de autenticacion, lo que hacia parecer un problema
  /// de sesion algo que suele ser una cuota o un limite.
  RobleApiException _toException(dynamic data) {
    if (data is! Map) {
      return RobleApiException(
        data?.toString() ?? 'Error de tiempo real',
      );
    }

    final code = data['code']?.toString();
    final message =
        (data['message'] ?? code ?? 'Error de tiempo real').toString();

    switch (code) {
      case 'REALTIME_UNAUTHORIZED':
        return RobleApiAuthException(message);
      case 'REALTIME_IDLE_TIMEOUT':
      case 'REALTIME_TOO_SLOW':
        return RobleApiTimeoutException(message);
      default:
        return RobleApiException(message, code: code);
    }
  }

  String _requestId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';
}
