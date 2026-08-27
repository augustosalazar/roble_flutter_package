import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:roble/roble.dart';

/// Almacén en memoria: evita flutter_secure_storage, que es un plugin nativo
/// y no está registrado bajo `flutter test`.
class MemoriaStorage implements RobleTokenStorage {
  final _datos = <String, String>{};
  @override
  Future<String?> getItem(String key) async => _datos[key];
  @override
  Future<void> setItem(String key, String value) async => _datos[key] = value;
  @override
  Future<void> removeItem(String key) async => _datos.remove(key);
}

void main() {
  final contrato = Platform.environment['ROBLE_CONTRACT_ID'];
  final base = Platform.environment['ROBLE_BASE_URL'] ??
      'https://roble-api.test-openlab.uninorte.edu.co';

  if (contrato == null || contrato.isEmpty) {
    test('falta ROBLE_CONTRACT_ID', () => fail('Define ROBLE_CONTRACT_ID'));
    return;
  }

  late RobleApiDataBase db;

  setUp(() {
    db = RobleApiDataBase(
      config: RobleApiConfig.fromContract(baseUrl: base, contractId: contrato),
      storage: MemoriaStorage(),
    );
  });

  test('sin sesión: los proveedores son públicos', () async {
    final proveedores = await db.listProviders();
    print('  proveedores: ${proveedores.map((p) => p.name).join(', ')}');
    expect(proveedores, isA<List<RobleProviderInfo>>());
  });

  test('flujo completo con una cuenta desechable', () async {
    final correo = 'smoke-${DateTime.now().millisecondsSinceEpoch}@ejemplo.test';
    var creada = false;

    try {
      await db.register(
          email: correo, password: 'SmokeClave!1', name: 'Smoke');
      creada = true;

      final user = await db.login(email: correo, password: 'SmokeClave!1');
      print('  login -> userId=${user['userId']} role=${user['role']}');
      expect(user['email'], correo);

      final col = '_smoke_${DateTime.now().millisecondsSinceEpoch}';
      final recibidos = <RobleChange>[];
      final sub = db.json.watch(col).listen(recibidos.add);
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      final id = await db.json.push(col, {'texto': 'hola'});
      print('  push -> $id');
      expect(await db.json.read(col), contains(id));

      await Future<void>.delayed(const Duration(milliseconds: 2500));
      print(recibidos.isEmpty
          ? '  AVISO tiempo real: no llegó ningún cambio'
          : '  tiempo real: llegó el cambio');
      expect(recibidos, isNotEmpty);

      await sub.cancel();
      await db.json.remove(col);
    } finally {
      // La cuenta se borra pase lo que pase: si no, cada corrida deja una.
      if (creada) await db.deleteAccount();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
