import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:test/test.dart';

void main() {
  test('unspecified listeners only expand onto the same IP family', () {
    final v4Listen = MultiAddr('/ip4/0.0.0.0/udp/4001/udx');
    final v6Listen = MultiAddr('/ip6/::/udp/4001/udx');
    final v4Interface = MultiAddr('/ip4/10.0.0.2');
    final v6Interface = MultiAddr('/ip6/2001:db8::2');

    expect(addressesShareIPFamily(v4Listen, v4Interface), isTrue);
    expect(addressesShareIPFamily(v6Listen, v6Interface), isTrue);
    expect(addressesShareIPFamily(v4Listen, v6Interface), isFalse);
    expect(addressesShareIPFamily(v6Listen, v4Interface), isFalse);
  });
}
