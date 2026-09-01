import 'package:flutter_test/flutter_test.dart';
import 'package:roble/roble.dart';

void main() {
  group('identidad', () {
    test('prefiere userId sobre id', () {
      // El servidor manda los dos y no son lo mismo: `id` es el registro del
      // perfil, `userId` es con lo que se comparan los campos tipo `autorId`.
      final user = RobleUser.fromJson({
        'id': 'registro-1',
        'userId': 'u1',
        'email': 'ana@correo.com',
        'name': 'Ana',
      });

      expect(user.userId, 'u1');
      expect(user.id, 'registro-1');
    });

    test('acepta los nombres que ha ido usando el servidor', () {
      for (final clave in ['userId', 'id', '_id', 'sub']) {
        final user = RobleUser.fromJson({
          clave: 'u1',
          'email': 'ana@correo.com',
          'name': 'Ana',
        });

        expect(user.userId, 'u1', reason: 'con la clave $clave');
      }
    });
  });

  group('rol', () {
    test('se lee del perfil', () {
      final user = RobleUser.fromJson({
        'userId': 'u1',
        'email': 'ana@correo.com',
        'name': 'Ana',
        'role': 'admin',
      });

      expect(user.role, 'admin');
    });

    test('sin rol asignado queda en null, no revienta', () {
      final user = RobleUser.fromJson({
        'userId': 'u1',
        'email': 'ana@correo.com',
        'name': 'Ana',
        'role': null,
      });

      expect(user.role, isNull);
    });

    test('un backend anterior a v1.7.8 tampoco revienta', () {
      // Ahí el perfil todavía no traía el campo.
      final user = RobleUser.fromJson({
        'userId': 'u1',
        'email': 'ana@correo.com',
        'name': 'Ana',
      });

      expect(user.role, isNull);
    });
  });

  group('fechas', () {
    test('llegan como DateTime', () {
      final user = RobleUser.fromJson({
        'userId': 'u1',
        'email': 'ana@correo.com',
        'name': 'Ana',
        'createdAt': '2026-08-26T12:00:00.000Z',
      });

      expect(user.createdAt, DateTime.parse('2026-08-26T12:00:00.000Z'));
    });

    test('una fecha ilegible no se lleva por delante el perfil entero', () {
      final user = RobleUser.fromJson({
        'userId': 'u1',
        'email': 'ana@correo.com',
        'name': 'Ana',
        'createdAt': 'el martes',
      });

      expect(user.createdAt, isNull);
      expect(user.email, 'ana@correo.com');
    });
  });

  test('lo que el paquete no conoce sigue estando en raw', () {
    // Un campo nuevo del backend tiene que poder leerse sin esperar a una
    // versión del paquete.
    final user = RobleUser.fromJson({
      'userId': 'u1',
      'email': 'ana@correo.com',
      'name': 'Ana',
      'plan': 'premium',
    });

    expect(user.raw['plan'], 'premium');
  });

  test('extra viaja tal cual', () {
    final user = RobleUser.fromJson({
      'userId': 'u1',
      'email': 'ana@correo.com',
      'name': 'Ana',
      'extra': {'carrera': 'IST'},
    });

    expect(user.extra?['carrera'], 'IST');
  });
}
