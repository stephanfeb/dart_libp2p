import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/core/connmgr/conn_gater.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/network/conn_gater.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:test/test.dart';

Future<Host> _host({ConnGater? gater}) async {
  final keyPair = await generateEd25519KeyPair();
  final host = await Libp2p.new_([
    Libp2p.identity(keyPair),
    Libp2p.transport(TCPTransport()),
    Libp2p.security(await NoiseSecurity.create(keyPair)),
    Libp2p.listenAddrs([MultiAddr('/ip4/127.0.0.1/tcp/0')]),
    Libp2p.autoNAT(false),
    Libp2p.relay(false),
    Libp2p.autoRelay(false),
    Libp2p.holePunching(false),
    if (gater != null) Libp2p.connectionGater(gater),
  ]);
  await host.start();
  return host;
}

/// Records each call and allows all, except an upgraded connection when
/// [allowUpgraded] is false.
class _RecordingGater implements ConnGater {
  final calls = <String>[];
  bool allowUpgraded = true;

  @override
  bool interceptPeerDial(PeerId peerId) {
    calls.add('peerDial');
    return true;
  }

  @override
  bool interceptAddrDial(PeerId peerId, MultiAddr addr) {
    calls.add('addrDial');
    return true;
  }

  @override
  bool interceptAccept(Conn conn) {
    calls.add('accept');
    return true;
  }

  @override
  bool interceptSecured(bool isInitiator, PeerId peerId, Conn conn) {
    calls.add('secured(${isInitiator ? 'out' : 'in'})');
    return true;
  }

  @override
  (bool, DisconnectReason?) interceptUpgraded(Conn conn) {
    calls.add('upgraded');
    return (allowUpgraded, null);
  }
}

Matcher _gaterRejection(String check) =>
    throwsA(predicate((e) => '$e'.contains('GaterDisallowedConnectionException') && '$e'.contains(check)));

/// Waits until [host] has no connections; a rejected peer sees the close a
/// little later.
Future<void> _noConns(Host host) async {
  for (var i = 0; i < 50 && host.network.conns.isNotEmpty; i++) {
    await Future.delayed(const Duration(milliseconds: 20));
  }
  expect(host.network.conns, isEmpty);
}

void main() {
  group('Connection gater', () {
    final hosts = <Host>[];

    Future<Host> host({ConnGater? gater}) async {
      final h = await _host(gater: gater);
      hosts.add(h);
      return h;
    }

    tearDown(() async {
      for (final h in hosts) {
        await h.close();
      }
      hosts.clear();
    });

    test('calls every check in order on both sides of a connection', () async {
      final dialerGater = _RecordingGater();
      final answererGater = _RecordingGater();
      final dialer = await host(gater: dialerGater);
      final answerer = await host(gater: answererGater);

      await dialer.connect(AddrInfo(answerer.id, answerer.network.listenAddresses));

      expect(dialerGater.calls, equals(['peerDial', 'addrDial', 'secured(out)', 'upgraded']));
      for (var i = 0; i < 50 && answererGater.calls.length < 3; i++) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      expect(answererGater.calls, equals(['accept', 'secured(in)', 'upgraded']));
    });

    test('interceptPeerDial: a blocked peer is not dialed', () async {
      final gater = BasicConnGater();
      final dialer = await host(gater: gater);
      final answerer = await host();
      gater.blockPeer(answerer.id);

      await expectLater(
        dialer.connect(AddrInfo(answerer.id, answerer.network.listenAddresses)),
        _gaterRejection('interceptPeerDial'),
      );
      await _noConns(dialer);
      await _noConns(answerer);
    });

    test('interceptPeerDial: the swarm does not return an existing connection once the peer is blocked', () async {
      final gater = BasicConnGater();
      final dialer = await host(gater: gater);
      final answerer = await host();
      await dialer.connect(AddrInfo(answerer.id, answerer.network.listenAddresses));
      gater.blockPeer(answerer.id);

      // As in go-libp2p, host.connect returns at once for a connected peer;
      // the gater applies to the swarm's dial.
      await expectLater(
        dialer.network.dialPeer(Context(), answerer.id),
        _gaterRejection('interceptPeerDial'),
      );
    });

    test('interceptAddrDial: a blocked IP is not dialed', () async {
      final gater = BasicConnGater()..blockAddr(MultiAddr('/ip4/127.0.0.1'));
      final dialer = await host(gater: gater);
      final answerer = await host();

      await expectLater(
        dialer.connect(AddrInfo(answerer.id, answerer.network.listenAddresses)),
        throwsA(predicate((e) => '$e'.contains('No dialable addresses'))),
      );
      await _noConns(answerer);
    });

    test('interceptAccept: a connection from a blocked subnet is refused', () async {
      final dialer = await host();
      final answerer = await host(gater: BasicConnGater()..blockSubnet('127.0.0.0/8'));

      await expectLater(
        dialer.connect(AddrInfo(answerer.id, answerer.network.listenAddresses)),
        throwsA(anything),
      );
      await _noConns(answerer);
      await _noConns(dialer);
    });

    test('interceptSecured: an inbound connection from a blocked peer is refused', () async {
      final gater = BasicConnGater();
      final dialer = await host();
      final answerer = await host(gater: gater);
      gater.blockPeer(dialer.id);

      await expectLater(
        dialer.connect(AddrInfo(answerer.id, answerer.network.listenAddresses)),
        throwsA(anything),
      );
      await _noConns(answerer);
      await _noConns(dialer);
    });

    test('interceptUpgraded: a rejected outbound connection is closed and not kept', () async {
      final gater = _RecordingGater()..allowUpgraded = false;
      final dialer = await host(gater: gater);
      final answerer = await host();

      await expectLater(
        dialer.connect(AddrInfo(answerer.id, answerer.network.listenAddresses)),
        _gaterRejection('interceptUpgraded'),
      );
      await _noConns(dialer);
      await _noConns(answerer);
    });

    test('interceptUpgraded: a rejected inbound connection is closed and not kept', () async {
      final dialer = await host();
      final answerer = await host(gater: _RecordingGater()..allowUpgraded = false);

      try {
        await dialer.connect(AddrInfo(answerer.id, answerer.network.listenAddresses));
      } catch (_) {
        // The dialer may finish its upgrade before the answerer closes.
      }
      await _noConns(answerer);
      await _noConns(dialer);
    });
  });
}
