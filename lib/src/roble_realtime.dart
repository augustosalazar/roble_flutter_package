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

  Map<String, dynamic> toJson() => {
        'simple': {
          'column': column,
          'operator': operator,
          'value': value,
        },
      };

  @override
  String toString() => 'RobleFilter($column $operator $value)';
}
