import 'dart:io';
import 'dart:typed_data';

import 'package:dart_libp2p/p2p/nat/stun/stun_message.dart';
import 'package:test/test.dart';

Uint8List _hex(String s) {
  final clean = s.replaceAll(' ', '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2) int.parse(clean.substring(i, i + 2), radix: 16)
  ]);
}

void main() {
  // RFC 5769 test vectors, sections 2.2 and 2.3.
  final transactionId = _hex('b7e7a701bc34d686fa87dfae');

  group('StunMessage.decodeXorAddress', () {
    test('decodes the RFC 5769 IPv4 vector', () {
      final result = StunMessage.decodeXorAddress(_hex('0001 a147 e112a643'), transactionId);
      expect(result?.address, equals(InternetAddress('192.0.2.1')));
      expect(result?.port, equals(32853));
    });

    test('decodes the RFC 5769 IPv6 vector', () {
      final result = StunMessage.decodeXorAddress(
          _hex('0002 a147 0113a9fa a5d3f179 bc25f4b5 bed2b9d9'), transactionId);
      expect(result?.address, equals(InternetAddress('2001:db8:1234:5678:11:2233:4455:6677')));
      expect(result?.port, equals(32853));
    });

    test('rejects an unknown family and a short attribute', () {
      expect(StunMessage.decodeXorAddress(_hex('0003 a147 e112a643'), transactionId), isNull);
      // The family in the reserved byte, as the old encoder wrote it.
      expect(StunMessage.decodeXorAddress(_hex('0100 a147 e112a643'), transactionId), isNull);
      expect(StunMessage.decodeXorAddress(_hex('0002 a147 e112a643'), transactionId), isNull);
    });
  });

  group('StunMessage.decodeAddress', () {
    test('decodes IPv4 and IPv6', () {
      expect(StunMessage.decodeAddress(_hex('0001 1234 c0000201'))?.address,
          equals(InternetAddress('192.0.2.1')));
      final v6 = StunMessage.decodeAddress(_hex('0002 1234 20010db8000000000000000000000001'));
      expect(v6?.address, equals(InternetAddress('2001:db8::1')));
      expect(v6?.port, equals(0x1234));
    });

    test('rejects an IPv6 attribute that is too short', () {
      // Before, a family other than IPv4 read 16 bytes past a short attribute.
      expect(StunMessage.decodeAddress(_hex('0002 1234 c0000201')), isNull);
    });
  });

  test('createBindingResponse writes XOR-MAPPED-ADDRESS as RFC 5389 lays it out', () {
    final response = StunMessage.createBindingResponse(transactionId, InternetAddress('192.0.2.1'), 32853);
    final attr = response.attributes[StunAttribute.xorMappedAddress]!;
    expect(attr, equals(_hex('0001 a147 e112a643')));
    final decoded = StunMessage.decode(response.encode())!;
    final result = StunMessage.decodeXorAddress(
        decoded.attributes[StunAttribute.xorMappedAddress]!, decoded.transactionId);
    expect(result?.address, equals(InternetAddress('192.0.2.1')));
    expect(result?.port, equals(32853));
  });
}
