import 'dart:async';

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/p2p/network/connmgr/null_conn_mgr.dart';
import 'package:dart_libp2p/p2p/transport/listener.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:test/test.dart';

// Regression test for issue: dart_libp2p crashes on IPv6 listen
// (observed-addr FormatException). TCPTransport.listen()/dial() and
// TCPListener._handleConnection() used to hardcode the "/ip4/" protocol tag
// when building bound/local/remote multiaddrs, so listening or accepting a
// connection on an IPv6 socket produced a malformed multiaddr like
// "/ip4/::1/tcp/1234" and MultiAddr's codec/validator threw
// FormatException('Invalid IPv4 address').
void main() {
  group('TCPTransport IPv6', () {
    late ResourceManager resourceManager;
    late NullConnMgr connManager;
    late TCPTransport transport;

    setUp(() {
      resourceManager = NullResourceManager();
      connManager = NullConnMgr();
      transport = TCPTransport(connManager: connManager, resourceManager: resourceManager);
    });

    tearDown(() async {
      await transport.dispose();
    });

    test('listen on an IPv6 loopback addr does not throw and yields an /ip6 bound addr', () async {
      final listenAddr = MultiAddr('/ip6/::1/tcp/0');

      final Listener listener = await transport.listen(listenAddr);
      // TCPListener.close() only completes once its (single-subscription)
      // connectionStream has been listened to, so subscribe before closing.
      final sub = listener.connectionStream.listen((_) {});
      addTearDown(sub.cancel);
      addTearDown(listener.close);

      expect(listener.addr.hasProtocol('ip6'), isTrue);
      expect(listener.addr.hasProtocol('ip4'), isFalse);
      // Would previously throw FormatException before this assertion is
      // ever reached, while building the bound addr.
      expect(listener.addr.valueForProtocol('ip6'), '::1');
    });

    test('dialing an IPv6 listener succeeds and reports /ip6 local/remote addrs', () async {
      final listener = await transport.listen(MultiAddr('/ip6/::1/tcp/0'));
      addTearDown(listener.close);

      final acceptedConns = <void>[];
      final acceptSub = listener.connectionStream.listen((conn) {
        acceptedConns.add(null);
      });
      addTearDown(acceptSub.cancel);

      final conn = await transport.dial(listener.addr);
      addTearDown(conn.close);

      expect(conn.localMultiaddr.hasProtocol('ip6'), isTrue);
      expect(conn.remoteMultiaddr.hasProtocol('ip6'), isTrue);
    });
  });
}
