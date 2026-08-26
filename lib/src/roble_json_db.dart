import 'roble_realtime.dart';
import 'roble_realtime_client.dart';

/// Peticion HTTP contra el servicio de tiempo real, ya con el token puesto.
typedef RobleJsonRequest = Future<dynamic> Function(
  String method,
  String path, {
  Object? body,
  Map<String, String>? queryParams,
});

/// Base de datos JSON: un arbol por proyecto, al estilo de Firebase Realtime
/// Database.
///
/// La diferencia con [RobleApiDataBase.watchTable] no es de sintaxis, es de
/// modelo. Una tabla hay que crearla antes, con sus columnas, y vive en el
/// esquema del proyecto. Aqui **no se declara nada**: la estructura aparece
/// cuando llega el primer dato, y el arbol vive fuera del esquema, asi que no
/// aparece entre las tablas del proyecto.
///
/// Para un chat, un tablero o una partida —datos que nacen y mueren rapido y
/// cuya forma no vale la pena declarar— este es el modulo, no una tabla.
///
/// Una ruta es `coleccion/hijo/nieto`. El primer segmento es la coleccion; el
/// resto navega dentro del JSON.
///
/// ```dart
/// // Escribir con clave generada por el servidor, como el push de Firebase.
/// await db.json.push('mensajes', {'texto': 'hola', 'de': 'ana@correo.com'});
///
/// // Escuchar lo que entre en la coleccion.
/// db.json.watch('mensajes').listen((cambio) {
///   for (final entry in (cambio.record ?? {}).entries) {
///     print('${entry.key}: ${entry.value}');
///   }
/// });
/// ```
class RobleJsonDb {
  RobleJsonDb({
    required RobleJsonRequest request,
    required RobleRealtimeClient realtime,
  })  : _request = request,
        _realtime = realtime;

  final RobleJsonRequest _request;
  final RobleRealtimeClient _realtime;

  /// Nombres de las colecciones que existen en el proyecto.
  Future<List<String>> collections() async {
    final res = await _request('GET', '');
    return (res as List?)?.map((e) => e.toString()).toList() ?? const [];
  }

  /// Lee lo que haya en [path]. Devuelve `null` si esa rama no existe.
  ///
  /// Con [shallow] en `true` no baja el arbol entero: de cada hijo dice si
  /// tiene contenido, no cual. Sirve para listar una coleccion grande sin
  /// traersela.
  Future<dynamic> read(String path, {bool shallow = false}) {
    return _request(
      'GET',
      _encode(path),
      queryParams: shallow ? const {'shallow': 'true'} : null,
    );
  }

  /// Reemplaza [path] por [data]. Lo que hubiera debajo se pierde.
  Future<void> write(String path, Object? data) async {
    await _request('PUT', _encode(path), body: data);
  }

  /// Mezcla [data] con lo que ya hay en [path]: solo toca las claves que
  /// vienen, el resto se queda.
  Future<void> update(String path, Map<String, dynamic> data) async {
    await _request('PATCH', _encode(path), body: data);
  }

  /// Anade un hijo con clave generada por el servidor, y devuelve esa clave.
  ///
  /// Las claves salen ordenadas por tiempo, asi que dos clientes que escriben a
  /// la vez no se pisan y el orden de insercion se conserva sin llevar contador.
  Future<String> push(String path, Object? data) async {
    final res = await _request('POST', _encode(path), body: data);
    return (res as Map)['name'].toString();
  }

  /// Borra [path] y todo lo que cuelgue de el.
  Future<void> remove(String path) async {
    await _request('DELETE', _encode(path));
  }

  /// Escucha los cambios en [path] y en lo que cuelgue de el.
  ///
  /// El stream **no** trae lo que ya hay, solo lo que cambie a partir de ahora:
  /// para pintar el estado inicial hay que leer con [read] y aplicar encima lo
  /// que llegue.
  ///
  /// El servidor emite por coleccion, asi que suscribirse a una rama concreta
  /// no ahorra trafico —llega todo lo de la coleccion y se descarta aqui lo que
  /// no cuelgue de [path]—. Solo ahorra trabajo a quien escucha.
  ///
  /// Tambien llega un cambio escrito *por encima* de [path], porque reemplazar
  /// un padre cambia al hijo aunque nadie lo nombre.
  Stream<RobleChange> watch(String path, {List<RobleChangeType>? events}) {
    final segments = _segments(path);
    if (segments.isEmpty) {
      throw ArgumentError.value(path, 'path', 'Falta el nombre de la coleccion');
    }
    final wanted = segments.sublist(1);

    return _realtime
        .watch(segments.first, events: events)
        .where((change) => _touches(change.path, wanted));
  }

  /// Un evento importa si su ruta y la escuchada estan en la misma rama: da
  /// igual cual de las dos sea mas profunda.
  static bool _touches(List<String> eventPath, List<String> wanted) {
    // El primer segmento es la coleccion, que ya decidio la suscripcion.
    final changed = eventPath.isEmpty ? const <String>[] : eventPath.sublist(1);
    final common = changed.length < wanted.length ? changed.length : wanted.length;
    for (var i = 0; i < common; i++) {
      if (changed[i] != wanted[i]) return false;
    }
    return true;
  }

  static List<String> _segments(String path) =>
      path.split('/').where((s) => s.isNotEmpty).toList();

  /// Cada segmento va escapado por separado: si no, un nombre con `/` partiria
  /// la ruta y uno con `?` se llevaria por delante el resto de la URL.
  static String _encode(String path) =>
      _segments(path).map(Uri.encodeComponent).join('/');
}
