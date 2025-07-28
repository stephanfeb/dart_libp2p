import 'dart:async';
import 'dart:math';

import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/protocol/autonatv2/client.dart';
import 'package:dart_libp2p/p2p/protocol/autonatv2/options.dart';
import 'package:dart_libp2p/p2p/protocol/autonatv2/server.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/network/network.dart';
import 'package:dart_libp2p/core/protocol/autonatv2/autonatv2.dart';
import 'package:logging/logging.dart';

import '../../../core/event/bus.dart';

final _log = Logger('autonatv2');

/// Implementation of the AutoNAT v2 service
class AutoNATv2Impl implements AutoNATv2 {
  final Host host;
  final bool allowPrivateAddrs;

  final AutoNATv2Server server;
  final AutoNATv2Client client;

  final _PeersMap _peers = _PeersMap();
  final Subscription? _subscription;

  /// Create a new AutoNAT v2 service
  ///
  /// [host] and [dialerHost] should have the same dialing capabilities. In case the host doesn't support
  /// a transport, dial back requests for address for that transport will be ignored.
  AutoNATv2Impl(Host host, Host dialerHost, {List<AutoNATv2Option>? options})
      : host = host,
        allowPrivateAddrs = _applyOptions(options).allowPrivateAddrs,
        server = AutoNATv2ServerImpl(host, dialerHost, _applyOptions(options)),
        client = AutoNATv2ClientImpl(host),
        _subscription = _subscribeToEvents(host);

  /// Apply options to the default settings
  static AutoNATv2Settings _applyOptions(List<AutoNATv2Option>? options) {
    var settings = defaultSettings();
    if (options != null) {
      for (final option in options) {
        settings = option(settings);
      }
    }
    return settings;
  }

  /// Subscribe to events for peer discovery
  static Subscription? _subscribeToEvents(Host host) {
    try {
      return host.eventBus.subscribe([
        'peer.protocols.updated',
        'peer.connectedness.changed',
        'peer.identification.completed',
      ]);
    } catch (e) {
      _log.warning('Failed to subscribe to events: $e');
      return null;
    }
  }

  @override
  Future<void> start() async {
    client.start();
    server.start();

    // Process events for peer discovery
    _subscription?.stream.listen((event) {
      final type = event['type'];
      final peerId = event['peerId'];

      if (type == 'peer.protocols.updated' ||
          type == 'peer.connectedness.changed' ||
          type == 'peer.identification.completed') {
        _updatePeer(peerId);
      }
    });
  }

  @override
  Future<void> close() async {
    await _subscription?.close();
    server.close();
    client.close();
  }

  @override
  Future<Result> getReachability(List<Request> requests) async {
    // Check if addresses are public
    if (!allowPrivateAddrs) {
      for (final request in requests) {
        if (!request.addr.isPublic()) {
          throw Exception('Private address cannot be verified by autonatv2: ${request.addr}');
        }
      }
    }

    // Get a random peer that supports AutoNAT v2
    final peerId = _peers.getRandom();
    if (peerId == null) {
      throw ClientErrors.noValidPeers;
    }

    try {
      // Get reachability from the peer
      final result = await client.getReachability(peerId, requests);
      _log.fine('Reachability check with $peerId successful');
      return result;
    } catch (e) {
      _log.fine('Reachability check with $peerId failed, err: $e');
      throw Exception('Reachability check with $peerId failed: $e');
    }
  }

  /// Update a peer in the peers map
  Future<void> _updatePeer(PeerId peerId) async {
    // Check if the peer supports the AutoNAT v2 protocol
    final protocols = await host.peerStore.protoBook.getProtocols(peerId);
    final connectedness = host.network.connectedness(peerId);

    if (protocols.contains(AutoNATv2Protocols.dialProtocol) && connectedness == Connectedness.connected) {
      _peers.put(peerId);
    } else {
      _peers.delete(peerId);
    }
  }
}

/// Map of peers that support AutoNAT v2
class _PeersMap {
  final Map<PeerId, int> _peerIdx = {};
  final List<PeerId> _peers = [];

  /// Get a random peer from the map
  PeerId? getRandom() {
    if (_peers.isEmpty) {
      return null;
    }
    return _peers[Random().nextInt(_peers.length)];
  }

  /// Add a peer to the map
  void put(PeerId peerId) {
    if (_peerIdx.containsKey(peerId)) {
      return;
    }
    _peers.add(peerId);
    _peerIdx[peerId] = _peers.length - 1;
  }

  /// Remove a peer from the map
  void delete(PeerId peerId) {
    final idx = _peerIdx[peerId];
    if (idx == null) {
      return;
    }

    // Move the last peer to the position of the removed peer
    _peers[idx] = _peers.last;
    _peerIdx[_peers[idx]] = idx;

    // Remove the last peer
    _peers.removeLast();
    _peerIdx.remove(peerId);
  }
}