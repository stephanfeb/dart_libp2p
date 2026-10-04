import 'dart:async';

import 'package:dart_libp2p/core/network/common.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart'; // For concrete PeerId
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/limit.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/resource_manager_impl.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/scope_impl.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/scopes/peer_scope_impl.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/scopes/transient_scope_impl.dart'; // Added import

// Debug logging removed to reduce console noise

class ConnectionScopeImpl extends ResourceScopeImpl implements ConnManagementScope {
  final Direction direction;
  final bool useFd;
  final MultiAddr remoteEndpoint;
  final ResourceManagerImpl _rcmgr; // Added ResourceManagerImpl reference

  PeerScopeImpl? _peerScopeImpl; // Concrete type for internal use

  // TODO: Add isAllowlisted field and logic if allowlisting is implemented.

  ConnectionScopeImpl(
    this._rcmgr, // Added rcmgr parameter
    Limit limit,
    String name,
    this.direction,
    this.useFd,
    this.remoteEndpoint, {
    List<ResourceScopeImpl>? edges, // Typically transient and system scopes
  }) : super(limit, name, edges: edges);

  @override
  PeerScope? get peerScope => _peerScopeImpl;

  @override
  Future<void> setPeer(PeerId peerId) async {
    if (_peerScopeImpl != null) {
      throw Exception('$name: connection scope already attached to a peer: ${_peerScopeImpl!.name}');
    }



    // 1. Get PeerScope from the ResourceManager.
    // Note: _rcmgr._getPeerScope is not public, but ConnectionScopeImpl is in the same library.
    // A cleaner way might be for ResourceManagerImpl to expose a method like `internalGetPeerScope`.
    // For now, direct access is assumed as they are tightly coupled.
    final newPeerScope = _rcmgr.getPeerScopeInternal(peerId); 

    // 2. Identify original transient scope and get the global system scope.
    // ConnectionScopeImpl is initially parented only by the transient scope.
    if (edges.isEmpty || edges[0] is! TransientScopeImpl) {

        throw StateError('$name: Expected initial parent to be TransientScopeImpl.');
    }
    // Get the system scope from the resource manager.
    // This assumes _rcmgr.systemScope provides the correct SystemScopeImpl instance.
    final systemScope = _rcmgr.systemScope;


    // 3. Move the connection from the transient scope to the peer scope.
    // reparent() counts it in the peer scope and releases it from the
    // transient scope; the system scope, an ancestor before and after,
    // keeps counting it once. On a limit error nothing changes and the
    // caller (the network layer) closes the connection.
    reparent([newPeerScope, systemScope]);
    _peerScopeImpl = newPeerScope;
  }

  // ConnManagementScope also implements ResourceScopeSpan, so done() is inherited from ResourceScopeImpl.
  // No need to override `done()` unless connection-specific cleanup is needed beyond base scope.
}
