import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:roble/roble.dart';

const baseUrl = 'https://roble-api.test';
const contractId = 'proyecto_ab12';

/// Cliente que responde siempre lo mismo y recuerda lo que se le pidió.
class Espia {
  final List<http.Request> peticiones = [];
  final Object respuesta;

  Espia([this.respuesta = const {'rows': [], 'rowCount': 0}]);

  RobleApiDataBase get db => RobleApiDataBase(
        config: RobleApiConfig.fromContract(
          baseUrl: baseUrl,
          contractId: contractId,
        ),
        storage: RobleMemoryStorage(),
        client: MockClient((req) async {
          peticiones.add(req);
          return http.Response(jsonEncode(respuesta), 200,
              headers: {'content-type': 'application/json'});
        }),
      );
}

void main() {
  group('executeQueryByName', () {
    test('pega en la ruta by-name del proyecto', () async {
      final espia = Espia();

      await espia.db.executeQueryByName('ranking_mensual');

      expect(
        espia.peticiones.single.url.toString(),
        '$baseUrl/database/$contractId/saved-queries/by-name/'
        'ranking_mensual/execute',
      );
      expect(espia.peticiones.single.method, 'POST');
    });

    test('escapa nombres con espacios y acentos', () async {
      final espia = Espia();

      await espia.db.executeQueryByName('ranking de créditos');

      final url = espia.peticiones.single.url;
      expect(url.toString(), contains('ranking%20de%20cr%C3%A9ditos'));
      // Al decodificar, los segmentos vuelven a ser los originales.
      expect(url.pathSegments, contains('ranking de créditos'));
    });

    test('sin params el cuerpo va vacío', () async {
      final espia = Espia();

      await espia.db.executeQueryByName('q');

      expect(jsonDecode(espia.peticiones.single.body), <String, dynamic>{});
    });

    test('con params los manda en el cuerpo', () async {
      final espia = Espia();

      await espia.db.executeQueryByName('q', params: [2026, 'agosto']);

      expect(jsonDecode(espia.peticiones.single.body), {
        'params': [2026, 'agosto'],
      });
    });

    test('parsea el resultado igual que executeQuery', () async {
      final espia = Espia({
        'success': true,
        'command': 'SELECT',
        'rowCount': 2,
        'rows': [
          {'nombre': 'Ana'},
          {'nombre': 'Luis'},
        ],
        'fields': [
          {'name': 'nombre'},
        ],
      });

      final res = await espia.db.executeQueryByName('q');

      expect(res, isA<RobleQueryResult>());
      expect(res.success, isTrue);
      expect(res.rowCount, 2);
      expect(res.rows.length, 2);
      expect(res.fields.single['name'], 'nombre');
    });

    test('lleva el bearer: no es un endpoint público', () async {
      final espia = Espia();
      final db = espia.db;
      // Sin sesión no hay cabecera, pero tampoco se omite a propósito.
      await db.executeQueryByName('q');

      expect(espia.peticiones.single.headers['Content-Type'],
          contains('application/json'));
    });

    group('rechaza nombres vacíos', () {
      for (final nombre in ['', '   ', '\n']) {
        test('«${nombre.trim()}»', () {
          expect(
            () => Espia().db.executeQueryByName(nombre),
            throwsA(isA<ArgumentError>()),
          );
        });
      }
    });
  });
}
