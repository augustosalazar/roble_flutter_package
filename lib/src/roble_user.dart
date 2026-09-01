/// El perfil de quien tiene la sesión iniciada.
///
/// Es lo mismo que devuelve `currentUser()`, pero con tipos. Aquí y no en cada
/// app porque el `Map` viene siempre igual: si cada proyecto lo convierte por su
/// cuenta, cada proyecto se equivoca por su cuenta con los campos que pueden
/// faltar —`role` no existía antes de la v1.7.8 del backend— y con los nombres
/// que el servidor cambió por el camino.
class RobleUser {
  const RobleUser({
    required this.userId,
    required this.email,
    required this.name,
    this.id,
    this.role,
    this.extra,
    this.createdAt,
    this.updatedAt,
    this.raw = const {},
  });

  /// Id del registro de perfil.
  final String? id;

  /// Id del usuario. Es con lo que se comparan los campos tipo `autorId`.
  final String userId;

  final String email;
  final String name;

  /// Rol asignado en la consola de Roble: `admin`, `user`, el que sea.
  ///
  /// `null` cuando no se le asignó ninguno —que no es un error— y también
  /// cuando el backend es anterior a v1.7.8, que es cuando el perfil empezó a
  /// traerlo.
  final String? role;

  /// Campos adicionales enviados al registrarse. `null` si no se usaron.
  final Map<String, dynamic>? extra;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// La respuesta tal cual, para lo que el servidor añada y esto no tenga.
  ///
  /// Sin esto, un campo nuevo del backend obliga a esperar a una versión del
  /// paquete para poder leerlo.
  final Map<String, dynamic> raw;

  factory RobleUser.fromJson(Map<String, dynamic> json) => RobleUser(
        // El servidor ha llamado a esto de varias formas; se aceptan todas
        // porque un perfil sin id no sirve para comparar nada.
        userId: (json['userId'] ?? json['id'] ?? json['_id'] ?? json['sub'] ?? '')
            .toString(),
        id: json['id']?.toString(),
        email: (json['email'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        // `as String?` y no un cast directo: si algún día llega un objeto en vez
        // de un nombre de rol, esto revienta aquí y no tres pantallas más allá.
        role: json['role'] as String?,
        extra: json['extra'] as Map<String, dynamic>?,
        createdAt: _fecha(json['createdAt']),
        updatedAt: _fecha(json['updatedAt']),
        raw: json,
      );

  /// Una fecha ilegible no tumba el perfil entero: se queda en `null`.
  static DateTime? _fecha(Object? valor) {
    if (valor is! String || valor.isEmpty) return null;
    return DateTime.tryParse(valor);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'userId': userId,
        'email': email,
        'name': name,
        'role': role,
        'extra': extra,
        'createdAt': createdAt?.toIso8601String(),
        'updatedAt': updatedAt?.toIso8601String(),
      };

  @override
  String toString() => 'RobleUser($email${role == null ? '' : ', $role'})';
}
