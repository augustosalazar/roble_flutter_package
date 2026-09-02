import 'dart:async';
import 'dart:math';

import 'package:socket_io_client/socket_io_client.dart' as io;

import 'roble_api_exception.dart';
import 'roble_models.dart';
import 'roble_realtime_client.dart' show RobleSocketFactory;

io.Socket _defaultSocketFactory(String url, Map<String, dynamic> options) =>
    io.io(url, options);

/// Mantiene abierto el canal de notificaciones del proyecto.
///
/// Es otro socket que el de tiempo real, contra el namespace
/// `/notifications`, y su protocolo es mucho mas corto: no hay nada que
/// suscribir, porque el destinatario es quien firma el token. Conectarse ya es
/// todo.
///
/// Se abre con el primer oyente y se cierra con el ultimo, asi que una app que
/// no escuche notificaciones no paga ninguna conexion.
class RobleNotificationsClient {
  RobleNotificationsClient({
    required this.origin,
    required this.dbName,
    required String? Function() accessToken,
    RobleSocketFactory? socketFactory,
  })  : _accessToken = accessToken,
        _socketFactory = socketFactory ?? _defaultSocketFactory;

  /// Host del servicio, sin ruta: el namespace se le pega aparte.
  final String origin;

  /// Contrato del proyecto. El servidor comprueba que coincida con el del token.
  final String dbName;

  final String? Function() _accessToken;
  final RobleSocketFactory _socketFactory;

  io.Socket? _socket;
  final _controllers = <StreamController<RobleNotificationEvent>>[];
  final _unreadController = StreamController<int>.broadcast();

  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _closing = false;
  int _unread = 0;

  bool get isConnected => _socket?.connected ?? false;

  /// Cuantas sin leer dijo el servidor la ultima vez que se conecto.
  int get unread => _unread;

  /// El contador de no leidas, cada vez que el servidor lo manda.
  ///
  /// Llega solo con conectarse, sin pedirlo: es lo primero que quiere pintar
  /// cualquier app y ahorra una llamada REST al arrancar.
  Stream<int> get unreadCount => _unreadController.stream;

  /// Las notificaciones segun van llegando.
  ///
  /// El stream **no** trae las anteriores, solo lo que pase a partir de ahora:
  /// para pintar la lista hay que leerla con `list()` y aplicar encima esto.
  Stream<RobleNotificationEvent> watch() {
    late final StreamController<RobleNotificationEvent> controller;

    controller = StreamController<RobleNotificationEvent>.broadcast(
      onListen: () {
        if (!_controllers.contains(controller)) _controllers.add(controller);
        _ensureSocket();
      },
      onCancel: () {
        _controllers.remove(controller);
        // Sin oyentes no hay razon para sostener el socket.
        if (_controllers.isEmpty) _dropSocket();
      },
    );

    return controller.stream;
  }

  /// Cierra el socket y todos los streams.
  ///
  /// Lo llama el cliente al cerrar sesion: el socket lleva el token de esa
  /// sesion, y dejarlo abierto entregaria a la siguiente persona lo que llegue
  /// para la anterior.
  Future<void> close() async {
    _closing = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    for (final controller in [..._controllers]) {
      await controller.close();
    }
    _controllers.clear();
    _socket?.dispose();
    _socket = null;
    _closing = false;
  }

  /// Alias de [close], para quien espere el nombre habitual.
  Future<void> dispose() => close();

  // ----------------------------------------------------------------- interno

  void _dropSocket() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _socket?.dispose();
    _socket = null;
  }

  void _ensureSocket() {
    if (_socket != null) return;

    final token = _accessToken();
    if (token == null || token.isEmpty) {
      _failAll(const RobleApiAuthException(
        'Hay que iniciar sesion antes de escuchar notificaciones.',
      ));
      return;
    }

    // Igual que en el cliente de tiempo real, la reconexion la lleva este
    // codigo y no socket.io: socket.io reintentaria con el token con el que se
    // creo el socket, y cuando ese caduca todos sus intentos van al rechazo.
    final socket = _socketFactory('$origin/notifications', {
      'transports': ['websocket'],
      'autoConnect': true,
      'reconnection': false,
      'query': {'token': token, 'dbName': dbName},
    });

    socket.onConnect((_) => _reconnectAttempt = 0);
    socket.onDisconnect((_) => _scheduleReconnect());

    socket.on('connected', (data) {
      if (data is! Map) return;
      _unread = (data['unread'] as num?)?.toInt() ?? 0;
      if (!_unreadController.isClosed) _unreadController.add(_unread);
    });

    socket.on('notification', _dispatch);

    // `error` para los problemas de conexion, `exception` para lo que rechaza
    // un mensaje concreto.
    socket.on('error', (data) => _failAll(_toException(data)));
    socket.on('exception', (data) => _failAll(_toException(data)));

    _socket = socket;
  }

  void _scheduleReconnect() {
    if (_closing || _controllers.isEmpty || _reconnectTimer != null) return;

    _socket?.dispose();
    _socket = null;

    // Espera creciente hasta medio minuto, para no martillear un servidor que
    // ya esta en apuros.
    final seconds = min(30, 1 << min(_reconnectAttempt, 5));
    _reconnectAttempt++;

    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      _reconnectTimer = null;
      if (_closing || _controllers.isEmpty) return;
      _ensureSocket();
    });
  }

  void _dispatch(Object? data) {
    if (data is! Map) return;

    final RobleNotificationEvent event;
    try {
      event = RobleNotificationEvent.fromJson(data);
    } on FormatException {
      // Un tipo de evento que este cliente no conoce no debe tirar el stream.
      return;
    }

    for (final controller in _controllers) {
      if (!controller.isClosed) controller.add(event);
    }
  }

  void _failAll(Object error) {
    for (final controller in _controllers) {
      if (!controller.isClosed) controller.addError(error);
    }
  }

  RobleApiException _toException(dynamic data) {
    if (data is! Map) {
      return RobleApiException(data?.toString() ?? 'Error de notificaciones');
    }

    final code = data['code']?.toString();
    final message =
        (data['message'] ?? code ?? 'Error de notificaciones').toString();

    switch (code) {
      case 'NOTIFICATIONS_UNAUTHORIZED':
        return RobleApiAuthException(message);
      default:
        return RobleApiException(message, code: code);
    }
  }
}
