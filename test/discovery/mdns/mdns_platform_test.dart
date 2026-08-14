import 'package:dart_libp2p/p2p/discovery/mdns/mdns.dart';
import 'package:test/test.dart';

void main() {
  test('disables port reuse on Android', () {
    expect(defaultMdnsReusePort(isAndroid: true), isFalse);
  });

  test('preserves port reuse on other platforms', () {
    expect(defaultMdnsReusePort(isAndroid: false), isTrue);
  });
}
