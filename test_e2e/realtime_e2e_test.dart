@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:roble/roble.dart';

/// Prueba de extremo a extremo contra un Roble de verdad.
///
/// No corre con `flutter test`, que solo mira `test/`. Se lanza a mano:
///
/// ```bash
/// ROBLE_CONTRACT=mi_proyecto_ab12 ROBLE_TABLE=products \
///   flutter test test_e2e/realtime_e2e_test.dart
/// ```
///
/// Crea un usuario propio con `signup-direct` en vez de pedir credenciales de
/// nadie, y lo borra al terminar. Tambien crea y borra una fila en la tabla que
/// se le indique; no toca ninguna otra.
void main() {
  final contract = Platform.environment['ROBLE_CONTRACT'];
  final table = Platform.environment['ROBLE_TABLE'];
  final baseUrl = Platform.environment['ROBLE_BASE_URL'] ??
      'https://roble-api.test-openlab.uninorte.edu.co';

  if (contract == null || table == null) {
    test('faltan datos', () {
      fail('Hacen falta ROBLE_CONTRACT y ROBLE_TABLE en el entorno.');
    });
    return;
  }

  late RobleApiDataBase db;
  late String email;
  final creados = <String>[];

  /// Almacen en memoria: sin esto haria falta el llavero del sistema.
  final storage = _MemoriaStorage();

  setUpAll(() async {
    db = RobleApiDataBase(
      config: RobleApiConfig.fromContract(baseUrl: baseUrl, contractId: contract),
      storage: storage,
    );

    // Usuario de usar y tirar, con una contrasena generada aqui: no hace falta
    // que nadie comparta la suya.
    final marca = DateTime.now().millisecondsSinceEpoch;
    email = 'e2e-$marca@example.com';
    final password = 'E2e!${marca}aA';

    await db.register(email: email, password: password, name: 'Prueba E2E');
    await db.login(email: email, password: password);
    expect(db.isLoggedIn, isTrue, reason: 'no se pudo iniciar sesion');
  });

  tearDownAll(() async {
    for (final id in creados) {
      try {
        await db.delete(table, id);
      } catch (_) {
        // Ya borrada por la propia prueba.
      }
    }
    try {
      await db.deleteAccount();
    } catch (_) {
      // Deja el usuario si el proyecto no permite borrarlo; es de usar y tirar.
    }
  });

  test('un INSERT llega al stream de la tabla', () async {
    final recibidos = <RobleChange>[];
    final sub = db.watchTable(table).listen(recibidos.add, onError: (e) {
      fail('el stream fallo: $e');
    });

    // El servidor abre el CDC de este proyecto al aparecer el primer
    // suscriptor, asi que hay que darle un momento antes de escribir.
    await Future<void>.delayed(const Duration(seconds: 3));

    final fila = await db.create(table, {'name': 'e2e-insert'});
    creados.add(fila['_id'].toString());

    await _esperarA(() => recibidos.isNotEmpty);
    await sub.cancel();

    expect(recibidos.first.type, RobleChangeType.insert);
    expect(recibidos.first.table, table);
    expect(recibidos.first.record?['name'], 'e2e-insert');
  });

  test('UPDATE y DELETE llegan con sus tipos', () async {
    final recibidos = <RobleChange>[];
    final sub = db.watchTable(table).listen(recibidos.add);
    await Future<void>.delayed(const Duration(seconds: 3));

    final fila = await db.create(table, {'name': 'e2e-ciclo'});
    final id = fila['_id'].toString();
    creados.add(id);

    await _esperarA(() => recibidos.any((c) => c.type == RobleChangeType.insert));
    await db.update(table, id, {'name': 'e2e-ciclo-2'});
    await _esperarA(() => recibidos.any((c) => c.type == RobleChangeType.update));
    await db.delete(table, id);
    await _esperarA(() => recibidos.any((c) => c.type == RobleChangeType.delete));
    await sub.cancel();

    final actualizado =
        recibidos.firstWhere((c) => c.type == RobleChangeType.update);
    expect(actualizado.record?['name'], 'e2e-ciclo-2');
  });

  test('watchRecord solo trae el registro pedido', () async {
    final mio = await db.create(table, {'name': 'e2e-vigilado'});
    final otro = await db.create(table, {'name': 'e2e-ruido'});
    creados.addAll([mio['_id'].toString(), otro['_id'].toString()]);

    final recibidos = <RobleChange>[];
    final sub = db.watchRecord(table, mio['_id']).listen(recibidos.add);
    await Future<void>.delayed(const Duration(seconds: 3));

    await db.update(table, otro['_id'], {'name': 'e2e-ruido-2'});
    await db.update(table, mio['_id'], {'name': 'e2e-vigilado-2'});

    await _esperarA(() => recibidos.isNotEmpty);
    // Un momento mas, por si el filtro no filtrara y llegara tambien el otro.
    await Future<void>.delayed(const Duration(seconds: 2));
    await sub.cancel();

    // El filtro lo aplica el servidor: la fila que no interesa no deberia
    // haber viajado siquiera.
    expect(recibidos, hasLength(1));
    expect(recibidos.single.record?['name'], 'e2e-vigilado-2');
  });

  test('dos suscripciones a la vez no se mezclan', () async {
    final tabla = <RobleChange>[];
    final registro = <RobleChange>[];

    final fila = await db.create(table, {'name': 'e2e-doble'});
    final id = fila['_id'].toString();
    creados.add(id);

    final subTabla = db.watchTable(table).listen(tabla.add);
    final subRegistro = db.watchRecord(table, id).listen(registro.add);
    await Future<void>.delayed(const Duration(seconds: 3));

    await db.update(table, id, {'name': 'e2e-doble-2'});

    await _esperarA(() => tabla.isNotEmpty && registro.isNotEmpty);
    await subTabla.cancel();
    await subRegistro.cancel();

    // Comparten un solo socket, asi que separarlas por subscriptionId es lo
    // unico que impide que una reciba lo de la otra.
    expect(tabla.single.record?['name'], 'e2e-doble-2');
    expect(registro.single.record?['name'], 'e2e-doble-2');
  });
}

/// Espera a que se cumpla [condicion], o falla al agotarse el plazo.
Future<void> _esperarA(
  bool Function() condicion, {
  Duration limite = const Duration(seconds: 20),
}) async {
  final fin = DateTime.now().add(limite);
  while (DateTime.now().isBefore(fin)) {
    if (condicion()) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('El cambio no llego en ${limite.inSeconds}s');
}

class _MemoriaStorage implements RobleTokenStorage {
  final _datos = <String, String>{};

  @override
  Future<String?> getItem(String key) async => _datos[key];

  @override
  Future<void> setItem(String key, String value) async => _datos[key] = value;

  @override
  Future<void> removeItem(String key) async => _datos.remove(key);
}
