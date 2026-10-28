import 'package:flutter_test/flutter_test.dart';
import 'package:sonify/shuffle_order.dart';

void main() {
  test('play next inserts immediately after the current shuffled entry', () {
    final order = SonifyShuffleOrder();
    order.indices.addAll([2, 0, 1]);
    order.insertAfter = 0;
    order.insert(1, 1);
    expect(order.indices, [3, 0, 1, 2]);
    expect(order.insertAfter, isNull);
    order.removeRange(0, 1);
    expect(order.indices.toSet(), {0, 1, 2});
    expect(order.indices, [2, 0, 1]);
  });
  test('clearing resets pending insertion preferences', () {
    final order = SonifyShuffleOrder()..insertAfter = 2;
    order.clear();
    expect(order.insertAfter, isNull);
    order.insert(0, 4);
    expect(order.indices.toSet(), {0, 1, 2, 3});
  });
}
