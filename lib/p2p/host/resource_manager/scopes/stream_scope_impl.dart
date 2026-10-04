import 'dart:async';

import 'package:dart_libp2p/core/network/common.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart' as concrete_peer_id; // For concrete PeerId type
import 'package:dart_libp2p/core/protocol/protocol.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/limit.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/resource_manager_impl.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/scope_impl.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/scopes/peer_scope_impl.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/scopes/protocol_scope_impl.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/scopes/service_scope_impl.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/scopes/transient_scope_impl.dart'; // Added
import 'package:dart_libp2p/p2p/host/resource_manager/scopes/system_scope_impl.dart';   // Added
import 'package:dart_libp2p/core/network/errors.dart' as network_errors;
import 'package:logging/logging.dart'; // Added



class StreamScopeImpl extends ResourceScopeImpl implements StreamManagementScope {
  final Direction direction;
  
  final Logger _logger = Logger('StreamScopeImpl'); // Added logger
  
  // References to associated scopes. These are set via setProtocol/setService.
  ProtocolScopeImpl? _protocolScopeImpl;
  ServiceScopeImpl? _serviceScopeImpl;
  PeerScopeImpl _peerScopeImpl; // Should be set at creation or early on.

  // In Go, streamScope also holds references to peerProtoScope and peerSvcScope,
  // which are sub-scopes under protocol/service for that specific peer.
  // This adds another layer of granularity.
  ResourceScopeImpl? _peerProtoScope;
  ResourceScopeImpl? _peerSvcScope;

  final ResourceManagerImpl _rcmgr; // Added ResourceManagerImpl reference

  StreamScopeImpl(
    this._rcmgr, // Added rcmgr parameter
    Limit limit,
    String name,
    this.direction,
    this._peerScopeImpl, // PeerScope is fundamental to a stream
    {List<ResourceScopeImpl>? edges} // Initial edges: peer, transient, system
  ) : super(limit, name, edges: edges);

  @override
  ProtocolScope? get protocolScope => _protocolScopeImpl;

  @override
  ServiceScope? get serviceScope => _serviceScopeImpl;

  @override
  PeerScope get peerScope => _peerScopeImpl; // Already a PeerScopeImpl

  @override
  Future<void> setProtocol(ProtocolID protocol) async {
    if (_protocolScopeImpl != null) {
      _logger.severe('$name: stream scope already attached to a protocol: ${_protocolScopeImpl!.protocol}');
      throw Exception('$name: stream scope already attached to a protocol: ${_protocolScopeImpl!.protocol}');
    }
    _logger.fine('$name: Setting protocol to $protocol for peer ${_peerScopeImpl.peer}');

    // 1. Get necessary scopes from ResourceManager
    final newProtocolScope = _rcmgr.getProtocolScopeInternal(protocol);
    final systemScope = _rcmgr.systemScope; 
    final limiter = _rcmgr.limiter;
    
    // Explicitly cast to the concrete PeerId type
    final newPeerProtoScope = newProtocolScope.getPeerSubScope(
      _peerScopeImpl.peer as concrete_peer_id.PeerId, 
      limiter, 
      systemScope
    );

    // 2. Identify original transient scope
    // Initial edges for a stream are [peerScope, transientScope, systemScope]
    ResourceScopeImpl? transientScope;
    for (final edge in edges) {
      if (edge.name == 'transient' && edge is TransientScopeImpl) {
        transientScope = edge;
        break;
      }
    }
    if (transientScope == null) {
      _logger.fine('$name: Edges: ${edges.map((e) => e.name).join(', ')}');
      throw StateError('$name: Transient scope not found in initial edges for juggling.');
    }

    // 3. Move the stream from the transient scope under its peer-protocol
    // scope. reparent() counts it in the scopes it gains (the protocol and
    // peer-protocol scopes) and releases it from the transient scope; the
    // peer and system scopes keep counting it once.
    try {
      reparent([_peerScopeImpl, newPeerProtoScope]);
    } on network_errors.ResourceLimitExceededException catch (e) {
      _logger.fine('$name: Failed to reserve resources for protocol $protocol: $e.');
      rethrow;
    }
    _protocolScopeImpl = newProtocolScope;
    _peerProtoScope = newPeerProtoScope;
    _logger.fine('$name: Successfully set protocol to $protocol. Resources transferred, edges updated.');
  }

  @override
  Future<void> setService(String serviceName) async {
    if (_serviceScopeImpl != null) {
      throw Exception('$name: stream scope already attached to a service: ${_serviceScopeImpl!.name}');
    }
    if (_protocolScopeImpl == null || _peerProtoScope == null) {
      throw StateError('$name: stream scope not attached to a protocol before setting service');
    }
    _logger.fine('$name: Setting service to $serviceName for peer ${_peerScopeImpl.peer}, protocol ${_protocolScopeImpl!.protocol}');

    // 1. Get necessary scopes
    final newServiceScope = _rcmgr.getServiceScopeInternal(serviceName);
    final systemScope = _rcmgr.systemScope;
    final limiter = _rcmgr.limiter;

    // Explicitly cast to the concrete PeerId type
    final newPeerSvcScope = newServiceScope.getPeerSubScope(
      _peerScopeImpl.peer,
      limiter, 
      systemScope
    );

    // 2. Add the stream to the service and peer-service scopes. Nothing is
    // released: a stream counts against its service on top of its protocol.
    // reparent() counts it once in each scope it gains.
    try {
      reparent([_peerScopeImpl, _peerProtoScope!, newPeerSvcScope]);
    } on network_errors.ResourceLimitExceededException catch (e) {
      _logger.fine('$name: Failed to reserve resources for service $serviceName: $e.');
      rethrow;
    }
    _serviceScopeImpl = newServiceScope;
    _peerSvcScope = newPeerSvcScope;
    _logger.fine('$name: Successfully set service to $serviceName. Edges updated.');
  }

  // Inherits done() from ResourceScopeImpl.
}
