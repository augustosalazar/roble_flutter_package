import 'roble_models.dart';
import 'roble_notifications_client.dart';

/// Peticion HTTP contra el servicio de notificaciones, ya con el token puesto.
typedef RobleNotificationsRequest = Future<dynamic> Function(
  String method,
  String path, {
  Object? body,
  Map<String, String>? queryParams,
});

/// Notificaciones del proyecto: enviarlas, listarlas y escucharlas.
///
/// Es otra cosa que el arbol JSON. Alli se escribe en una ruta y quien mire esa
/// ruta lo ve; aqui el destinatario es **una persona** del proyecto, el aviso
/// se guarda aunque no tenga la app abierta, y cada uno lleva su propio estado
/// de leido.
///
/// ```dart
/// // Escuchar lo que llegue.
/// db.notifications.watch().listen((evento) {
///   if (evento.type == RobleNotificationEventType.created) {
///     mostrarAviso(evento.notification.title);
///   }
/// });
///
/// // Enviar a alguien.
/// await db.notifications.send(
///   to: otroUsuarioId,
///   title: 'Te toca',
///   data: {'partidaId': '42'},
/// );
/// ```
class RobleNotifications {
  RobleNotifications({
    required RobleNotificationsRequest request,
    required RobleNotificationsClient client,
  })  : _request = request,
        _client = client;

  final RobleNotificationsRequest _request;
  final RobleNotificationsClient _client;

  /// La conexion: estado, contador de no leidas y cierre.
  RobleNotificationsClient get connection => _client;

  /// Envia una notificacion y devuelve una por destinatario.
  ///
  /// [to] admite un id, varios, o [robleNotificationEveryone] para todo el
  /// proyecto. El comodin no se mezcla con ids concretos: el servidor lo
  /// rechaza, porque quien estuviera en las dos listas la recibiria dos veces.
  Future<List<RobleNotification>> send({
    required Object to,
    required String title,
    String? body,
    String? topic,
    Map<String, dynamic>? data,
    DateTime? expiresAt,
  }) async {
    final recipients = to is List
        ? to.map((e) => e.toString()).toList()
        : <String>[to.toString()];

    final res = await _request(
      'POST',
      '',
      body: {
        'recipients': recipients,
        'title': title,
        if (body != null) 'body': body,
        if (topic != null) 'topic': topic,
        if (data != null) 'data': data,
        if (expiresAt != null) 'expiresAt': expiresAt.toUtc().toIso8601String(),
      },
    );

    return (res as List?)
            ?.whereType<Map>()
            .map(RobleNotification.fromJson)
            .toList() ??
        const [];
  }

  /// Las notificaciones visibles para quien tiene la sesion abierta: las suyas
  /// y las del proyecto, de la mas reciente a la mas antigua.
  ///
  /// [limit] va entre 1 y 100; por defecto el servidor devuelve 50. [before]
  /// sirve para ir hacia atras: pide las anteriores a esa fecha.
  Future<List<RobleNotification>> list({
    bool unread = false,
    String? topic,
    int? limit,
    DateTime? before,
  }) async {
    final res = await _request(
      'GET',
      '',
      queryParams: {
        if (unread) 'unread': 'true',
        if (topic != null) 'topic': topic,
        if (limit != null) 'limit': '$limit',
        if (before != null) 'before': before.toUtc().toIso8601String(),
      },
    );

    return (res as List?)
            ?.whereType<Map>()
            .map(RobleNotification.fromJson)
            .toList() ??
        const [];
  }

  /// Cuantas lleva sin leer. Es lo que pinta el globito.
  ///
  /// Al conectar el socket este numero llega solo, por
  /// [RobleNotificationsClient.unreadCount]; esto es para pedirlo sin escuchar.
  Future<int> unreadCount() async {
    final res = await _request('GET', 'unread-count');
    if (res is Map) {
      final raw = res['count'];
      return raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0;
    }
    return 0;
  }

  /// Marca una como leida. Marcarla dos veces no cambia nada.
  Future<RobleNotification> markRead(String id) async {
    final res = await _request('PATCH', '${Uri.encodeComponent(id)}/read');
    return RobleNotification.fromJson(res as Map);
  }

  /// Marca todas las visibles. Devuelve cuantas cambiaron de estado.
  Future<int> markAllRead() async {
    final res = await _request('PATCH', 'read-all');
    if (res is Map) {
      final raw = res['marked'];
      return raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0;
    }
    return 0;
  }

  /// Borra una notificacion dirigida a este usuario.
  ///
  /// Las de proyecto no se pueden borrar desde un cliente: la notificacion es
  /// una sola y es de todos. Se marcan leidas.
  Future<void> remove(String id) async {
    await _request('DELETE', Uri.encodeComponent(id));
  }

  /// Apunta este aparato para recibir push con la app cerrada.
  ///
  /// El [token] lo da el SDK de Firebase dentro de tu app —este paquete no
  /// depende de `firebase_messaging` ni lo pide por ti—, y el push solo sale si
  /// el proyecto tiene subidas sus credenciales de Firebase en la consola de
  /// Roble.
  ///
  /// Llamarlo otra vez con el mismo token no duplica nada: solo refresca la
  /// fecha, que es lo que conviene hacer en cada arranque.
  ///
  /// ```dart
  /// final token = await FirebaseMessaging.instance.getToken();
  /// if (token != null) {
  ///   await db.notifications.registerDevice(token, RobleDevicePlatform.android);
  /// }
  /// ```
  Future<RobleDevice> registerDevice(
    String token,
    RobleDevicePlatform platform,
  ) async {
    final res = await _request(
      'POST',
      'devices',
      body: {'token': token, 'platform': platform.wire},
    );
    return RobleDevice.fromJson(res as Map);
  }

  /// Deja de recibir push en este aparato.
  ///
  /// Llamalo **antes** de cerrar sesion: despues ya no hay token con el que
  /// pedirlo, y el aparato seguiria recibiendo los avisos de esa cuenta.
  Future<void> unregisterDevice(String token) async {
    await _request('DELETE', 'devices/${Uri.encodeComponent(token)}');
  }

  /// Los aparatos que esta cuenta tiene apuntados.
  Future<List<RobleDevice>> devices() async {
    final res = await _request('GET', 'devices');
    return (res as List?)?.whereType<Map>().map(RobleDevice.fromJson).toList() ??
        const [];
  }

  /// Las notificaciones segun van llegando.
  ///
  /// El stream **no** trae las anteriores, solo lo que pase a partir de ahora:
  /// para pintar la lista, [list] y encima esto.
  Stream<RobleNotificationEvent> watch() => _client.watch();

  /// El contador de no leidas cada vez que el servidor lo manda: al conectar y
  /// en cada reconexion.
  Stream<int> get unreadCountChanges => _client.unreadCount;
}
