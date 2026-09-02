/// Modelos de respuesta del paquete `roble`.

/// Registro que el servidor rechazó durante un `POST /insert`.
class RobleSkippedRecord {
  /// Posición del registro en la lista enviada.
  final int index;

  /// Motivo indicado por el servidor.
  final String reason;

  const RobleSkippedRecord({required this.index, required this.reason});

  factory RobleSkippedRecord.fromJson(Map<dynamic, dynamic> json) {
    return RobleSkippedRecord(
      index: json['index'] is int
          ? json['index'] as int
          : int.tryParse('${json['index']}') ?? -1,
      reason: '${json['reason'] ?? 'sin motivo'}',
    );
  }

  @override
  String toString() => 'RobleSkippedRecord(index: $index, reason: $reason)';
}

/// Resultado de insertar varios registros con [RobleApiDataBase.createMany].
///
/// El endpoint `/insert` responde `200` aunque haya rechazado registros, así
/// que siempre conviene revisar [skipped] antes de dar la escritura por buena.
class RobleInsertResult {
  /// Registros efectivamente insertados, con su `_id` generado.
  final List<Map<String, dynamic>> inserted;

  /// Registros rechazados, con su posición y motivo.
  final List<RobleSkippedRecord> skipped;

  const RobleInsertResult({required this.inserted, required this.skipped});

  /// `true` si el servidor rechazó al menos un registro.
  bool get hasSkipped => skipped.isNotEmpty;

  factory RobleInsertResult.fromJson(Map<dynamic, dynamic> json) {
    final rawInserted = json['inserted'];
    final rawSkipped = json['skipped'];

    return RobleInsertResult(
      inserted: rawInserted is List
          ? rawInserted
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : <Map<String, dynamic>>[],
      skipped: rawSkipped is List
          ? rawSkipped
              .whereType<Map>()
              .map(RobleSkippedRecord.fromJson)
              .toList()
          : <RobleSkippedRecord>[],
    );
  }

  @override
  String toString() =>
      'RobleInsertResult(inserted: ${inserted.length}, skipped: ${skipped.length})';
}

/// Resultado de `POST /execute-query`.
class RobleQueryResult {
  final bool success;
  final String? command;
  final int rowCount;
  final List<dynamic> rows;
  final List<Map<String, dynamic>> fields;

  const RobleQueryResult({
    required this.success,
    required this.command,
    required this.rowCount,
    required this.rows,
    required this.fields,
  });

  factory RobleQueryResult.fromJson(Map<dynamic, dynamic> json) {
    final rawRows = json['rows'];
    final rawFields = json['fields'];

    return RobleQueryResult(
      success: json['success'] == true,
      command: json['command'] as String?,
      rowCount: json['rowCount'] is int
          ? json['rowCount'] as int
          : int.tryParse('${json['rowCount']}') ?? 0,
      rows: rawRows is List ? List<dynamic>.from(rawRows) : const [],
      fields: rawFields is List
          ? rawFields
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : <Map<String, dynamic>>[],
    );
  }

  @override
  String toString() =>
      'RobleQueryResult(command: $command, rowCount: $rowCount)';
}

/// Destinatario que significa "todos los usuarios del proyecto".
const String robleNotificationEveryone = '*';

/// Que le paso a la notificacion.
enum RobleNotificationEventType {
  /// Alguien la envio.
  created,

  /// Este usuario la marco leida, quiza desde otro dispositivo.
  read,

  /// Se borro.
  deleted;

  static RobleNotificationEventType fromWire(String value) {
    switch (value) {
      case 'created':
        return RobleNotificationEventType.created;
      case 'read':
        return RobleNotificationEventType.read;
      case 'deleted':
        return RobleNotificationEventType.deleted;
      default:
        throw FormatException('Tipo de notificacion desconocido: $value');
    }
  }
}

/// Un aviso dirigido a un usuario del proyecto, o a todo el proyecto.
class RobleNotification {
  const RobleNotification({
    required this.id,
    required this.dbName,
    required this.recipientId,
    required this.senderId,
    required this.topic,
    required this.title,
    required this.body,
    required this.data,
    required this.readAt,
    required this.createdAt,
    required this.expiresAt,
  });

  final String id;

  /// Proyecto al que pertenece.
  final String dbName;

  /// Usuario destinatario, o [robleNotificationEveryone] si va a todo el
  /// proyecto.
  final String recipientId;

  /// Quien la envio, si se sabe.
  final String? senderId;

  /// Etiqueta libre para agrupar o filtrar (`chat`, `tareas`...).
  final String? topic;

  final String title;
  final String? body;

  /// Carga util libre: lo que la app necesite para abrir la pantalla correcta.
  final Map<String, dynamic> data;

  /// Cuando la marco leida **este** usuario, o `null`.
  final DateTime? readAt;

  final DateTime createdAt;

  /// A partir de aqui deja de entregarse y de listarse.
  final DateTime? expiresAt;

  /// `true` si va a todo el proyecto y no a una persona.
  bool get isForEveryone => recipientId == robleNotificationEveryone;

  /// `true` si este usuario todavia no la ha leido.
  bool get isUnread => readAt == null;

  factory RobleNotification.fromJson(Map<dynamic, dynamic> json) {
    DateTime? fecha(Object? raw) =>
        raw == null ? null : DateTime.tryParse('$raw')?.toLocal();

    final rawData = json['data'];

    return RobleNotification(
      id: '${json['id']}',
      dbName: '${json['dbName']}',
      recipientId: '${json['recipientId']}',
      senderId: json['senderId'] == null ? null : '${json['senderId']}',
      topic: json['topic'] == null ? null : '${json['topic']}',
      title: '${json['title'] ?? ''}',
      body: json['body'] == null ? null : '${json['body']}',
      data: rawData is Map
          ? Map<String, dynamic>.from(rawData)
          : <String, dynamic>{},
      readAt: fecha(json['readAt']),
      // Sin fecha no se puede ordenar la lista; se prefiere "ahora" a tirar
      // toda la notificacion por un campo que el servidor siempre manda.
      createdAt: fecha(json['createdAt']) ?? DateTime.now(),
      expiresAt: fecha(json['expiresAt']),
    );
  }

  @override
  String toString() =>
      'RobleNotification(id: $id, title: $title, readAt: $readAt)';
}

/// Lo que llega por el canal de notificaciones.
class RobleNotificationEvent {
  const RobleNotificationEvent({
    required this.type,
    required this.notification,
  });

  final RobleNotificationEventType type;
  final RobleNotification notification;

  factory RobleNotificationEvent.fromJson(Map<dynamic, dynamic> json) {
    final raw = json['notification'];
    if (raw is! Map) {
      throw const FormatException('El evento no trae la notificacion');
    }
    return RobleNotificationEvent(
      type: RobleNotificationEventType.fromWire('${json['type']}'),
      notification: RobleNotification.fromJson(raw),
    );
  }

  @override
  String toString() => 'RobleNotificationEvent($type, ${notification.id})';
}

/// Sistema del aparato que recibe el push.
enum RobleDevicePlatform {
  android,
  ios,
  web;

  /// Como lo espera el servidor.
  String get wire => name;

  static RobleDevicePlatform fromWire(String value) {
    for (final p in RobleDevicePlatform.values) {
      if (p.name == value) return p;
    }
    throw FormatException('Plataforma desconocida: $value');
  }
}

/// Un aparato apuntado para recibir push.
class RobleDevice {
  const RobleDevice({
    required this.dbName,
    required this.userId,
    required this.token,
    required this.platform,
    required this.createdAt,
    required this.lastSeenAt,
  });

  final String dbName;
  final String userId;

  /// El token de FCM del aparato.
  final String token;

  final RobleDevicePlatform platform;
  final DateTime createdAt;
  final DateTime lastSeenAt;

  factory RobleDevice.fromJson(Map<dynamic, dynamic> json) {
    DateTime fecha(Object? raw) =>
        DateTime.tryParse('$raw')?.toLocal() ?? DateTime.now();

    return RobleDevice(
      dbName: '${json['dbName']}',
      userId: '${json['userId']}',
      token: '${json['token']}',
      platform: RobleDevicePlatform.fromWire('${json['platform']}'),
      createdAt: fecha(json['createdAt']),
      lastSeenAt: fecha(json['lastSeenAt']),
    );
  }

  @override
  String toString() => 'RobleDevice($platform, ${token.substring(0, 8)}…)';
}
