import 'dart:typed_data';

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart';
import 'package:test/test.dart';

Uint8List _hex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
    ]);

String _toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // Bytes from go-multiaddr v0.16.1 (ma.NewMultiaddr(s).Bytes()).
  const goVectors = {
    '/dns4/teranode-eks-testnet-eu-1-p2p.bsvb.tech/tcp/9905':
        '3627746572616e6f64652d656b732d746573746e65742d65752d312d7032702e627376622e746563680626b1',
    '/dns6/example.com/tcp/443': '370b6578616d706c652e636f6d0601bb',
    '/dns/example.com/udp/4001': '350b6578616d706c652e636f6d91020fa1',
    '/dnsaddr/testnet.bootstrap.teranode.bsvb.tech':
        '3824746573746e65742e626f6f7473747261702e746572616e6f64652e627376622e74656368',
    '/ip4/1.2.3.4/udp/4001/quic-v1/webtransport/certhash/uEiDDq4_xNyDorZBH3TlGazyJdOWSwvo4PUo5YHFMrvDE8g/sni/example.com':
        '040102030491020fa1cd03d103d203221220c3ab8ff13720e8ad9047dd39466b3c8974e592c2fa383d4a3960714caef0c4f2c1030b6578616d706c652e636f6d',
  };

  group('MultiAddr bytes match go-multiaddr', () {
    goVectors.forEach((text, goHex) {
      test('encode $text', () {
        expect(_toHex(MultiAddr(text).toBytes()), equals(goHex));
      });

      test('decode $text', () {
        expect(MultiAddr.fromBytes(_hex(goHex)).toString(), equals(text));
      });
    });

    test('protocol codes match go-multiaddr', () {
      const goCodes = {
        'ip4': 0x0004, 'tcp': 0x0006, 'udp': 0x0111, 'ip6': 0x0029,
        'dns': 0x0035, 'dns4': 0x0036, 'dns6': 0x0037, 'dnsaddr': 0x0038,
        'p2p': 0x01a5, 'unix': 0x0190, 'quic-v1': 0x01cd,
        'webtransport': 0x01d1, 'certhash': 0x01d2, 'sni': 0x01c1,
        'p2p-circuit': 0x0122, 'webrtc': 0x0119, 'webrtc-direct': 0x0118,
      };
      goCodes.forEach((name, code) {
        expect(Protocols.byName(name)?.code, equals(code), reason: name);
      });
    });

    test('a base58 certhash encodes to the same bytes and prints as base64url, as in go', () {
      final addr = MultiAddr(
          '/ip4/1.2.3.4/udp/4001/quic-v1/webtransport/certhash/zQmbWTwYGcmdyK9CYfNBcfs9nhZs17a6FQ4Y8oea278xx41');
      final roundTrip = MultiAddr.fromBytes(addr.toBytes());
      expect(roundTrip.certhash, equals('uEiDDq4_xNyDorZBH3TlGazyJdOWSwvo4PUo5YHFMrvDE8g'));
    });

    test('a dns4 address with a peer ID round-trips through bytes', () {
      const text = '/dns4/example.com/tcp/9905/p2p/12D3KooWD3eckifWpRn9wQpMG9R9hX3sD158z7EqHWmweQAJU5SA';
      expect(MultiAddr.fromBytes(MultiAddr(text).toBytes()).toString(), equals(text));
    });
  });
}
