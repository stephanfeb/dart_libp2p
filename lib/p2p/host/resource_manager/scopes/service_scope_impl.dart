import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart'; // Added for concrete PeerId
import 'package:dart_libp2p/p2p/host/resource_manager/limit.dart';
import 'package:dart_libp2p/p2p/host/resource_manager/limiter.dart'; // Added for Limiter
import 'package:dart_libp2p/p2p/host/resource_manager/scope_impl.dart';

/// ServiceScopeImpl is the concrete implementation for service-specific scopes.
class ServiceScopeImpl extends ResourceScopeImpl implements ServiceScope {
  @override
  final String name; // This is the service name.

  final Map<PeerId, ResourceScopeImpl> _peerSubScopes = {};

  // In Go, serviceScope also holds a map of peer sub-scopes: `peers map[peer.ID]*resourceScope`
  // And a reference to the resourceManager to get limits for those peer sub-scopes.
  // We might need to add similar functionality here if services have per-peer limits within them.

  ServiceScopeImpl(Limit limit, this.name, {List<ResourceScopeImpl>? edges})
      : super(limit, 'service:$name', edges: edges); // Scope name is prefixed

  // The `name` getter is fulfilled by the final field.

  ResourceScopeImpl getPeerSubScope(PeerId peerId, Limiter limiter, ResourceScopeImpl systemScope) {
    return _peerSubScopes.putIfAbsent(peerId, () {
      final peerServiceLimit = limiter.getServicePeerLimits(this.name, peerId);
      final scopeName = 'service:${this.name}-peer:${peerId.toString()}';
      
      final newPeerSubScope = ResourceScopeImpl(
        peerServiceLimit,
        scopeName,
        edges: [this, systemScope], // Parent is this service scope and system scope
      );
      newPeerSubScope.incRef(); // This sub-scope is now in use
      return newPeerSubScope;
    });
  }

  /// Drops the per-peer sub-scopes that nothing uses. Called by the resource
  /// manager's garbage collector; without it this map would keep an entry
  /// for every peer that ever used this service.
  void gcPeerSubScopes() {
    _peerSubScopes.removeWhere((_, scope) {
      if (scope.isUnused(ownRefs: 1)) {
        scope.done();
        return true;
      }
      return false;
    });
  }

  /// The number of per-peer sub-scopes.
  int get peerSubScopeCount => _peerSubScopes.length;
}
