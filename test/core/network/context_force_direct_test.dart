import 'package:dart_libp2p/core/network/context.dart';
import 'package:test/test.dart';

void main() {
  group('force-direct dial context', () {
    test('accepts the public string-valued helper', () {
      expect(
        Context().withForceDirectDial('hole-punch').getForceDirectDial(),
        (true, 'hole-punch'),
      );
    });

    test('accepts the bool-valued form used by the responder', () {
      expect(
        Context().withValue('forceDirectDial', true).getForceDirectDial(),
        (true, 'true'),
      );
    });
  });
}
