import 'dart:io';

import 'package:dart_libp2p/core/connmgr/conn_gater.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:logging/logging.dart';

/// BasicConnGater is a ConnGater that allows all connections except those to
/// blocked peers, addresses or subnets, like go-libp2p's
/// BasicConnectionGater. Give it to a host with `Libp2p.connectionGater`.
///
/// It keeps no state for each connection. Connection limits belong to the
/// resource manager (`Libp2p.resourceLimiter`) and the connection manager.
class BasicConnGater implements ConnGater {
  final Logger _logger = Logger('BasicConnGater');

  /// Set of blocked peer IDs
  final Set<PeerId> _blockedPeers = {};

  /// Set of blocked multiaddresses
  final Set<MultiAddr> _blockedAddrs = {};

  /// Set of blocked connections
  final Set<String> _blockedConns = {};

  /// Set of blocked subnets
  final Set<String> _blockedSubnets = {};

  /// Creates a new BasicConnGater with no blocks.
  ///
  /// The parameters have no effect: nothing told this gater when a
  /// connection closed, so its limits counted connections that were gone.
  BasicConnGater({
    @Deprecated('No effect. Use the resource manager limits. Removed in 5.0.') int maxConnections = 1000,
    @Deprecated('No effect. Use the resource manager limits. Removed in 5.0.') int maxConnectionsPerPeer = 10,
    @Deprecated('No effect. Removed in 5.0.') Duration connectionTimeout = const Duration(minutes: 5),
  });

  /// BlockPeer blocks a peer by its ID
  void blockPeer(PeerId peerId) {
    _blockedPeers.add(peerId);
    _logger.fine('Blocked peer: $peerId');
  }

  /// UnblockPeer unblocks a previously blocked peer
  void unblockPeer(PeerId peerId) {
    _blockedPeers.remove(peerId);
    _logger.fine('Unblocked peer: $peerId');
  }

  /// BlockAddr blocks [addr] and every address that starts with it. Thus
  /// `/ip4/1.2.3.4` blocks all ports of that IP, as go-libp2p's BlockAddr
  /// does, and `/ip4/1.2.3.4/tcp/4001` blocks only that address.
  void blockAddr(MultiAddr addr) {
    _blockedAddrs.add(addr);
    _logger.fine('Blocked address: $addr');
  }

  /// UnblockAddr unblocks a previously blocked address
  void unblockAddr(MultiAddr addr) {
    _blockedAddrs.remove(addr);
    _logger.fine('Unblocked address: $addr');
  }

  /// BlockConn blocks a specific connection by its ID
  void blockConn(String connId) {
    _blockedConns.add(connId);
    _logger.fine('Blocked connection: $connId');
  }

  /// UnblockConn unblocks a previously blocked connection
  void unblockConn(String connId) {
    _blockedConns.remove(connId);
    _logger.fine('Unblocked connection: $connId');
  }

  /// BlockSubnet blocks a subnet (CIDR notation)
  void blockSubnet(String subnet) {
    _blockedSubnets.add(subnet);
    _logger.fine('Blocked subnet: $subnet');
  }

  /// UnblockSubnet unblocks a previously blocked subnet
  void unblockSubnet(String subnet) {
    _blockedSubnets.remove(subnet);
    _logger.fine('Unblocked subnet: $subnet');
  }

  /// IsPeerBlocked returns whether a peer is blocked
  bool isPeerBlocked(PeerId peerId) {
    return _blockedPeers.contains(peerId);
  }

  /// IsAddrBlocked returns whether [addr] is a blocked address or starts
  /// with one (see [blockAddr]).
  bool isAddrBlocked(MultiAddr addr) {
    return _blockedAddrs.any((blocked) => _startsWith(addr, blocked));
  }

  /// IsConnBlocked returns whether a connection is blocked
  bool isConnBlocked(String connId) {
    return _blockedConns.contains(connId);
  }

  /// IsSubnetBlocked returns whether a subnet is blocked
  bool isSubnetBlocked(String subnet) {
    return _blockedSubnets.contains(subnet);
  }

  /// Checks if an address is in a blocked subnet
  bool isAddrInBlockedSubnet(MultiAddr addr) {
    for (final subnet in _blockedSubnets) {
      if (_isAddrInSubnet(addr, subnet)) {
        return true;
      }
    }
    return false;
  }

  /// Whether the components of [addr] begin with all components of [prefix].
  static bool _startsWith(MultiAddr addr, MultiAddr prefix) {
    final a = addr.components;
    final p = prefix.components;
    if (p.isEmpty || p.length > a.length) return false;
    for (var i = 0; i < p.length; i++) {
      if (a[i].$1.code != p[i].$1.code || a[i].$2 != p[i].$2) return false;
    }
    return true;
  }

  /// Helper method to check if an address is in a subnet
  bool _isAddrInSubnet(MultiAddr addr, String subnet) {
    try {
      // Extract IP address from multiaddr
      final ipAddr = addr.valueForProtocol('ip4') ?? addr.valueForProtocol('ip6');
      if (ipAddr == null) return false;

      // Parse CIDR notation
      final parts = subnet.split('/');
      if (parts.length != 2) return false;

      final subnetAddr = parts[0];
      final prefixLen = int.parse(parts[1]);

      // Convert IP addresses to binary form
      final ipBytes = InternetAddress.tryParse(ipAddr)?.rawAddress;
      final subnetBytes = InternetAddress.tryParse(subnetAddr)?.rawAddress;
      if (ipBytes == null || subnetBytes == null) return false;

      if (ipBytes.length != subnetBytes.length) return false;

      // Check if IP is in subnet
      final mask = _createMask(prefixLen, ipBytes.length);
      for (var i = 0; i < ipBytes.length; i++) {
        if ((ipBytes[i] & mask[i]) != (subnetBytes[i] & mask[i])) {
          return false;
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Helper method to create a subnet mask
  List<int> _createMask(int prefixLen, int addrLen) {
    final mask = List<int>.filled(addrLen, 0);
    for (var i = 0; i < addrLen; i++) {
      if (prefixLen > 8) {
        mask[i] = 0xFF;
        prefixLen -= 8;
      } else {
        mask[i] = (0xFF << (8 - prefixLen)) & 0xFF;
        break;
      }
    }
    return mask;
  }

  /// Whether [addr] is blocked as an address or by a subnet.
  bool _isAddrDisallowed(MultiAddr addr) {
    return isAddrBlocked(addr) || isAddrInBlockedSubnet(addr);
  }

  /// No effect: the gater keeps no connection metrics.
  @Deprecated('No effect. Removed in 5.0.')
  void updateConnectionMetrics(String connId, {int? bytesIn, int? bytesOut}) {}

  /// Returns null: the gater keeps no connection metrics.
  @Deprecated('Always null. Removed in 5.0.')
  // ignore: deprecated_member_use_from_same_package
  ConnectionMetrics? getConnectionMetrics(String connId) => null;

  @override
  bool interceptPeerDial(PeerId peerId) {
    if (isPeerBlocked(peerId)) {
      _logger.fine('Blocked peer dial: $peerId');
      return false;
    }
    return true;
  }

  @override
  bool interceptAddrDial(PeerId peerId, MultiAddr addr) {
    // Check if the peer is blocked
    if (isPeerBlocked(peerId)) {
      _logger.fine('Blocked peer dial: $peerId');
      return false;
    }

    // Check if the address is blocked
    if (isAddrBlocked(addr)) {
      _logger.fine('Blocked address dial: $addr');
      return false;
    }

    // Check if the address is in a blocked subnet
    if (isAddrInBlockedSubnet(addr)) {
      _logger.fine('Blocked subnet dial: $addr');
      return false;
    }

    return true;
  }

  @override
  bool interceptAccept(Conn conn) {
    // The remote peer is not known before the security handshake: decide on
    // the remote address, as go-libp2p does.
    if (_isAddrDisallowed(conn.remoteMultiaddr)) {
      _logger.fine('Blocked connection accept from: ${conn.remoteMultiaddr}');
      return false;
    }
    if (isConnBlocked(conn.id)) {
      _logger.fine('Blocked connection accept: ${conn.id}');
      return false;
    }
    return true;
  }

  @override
  bool interceptSecured(bool isInitiator, PeerId peerId, Conn conn) {
    if (isPeerBlocked(peerId)) {
      _logger.fine('Blocked secured connection: $peerId');
      return false;
    }
    if (isConnBlocked(conn.id)) {
      _logger.fine('Blocked secured connection: ${conn.id}');
      return false;
    }
    return true;
  }

  @override
  (bool, DisconnectReason?) interceptUpgraded(Conn conn) {
    if (isPeerBlocked(conn.remotePeer)) {
      _logger.fine('Blocked upgraded connection: ${conn.remotePeer}');
      return (
        false,
        DisconnectReason(
          code: 1,
          message: 'Peer is blocked',
        ),
      );
    }
    if (isConnBlocked(conn.id)) {
      _logger.fine('Blocked upgraded connection: ${conn.id}');
      return (
        false,
        DisconnectReason(
          code: 2,
          message: 'Connection is blocked',
        ),
      );
    }
    return (true, null);
  }

  /// No effect: the gater holds no resources.
  @Deprecated('No effect. Removed in 5.0.')
  void close() {}
}

/// Connection metrics. BasicConnGater no longer records them.
@Deprecated('BasicConnGater keeps no connection metrics. Removed in 5.0.')
class ConnectionMetrics {
  final PeerId peerId;
  final DateTime startTime;
  int bytesIn = 0;
  int bytesOut = 0;

  ConnectionMetrics({
    required this.peerId,
    required this.startTime,
  });

  /// Gets the connection duration
  Duration get duration => DateTime.now().difference(startTime);

  /// Gets the total bytes transferred
  int get totalBytes => bytesIn + bytesOut;
}
