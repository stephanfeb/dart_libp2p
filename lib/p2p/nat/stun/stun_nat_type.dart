import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

import '../../../core/event/nattype.dart';
import 'stun_client.dart';
import 'stun_client_pool.dart';
import 'stun_message.dart';

final _log = Logger('stun_nat_type');

/// Finds out whether this host's NAT maps UDP like a cone or like a
/// symmetric NAT, with two STUN servers.
///
/// One local socket asks two servers for the address they see. A cone NAT
/// (endpoint-independent mapping) shows both servers the same address and
/// port. A symmetric NAT makes a new mapping for each destination, so the
/// servers see different ports. A hole punch through a symmetric NAT works
/// only when the other NAT is lenient, because the peer cannot know the port
/// to send to.
///
/// The two servers should have different IP addresses: with the same IP, an
/// address-dependent mapping looks like a cone.
class StunNatTypeProbe {
  /// The STUN servers to ask. At least two must answer.
  final List<({String host, int port})> servers;

  /// How long to wait for the answers.
  final Duration timeout;

  StunNatTypeProbe({
    List<({String host, int port})>? servers,
    this.timeout = const Duration(seconds: 5),
  }) : servers = servers ?? StunClientPool.defaultStunServers;

  /// Returns [NATDeviceType.cone] or [NATDeviceType.symmetric], or
  /// [NATDeviceType.unknown] when fewer than two servers answered.
  Future<NATDeviceType> probe() async {
    final targets = await _resolveTargets();
    if (targets.length < 2) {
      _log.fine('Fewer than two STUN servers resolved; NAT type unknown');
      return NATDeviceType.unknown;
    }

    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final pending = <String, ({InternetAddress address, int port})>{};
    final mapped = <({InternetAddress address, int port})>[];
    final done = Completer<void>();
    try {
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        final message = StunMessage.decode(datagram.data);
        if (message == null) return;
        final key = message.transactionId.join(',');
        if (pending.remove(key) == null) return;
        final address = StunClient.mappedAddressOf(message);
        if (address != null) mapped.add(address);
        if (mapped.length >= 2 && !done.isCompleted) done.complete();
      });

      // Ask every resolved server from the same socket; two answers decide.
      for (final target in targets) {
        final request = StunMessage.createBindingRequest();
        pending[request.transactionId.join(',')] = target;
        socket.send(request.encode(), target.address, target.port);
      }
      await done.future.timeout(timeout, onTimeout: () {});
    } finally {
      socket.close();
    }

    if (mapped.length < 2) {
      _log.fine('Only ${mapped.length} STUN server(s) answered; NAT type unknown');
      return NATDeviceType.unknown;
    }
    final first = mapped[0];
    final second = mapped[1];
    final same = first.address.address == second.address.address && first.port == second.port;
    final type = same ? NATDeviceType.cone : NATDeviceType.symmetric;
    _log.fine('STUN mapped addresses ${first.address.address}:${first.port} and '
        '${second.address.address}:${second.port}: $type');
    return type;
  }

  /// The IPv4 endpoints of [servers], each one once.
  Future<List<({InternetAddress address, int port})>> _resolveTargets() async {
    final targets = <({InternetAddress address, int port})>[];
    final seen = <String>{};
    for (final server in servers) {
      try {
        final parsed = InternetAddress.tryParse(server.host);
        final addresses = parsed != null
            ? [parsed]
            : await InternetAddress.lookup(server.host, type: InternetAddressType.IPv4)
                .timeout(StunClient.dnsTimeout);
        for (final a in addresses) {
          if (a.type != InternetAddressType.IPv4) continue;
          if (seen.add('${a.address}:${server.port}')) {
            targets.add((address: a, port: server.port));
          }
          break;
        }
      } catch (e) {
        _log.fine('Could not resolve STUN server ${server.host}: $e');
      }
    }
    return targets;
  }
}
