import 'dart:async';

import '../../core/multiaddr.dart';
import '../../core/network/conn.dart';
import 'listener.dart';
import 'transport_config.dart';

/// Represents a libp2p transport protocol (e.g., TCP, QUIC)
abstract class Transport {
  /// The configuration for this transport
  TransportConfig get config;

  /// Dials a peer at the given multiaddress with optional timeout override.
  /// Returns a connection to the peer if successful.
  ///
  /// [simultaneousConnect] signals that this dial is a DCUtR
  /// simultaneous-connect (hole-punch) attempt rather than an ordinary dial.
  /// Transports that support NAT hole-punching may use this to change how
  /// the dial is performed — e.g. reusing an active listener's socket so
  /// the dial originates from the address already advertised to the peer.
  /// Transports that don't support hole-punching may ignore it.
  Future<Conn> dial(MultiAddr addr, {Duration? timeout, bool simultaneousConnect = false});

  /// Starts listening on the given multiaddress
  /// Returns a listener that can accept incoming connections
  Future<Listener> listen(MultiAddr addr);

  /// Returns the list of protocols supported by this transport
  /// For example: ['/ip4/tcp', '/ip6/tcp']
  List<String> get protocols;

  /// Returns true if this transport can dial the given multiaddress
  bool canDial(MultiAddr addr);

  /// Returns true if this transport can listen on the given multiaddress
  bool canListen(MultiAddr addr);

  //Close this transport and dispose of it's resources
  Future<void> dispose();
}