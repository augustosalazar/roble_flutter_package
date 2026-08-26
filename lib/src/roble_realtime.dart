/// Tipo de cambio en una fila.
enum RobleChangeType {
  insert,
  update,
  delete;

  /// Como lo nombra el servidor: `INSERT`, `UPDATE`, `DELETE`.
  String get wire => name.toUpperCase();

  static RobleChangeType? fromWire(String? value) {
    switch (value) {
      case 'INSERT':
        return RobleChangeType.insert;
      case 'UPDATE':
        return RobleChangeType.update;
      case 'DELETE':
        return RobleChangeType.delete;
      default:
        return null;
    }
  }
}

/// Un cambio en una fila, tal y como llega del servidor.
class RobleChange {
  const RobleChange({
    required this.type,
    required this.table,
    required this.schema,
    required this.primaryKey,
    required this.commitTimestamp,
    required this.eventId,
    this.record,
    this.previous,
    this.path = const [],
  });

  final RobleChangeType type;
  final String table;
  final String schema;

  /// Clave primaria de la fila. Es lo unico que viene siempre, incluso en un
  /// borrado.
  final Map<String, dynamic> primaryKey;

  /// Cuando se confirmo la transaccion en la base, no cuando llego aqui.
  final DateTime commitTimestamp;

  /// Identificador del evento, util para descartar duplicados tras reconectar.
  final String eventId;

  /// La fila despues del cambio. `null` en un borrado.
  final Map<String, dynamic>? record;

  /// La fila antes del cambio. `null` en una insercion, y en un update solo
  /// trae valores si la tabla tiene REPLICA IDENTITY FULL.
  final Map<String, dynamic>? previous;

  /// Ruta dentro del arbol JSON que cambio, empezando por la coleccion.
  ///
  /// Solo la traen los cambios de la base de datos JSON. En una tabla SQL
  /// llega vacia, porque ahi lo que identifica la fila es [primaryKey].
  final List<String> path;

  /// El `_id` de la fila, que es como se identifica un registro en Roble.
  String? get id =>
      (primaryKey['_id'] ?? record?['_id'] ?? previous?['_id'])?.toString();

  factory RobleChange.fromJson(Map<dynamic, dynamic> json) {
    final type = RobleChangeType.fromWire(json['operation'] as String?);
    if (type == null) {
      throw FormatException('Operacion desconocida: ${json['operation']}');
    }

    return RobleChange(
      type: type,
      table: json['table'] as String? ?? '',
      schema: json['schema'] as String? ?? 'public',
      primaryKey: Map<String, dynamic>.from(
        (json['primaryKey'] as Map?) ?? const {},
      ),
      commitTimestamp:
          DateTime.tryParse(json['commitTimestamp'] as String? ?? '') ??
              DateTime.now(),
      eventId: json['eventId'] as String? ?? '',
      record: json['new'] == null
          ? null
          : Map<String, dynamic>.from(json['new'] as Map),
      previous: json['old'] == null
          ? null
          : Map<String, dynamic>.from(json['old'] as Map),
      path: (json['path'] as List?)?.map((s) => s.toString()).toList() ??
          const [],
    );
  }

  @override
  String toString() =>
      'RobleChange(${type.name} $schema.$table id=$id)';
}

/// Comparacion que el servidor aplica antes de mandar el cambio.
///
/// Filtrar aqui y no en la app ahorra el viaje de todo lo que no interesa, que
/// en una tabla movida es casi todo.
class RobleFilter {
  const RobleFilter(this.column, this.operator, this.value);

  /// `columna == valor`.
  const RobleFilter.equals(String column, Object? value)
      : this(column, 'eq', value);

  const RobleFilter.notEquals(String column, Object? value)
      : this(column, 'neq', value);

  const RobleFilter.greaterThan(String column, Object? value)
      : this(column, 'gt', value);

  const RobleFilter.greaterOrEqual(String column, Object? value)
      : this(column, 'gte', value);

  const RobleFilter.lessThan(String column, Object? value)
      : this(column, 'lt', value);

  const RobleFilter.lessOrEqual(String column, Object? value)
      : this(column, 'lte', value);

  /// `columna` dentro de la lista.
  const RobleFilter.isIn(String column, List<Object?> values)
      : this(column, 'in', values);

  final String column;

  /// Uno de `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `in`.
  final String operator;

  final Object? value;

  /// Plano, no envuelto en `simple`.
  ///
  /// El evaluador del servidor lee `column`, `operator` y `value` del objeto
  /// tal cual. Envuelto, `operator` le llega vacio y su `switch` cae en un
  /// `default` que devuelve `true`: el filtro no descarta nada y lo deja pasar
  /// todo, en silencio. El DTO admite las dos formas, asi que la validacion
  /// tampoco lo delata.
  Map<String, dynamic> toJson() => {
        'column': column,
        'operator': operator,
        'value': value,
      };

  @override
  String toString() => 'RobleFilter($column $operator $value)';
}

/// Quien puede escuchar los cambios de una tabla.
enum RobleRealtimeAccess {
  /// Nadie: la tabla no emite.
  disabled,

  /// Cualquiera, con sesion o sin ella.
  public,

  /// Cualquier usuario con sesion iniciada.
  authenticated,

  /// Solo el dueno de la fila.
  ownerOnly,

  /// Segun el rol, con lo definido en `rowPolicy`.
  roleBased;

  /// Como lo nombra el servidor: `owner_only`, `role_based`…
  String get wire => switch (this) {
        RobleRealtimeAccess.ownerOnly => 'owner_only',
        RobleRealtimeAccess.roleBased => 'role_based',
        _ => name,
      };

  static RobleRealtimeAccess fromWire(String? value) => switch (value) {
        'disabled' => RobleRealtimeAccess.disabled,
        'public' => RobleRealtimeAccess.public,
        'owner_only' => RobleRealtimeAccess.ownerOnly,
        'role_based' => RobleRealtimeAccess.roleBased,
        _ => RobleRealtimeAccess.authenticated,
      };
}

/// Configuracion de tiempo real de una tabla.
///
/// Decide si la tabla emite, que operaciones, y quien puede escucharlas. Una
/// tabla sin politica emite a cualquiera con sesion: la politica sirve para
/// restringir o apagar, no para habilitar.
class RobleTablePolicy {
  const RobleTablePolicy({
    required this.table,
    required this.enabled,
    this.schema = 'public',
    this.events = const [
      RobleChangeType.insert,
      RobleChangeType.update,
      RobleChangeType.delete,
    ],
    this.access = RobleRealtimeAccess.authenticated,
    this.includeOldRecord = true,
    this.allowedFilterColumns,
    this.rowPolicy,
    this.id,
    this.createdAt,
    this.updatedAt,
  });

  final String table;
  final String schema;

  /// `false` deja la tabla muda sin borrar el resto de la configuracion.
  final bool enabled;

  /// Operaciones que la tabla puede emitir.
  final List<RobleChangeType> events;

  final RobleRealtimeAccess access;

  /// Si se manda la fila anterior en un update o un borrado.
  ///
  /// Aunque este en `true`, Postgres solo la trae completa si la tabla tiene
  /// `REPLICA IDENTITY FULL`; si no, viaja solo la clave.
  final bool includeOldRecord;

  /// Columnas por las que se permite filtrar. `null` es cualquiera.
  final List<String>? allowedFilterColumns;

  /// Condicion extra para `ownerOnly` y `roleBased`.
  final Map<String, dynamic>? rowPolicy;

  final String? id;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory RobleTablePolicy.fromJson(Map<dynamic, dynamic> json) {
    return RobleTablePolicy(
      table: json['tableName'] as String? ?? '',
      schema: json['schemaName'] as String? ?? 'public',
      enabled: json['enabled'] == true,
      events: ((json['allowedEvents'] as List?) ?? const [])
          .map((e) => RobleChangeType.fromWire(e as String?))
          .whereType<RobleChangeType>()
          .toList(),
      access: RobleRealtimeAccess.fromWire(json['accessLevel'] as String?),
      includeOldRecord: json['includeOldRecord'] != false,
      allowedFilterColumns: (json['allowedFilterColumns'] as List?)
          ?.map((e) => e.toString())
          .toList(),
      rowPolicy: json['rowPolicy'] == null
          ? null
          : Map<String, dynamic>.from(json['rowPolicy'] as Map),
      id: json['id']?.toString(),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
    );
  }

  /// Lo que espera el servidor al guardar. La tabla y el esquema van en la
  /// ruta, no en el cuerpo.
  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'allowedEvents': events.map((e) => e.wire).toList(),
        'accessLevel': access.wire,
        'includeOldRecord': includeOldRecord,
        if (allowedFilterColumns != null)
          'allowedFilterColumns': allowedFilterColumns,
        if (rowPolicy != null) 'rowPolicy': rowPolicy,
      };

  @override
  String toString() => 'RobleTablePolicy($schema.$table, '
      'enabled: $enabled, access: ${access.wire})';
}
