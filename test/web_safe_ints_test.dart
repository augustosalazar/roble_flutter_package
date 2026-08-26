@TestOn('browser')
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

/// En web los enteros de Dart son numeros de JavaScript, y el desplazamiento
/// usa la semantica de JS: `1 << 32` da 0, no 2^32. `Random.nextInt(0)` lanza
/// `RangeError`.
///
/// Eso rompia la suscripcion en tiempo real solo en web: el identificador de
/// peticion se generaba con ese limite, asi que el cliente conectaba el socket
/// y reventaba justo antes de emitir el `subscribe`. El servidor veia una
/// conexion sin suscripciones y la app se quedaba esperando para siempre. En la
/// VM el mismo codigo funciona, por lo que las pruebas de extremo a extremo no
/// lo vieron.
void main() {
  test('un desplazamiento de 32 no sirve como limite en web', () {
    expect(1 << 32, 0);
    expect(() => Random().nextInt(1 << 32), throwsRangeError);
  });

  test('el limite que usa el cliente sí vale en web', () {
    expect(0xFFFFFFFF, 4294967295);
    expect(() => Random().nextInt(0xFFFFFFFF), returnsNormally);
  });
}
