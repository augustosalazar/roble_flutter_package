import 'dart:convert';

/// Columna que dice de quién es cada fila.
///
/// La pone el servidor con el usuario del token al insertar; lo que mandes tú
/// en ella no se respeta nunca, ni al crear ni al actualizar. Este paquete la
/// quita de los datos que envías para que el patrón de leer una fila, cambiarle
/// algo y volver a escribirla siga funcionando.
///
/// Puede no venir en las lecturas: una tabla puede ocultarla desde la consola
/// (`expose_owner`), y ahí filtrar por ella tampoco vale. Es lo que quieres en
/// una tabla anónima, donde saber de quién es cada fila rompe el propósito.
const String robleOwnerColumn = '_owner';

/// Roles que Roble crea en un proyecto nuevo.
///
/// Son cadenas normales: un proyecto puede tener otros, y el `role` del perfil
/// trae el que sea. Están aquí para no escribirlos a mano en cada comparación.
abstract final class RobleRole {
  /// Todo, sobre cualquier fila.
  static const String admin = 'admin';

  /// Por defecto al registrarse: crear y leer.
  static const String user = 'user';

  /// Crear, leer, actualizar y borrar cualquier fila.
  static const String editor = 'editor';

  /// Lo mismo que [editor], pero sólo sobre las filas propias.
  ///
  /// Es el rol que resuelve el caso de siempre —«que cada quien edite lo
  /// suyo»— sin que promover a alguien le deje borrar la tabla entera.
  static const String editorOwn = 'editor_own';
}

/// De quién es la fila, o `null` si la tabla no lo dice.
///
/// ```dart
/// final mias = filas.where((f) => robleOwnerOf(f) == db.currentUserId);
/// ```
String? robleOwnerOf(Map<String, dynamic>? row) {
  final owner = row?[robleOwnerColumn];
  return (owner is String && owner.isNotEmpty) ? owner : null;
}

/// Devuelve [data] sin `_owner`. El servidor lo asigna él.
Map<String, dynamic> robleWithoutOwner(Map<String, dynamic> data) {
  if (!data.containsKey(robleOwnerColumn)) return data;
  return Map<String, dynamic>.from(data)..remove(robleOwnerColumn);
}

/// Payload de un JWT, sin verificar la firma.
///
/// Sirve para sacar el `sub` sin ir al servidor: para pintar, no para decidir
/// permisos. Quien decide es el servidor, que sí verifica.
Map<String, dynamic>? robleJwtPayload(String? token) {
  if (token == null || token.isEmpty) return null;

  final partes = token.split('.');
  if (partes.length < 2 || partes[1].isEmpty) return null;

  try {
    final normalizado = base64Url.normalize(partes[1]);
    final decoded = jsonDecode(utf8.decode(base64Url.decode(normalizado)));
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } catch (_) {
    return null;
  }
}
