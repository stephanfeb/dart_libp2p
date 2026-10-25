import 'dart:typed_data';

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('Protocols registry', () {
    test('a /ble address round-trips through text and bytes', () {
      const text = '/ble/k3f9a2/p2p/12D3KooWL3dpNwLsf8MNvdaiiMe3YvgMARoinCHTnej3nQ8pnFb1';
      final addr = MultiAddr(text);
      expect(addr.toString(), equals(text));
      expect(addr.valueForProtocol('ble'), equals('k3f9a2'));
      expect(MultiAddr.fromBytes(addr.toBytes()).toString(), equals(text));
    });

    test('ble uses a private-use code', () {
      final code = Protocols.byName('ble')!.code;
      expect(code, inInclusiveRange(0x300000, 0x3fffff));
    });

    test('a registered protocol can be parsed and encoded', () {
      Protocols.register(const Protocol(name: 'test-reg-var', code: 0x3f0001, size: -1));
      Protocols.register(const Protocol(name: 'test-reg-flag', code: 0x3f0002, size: 0));
      const text = '/test-reg-var/abc/test-reg-flag';
      final addr = MultiAddr(text);
      expect(addr.toString(), equals(text));
      expect(MultiAddr.fromBytes(addr.toBytes()).toString(), equals(text));
    });

    test('registering an equal protocol again does nothing', () {
      const p = Protocol(name: 'test-reg-again', code: 0x3f0003, size: -1);
      Protocols.register(p);
      Protocols.register(p);
      expect(Protocols.byName('test-reg-again')!.code, equals(0x3f0003));
    });

    test('a conflicting name or code is rejected', () {
      expect(() => Protocols.register(const Protocol(name: 'tcp', code: 0x3f0004, size: -1)),
          throwsArgumentError);
      expect(() => Protocols.register(const Protocol(name: 'test-reg-dup', code: 0x0006, size: -1)),
          throwsArgumentError);
      expect(Protocols.byName('test-reg-dup'), isNull);
    });

    test('a fixed-size protocol is rejected', () {
      expect(() => Protocols.register(const Protocol(name: 'test-reg-fixed', code: 0x3f0005, size: 32)),
          throwsArgumentError);
    });

    test('an unknown code gives null from byCode and FormatException from fromBytes', () {
      expect(Protocols.byCode(0x3f00ff), isNull);
      // varint 0x3f00ff = ff 81 fc 01
      expect(() => MultiAddr.fromBytes(Uint8List.fromList([0xff, 0x81, 0xfc, 0x01])), throwsFormatException);
    });
  });
}
