import 'dart:async';
import 'dart:math' as math;

import 'package:dart_libp2p/core/network/common.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/network/errors.dart' as network_errors;
import 'package:dart_libp2p/p2p/host/resource_manager/limit.dart';
// It's good practice to alias if class names might collide or for clarity.
// import 'package:dart_libp2p/log/logger.dart' as log;

// A simple logger placeholder, replace with actual logging if available
void _logWarn(String message) {
}

class _Resources {
  final Limit limit;

  /// Adds all of [st] at once, or nothing if any limit would be exceeded.
  Exception? reserveStat(ScopeStat st) {
    final memErr = checkMemory(st.memory, ReservationPriority.always);
    if (memErr != null) return memErr;
    final sIn = streamsInbound + st.numStreamsInbound;
    final sOut = streamsOutbound + st.numStreamsOutbound;
    final cIn = connsInbound + st.numConnsInbound;
    final cOut = connsOutbound + st.numConnsOutbound;
    final f = fds + st.numFD;
    if ((st.numStreamsInbound > 0 && sIn > limit.getStreamLimit(Direction.inbound)) ||
        (st.numStreamsOutbound > 0 && sOut > limit.getStreamLimit(Direction.outbound)) ||
        (st.numStreamsInbound + st.numStreamsOutbound > 0 && sIn + sOut > limit.streamTotalLimit) ||
        (st.numConnsInbound > 0 && cIn > limit.getConnLimit(Direction.inbound)) ||
        (st.numConnsOutbound > 0 && cOut > limit.getConnLimit(Direction.outbound)) ||
        (st.numConnsInbound + st.numConnsOutbound > 0 && cIn + cOut > limit.connTotalLimit) ||
        (st.numFD > 0 && f > limit.fdLimit)) {
      return network_errors.ResourceLimitExceededException();
    }
    memory += st.memory;
    streamsInbound = sIn;
    streamsOutbound = sOut;
    connsInbound = cIn;
    connsOutbound = cOut;
    fds = f;
    return null;
  }


  int connsInbound = 0;
  int connsOutbound = 0;
  int streamsInbound = 0;
  int streamsOutbound = 0;
  int fds = 0; // File descriptors, conceptual in Dart
  int memory = 0; // In bytes

  _Resources(this.limit);

  // Checks memory reservation.
  // Note: Go's priority system for memory is complex (using uint8 for priority).
  // Dart's `ResourceScope.reserveMemory` takes `ReservationPriority`.
  // We'll simplify priority handling for now or map it if necessary.
  // The current `ReservationPriority` in Dart is an enum, not a uint8.
  // For now, we assume any valid priority allows reservation up to the limit.
  Exception? checkMemory(int rsvp, int priority) {
    if (rsvp < 0) {
      return Exception("can't reserve negative memory. rsvp=$rsvp");
    }

    final currentLimit = limit.memoryLimit;
    if (currentLimit == BaseLimit.unlimited().memoryLimit) {
      return null; // Effectively unlimited
    }

    // Simplified priority: if priority is high, maybe allow exceeding soft limits?
    // For now, all priorities are treated the same against the hard limit.
    // This part needs to align with how ReservationPriority is intended to be used.
    // Go's logic: newmem > (limit * (1 + prio)) / 256
    // Let's assume priority is handled by allowing reservation if newMem <= currentLimit.
    // A more sophisticated model might be needed if Dart's ReservationPriority implies tiered limits.

    if (memory + rsvp > currentLimit) {
      // This constructor takes no arguments. The message is fixed.
      return network_errors.ResourceLimitExceededException();
    }
    return null;
  }

  Exception? reserveMemory(int size, int priority) {
    final err = checkMemory(size, priority);
    if (err != null) {
      return err;
    }
    memory += size;
    return null;
  }

  void releaseMemory(int size) {
    memory -= size;
    if (memory < 0) {
      _logWarn('BUG: too much memory released (size: $size, memory before: ${memory + size}, after attempted subtract: $memory)');
      memory = 0;
    }
  }

  Exception? addStream(Direction dir, String ownerId) {

    final currentLimit = limit.getStreamLimit(dir);
    final totalLimit = limit.streamTotalLimit;

    if (dir == Direction.inbound) {
      if (streamsInbound + 1 > currentLimit) {
        return network_errors.ResourceLimitExceededException();
      }
    } else {
      if (streamsOutbound + 1 > currentLimit) {
        return network_errors.ResourceLimitExceededException();
      }
    }

    if (streamsInbound + streamsOutbound + 1 > totalLimit) {
      return network_errors.ResourceLimitExceededException();
    }

    if (dir == Direction.inbound) {
      streamsInbound++;
    } else {
      streamsOutbound++;
    }
    return null;
  }

  void removeStream(Direction dir, String ownerId) {
    if (dir == Direction.inbound) {
      streamsInbound--;
      if (streamsInbound < 0) {
        _logWarn('BUG: too many inbound streams released for $ownerId');
        streamsInbound = 0;
      }
    } else {
      streamsOutbound--;
      if (streamsOutbound < 0) {
        _logWarn('BUG: too many outbound streams released for $ownerId');
        streamsOutbound = 0;
      }
    }
  }

  Exception? addConn(Direction dir, bool usefd) {
    final fdIncrement = usefd ? 1 : 0;
    final currentConnLimit = limit.getConnLimit(dir);
    final totalConnLimit = limit.connTotalLimit;
    final fdLimit = limit.fdLimit;

    if (dir == Direction.inbound) {
      if (connsInbound + 1 > currentConnLimit) {
        return network_errors.ResourceLimitExceededException();
      }
    } else {
      if (connsOutbound + 1 > currentConnLimit) {
        return network_errors.ResourceLimitExceededException();
      }
    }

    if (connsInbound + connsOutbound + 1 > totalConnLimit) {
      return network_errors.ResourceLimitExceededException();
    }

    if (usefd && (fds + 1 > fdLimit)) {
      return network_errors.ResourceLimitExceededException();
    }

    if (dir == Direction.inbound) {
      connsInbound++;
    } else {
      connsOutbound++;
    }
    if (usefd) {
      fds++;
    }
    return null;
  }

  void removeConn(Direction dir, bool usefd) {
    if (dir == Direction.inbound) {
      connsInbound--;
      if (connsInbound < 0) {
        _logWarn('BUG: too many inbound connections released');
        connsInbound = 0;
      }
    } else {
      connsOutbound--;
      if (connsOutbound < 0) {
        _logWarn('BUG: too many outbound connections released');
        connsOutbound = 0;
      }
    }
    if (usefd) {
      fds--;
      if (fds < 0) {
        _logWarn('BUG: too many FDs released');
        fds = 0;
      }
    }
  }

  ScopeStat stat() {
    return ScopeStat(
      memory: memory,
      numStreamsInbound: streamsInbound,
      numStreamsOutbound: streamsOutbound,
      numConnsInbound: connsInbound,
      numConnsOutbound: connsOutbound,
      numFD: fds,
    );
  }
}

class ResourceScopeImpl implements ResourceScope, ResourceScopeSpan {
  bool _isDone = false;
  int _refCnt = 0;
  int _spanIdCounter = 0; // For generating unique span IDs within this scope

  final _Resources _resources;
  ResourceScopeImpl? _owner; // For span scopes
  List<ResourceScopeImpl> edges = []; // Made public for subclass access

  final String name;
  // TODO: Add trace and metrics objects later

  ResourceScopeImpl(Limit limit, this.name,
      {ResourceScopeImpl? owner, List<ResourceScopeImpl>? edges}) // Changed back to edges
      : _resources = _Resources(limit),
        _owner = owner,
        this.edges = edges ?? [] {
    // if (limit is BaseLimit) {
    // } else {
    // }
    if (_owner == null) {
      // This is a DAG scope, increment ref count of its parents
      for (var edge in this.edges) { // Use public field via 'this' for clarity
        edge.incRef();
      }
    }
    // If it's a span, owner's ref count is handled by beginSpan
    // log.debug('Scope created: $name, Owner: ${_owner?.name}, Edges: ${_edges.map((e) => e.name)}');
  }

  // Factory for creating a span
  ResourceScopeImpl._asSpan(Limit limit, this.name, this._owner, int spanId)
      : _resources = _Resources(limit) {
    // log.debug('Span scope created: $name, Owner: ${_owner?.name}');
  }

  String _wrapErrorMsg(String msg) => '$name: $msg';

  Exception _wrapError(Exception err) {
    // Prepend scope name to the standard message if possible.
    // Preserve original typed exceptions for better error handling.
    if (err is network_errors.ResourceLimitExceededException) {
      // Optionally, if we want to add context while preserving type:
      // return network_errors.ResourceLimitExceededException(_wrapErrorMsg('resource limit exceeded'));
      // For now, just return the original error to ensure type matching in tests.
      return err; 
    }
    if (err is network_errors.ResourceScopeClosedException) {
      // Similarly, preserve type or re-wrap with same type.
      return err;
    }
    // For other generic exceptions, wrap with context.
    return Exception(_wrapErrorMsg(err.toString()));
  }

  /// The scopes directly above this one: the owner of a span, or the edges.
  List<ResourceScopeImpl> get _parents => _owner != null ? [_owner!] : edges;

  /// Every scope above this one, each once. A resource counted here is also
  /// counted once in each of them, as go-libp2p counts it in each of a
  /// scope's constraints. (Walking the edges recursively instead counted a
  /// stream in the system scope once per path: through the peer, the
  /// transient and the protocol scope.)
  List<ResourceScopeImpl> get _ancestors => _closure(_parents);

  static List<ResourceScopeImpl> _closure(List<ResourceScopeImpl> start) {
    final result = <ResourceScopeImpl>[];
    final seen = <ResourceScopeImpl>{};
    void visit(List<ResourceScopeImpl> scopes) {
      for (final scope in scopes) {
        if (seen.add(scope)) {
          result.add(scope);
          visit(scope._parents);
        }
      }
    }
    visit(start);
    return result;
  }

  /// Moves this scope under [newEdges]. Its current resources are counted in
  /// the ancestors it gains and released from the ones it loses; an ancestor
  /// it keeps (the system scope, usually) keeps counting them once. This is
  /// how go-libp2p's SetPeer and SetProtocol juggle resources. Throws, and
  /// changes nothing, if a gained ancestor's limit would be exceeded.
  void reparent(List<ResourceScopeImpl> newEdges) {
    // A scope that is done holds nothing and refers to nothing; moving it
    // would only take references that are never dropped. (A stream whose
    // remote peer reset it is done before the protocol is set.)
    if (_isDone) return;
    if (_owner != null) {
      throw StateError('$name: a span cannot be reparented');
    }
    final oldAncestors = _ancestors.toSet();
    final newAncestors = _closure(newEdges);
    final gained = newAncestors.where((a) => !oldAncestors.contains(a)).toList();
    final lost = oldAncestors.where((a) => !newAncestors.contains(a)).toList();
    final st = stat;

    final reserved = <ResourceScopeImpl>[];
    for (final scope in gained) {
      final err = scope._isDone ? network_errors.ResourceScopeClosedException() : scope._resources.reserveStat(st);
      if (err != null) {
        for (final r in reserved) {
          r._releaseResourcesForChild(st);
        }
        throw _wrapError(err);
      }
      reserved.add(scope);
    }
    for (final scope in lost) {
      scope._releaseResourcesForChild(st);
    }

    for (final e in edges) {
      if (!newEdges.contains(e)) e.decRef();
    }
    for (final e in newEdges) {
      if (!edges.contains(e)) e.incRef();
    }
    edges = List.of(newEdges);
  }

  @override
  Future<void> reserveMemory(int size, int priority) async {
    if (_isDone) {
      throw _wrapError(network_errors.ResourceScopeClosedException());
    }
    var err = _resources.reserveMemory(size, priority);
    if (err != null) {
      // TODO: metrics.BlockMemory(size);
      throw _wrapError(err);
    }

    try {
      await _reserveMemoryForAncestors(size, priority);
    } catch (e) {
      _resources.releaseMemory(size); // Rollback local reservation
      final memoryAfterRollback = _resources.memory; // Explicitly read after rollback
      // Specific check for the failing test conditions - removing this as well
      // if (name == 'childScope' && size == 70 && memoryAfterRollback != 0) {
      // }
      // TODO: metrics.BlockMemory(size);
      throw _wrapError(e as Exception);
    }
    // TODO: trace.ReserveMemory(name, priority, size, _resources.memory);
    // TODO: metrics.AllowMemory(size);
  }

  Future<void> _reserveMemoryForAncestors(int size, int priority) async {
    final reserved = <ResourceScopeImpl>[];
    for (final scope in _ancestors) {
      final err = scope._reserveMemoryForChild(size, priority);
      if (err != null) {
        for (final r in reserved) {
          r._releaseMemoryForChild(size);
        }
        throw scope._wrapError(err);
      }
      reserved.add(scope);
    }
  }

  @override
  void releaseMemory(int size) {
    if (_isDone) {
      return;
    }
    _resources.releaseMemory(size);
    _releaseMemoryForAncestors(size);
    // TODO: trace.ReleaseMemory(name, size, _resources.memory);
  }

  void _releaseMemoryForAncestors(int size) {
    for (final scope in _ancestors) {
      scope._releaseMemoryForChild(size);
    }
  }

  // Internal methods for child scopes to reserve/release directly on this scope
  // These would be synchronous if called internally.
  Exception? _reserveMemoryForChild(int size, int priority) {
    if (_isDone) return network_errors.ResourceScopeClosedException();
    // _resources.reserveMemory already returns Exception?
    return _resources.reserveMemory(size, priority);
  }

  void _releaseMemoryForChild(int size) {
    if (_isDone) return;
    _resources.releaseMemory(size);
  }


  @override
  ScopeStat get stat => _resources.stat();

  @override
  Future<ResourceScopeSpan> beginSpan() async {
    if (_isDone) {
      throw _wrapError(network_errors.ResourceScopeClosedException());
    }
    _refCnt++; // Owner's ref count increases because a span is now active
    _spanIdCounter++;
    final spanName = '$name.span-$_spanIdCounter';
    // Span inherits its limit from the owner.
    return ResourceScopeImpl._asSpan(_resources.limit, spanName, this, _spanIdCounter);
  }

  @override
  void done() {
    if (_isDone) {
      _logWarn('BUG: done() called on already done scope $name');
      return;
    }

    final currentStat = stat;
    // Release this scope's resources from every ancestor, each once, then
    // drop the references held on the direct parents (the owner of a span,
    // or the edges).
    for (final scope in _ancestors) {
      scope._releaseResourcesForChild(currentStat);
    }
    for (final parent in _parents) {
      parent.decRef();
    }

    // Clear local resources
    _resources.memory = 0;
    _resources.streamsInbound = 0;
    _resources.streamsOutbound = 0;
    _resources.connsInbound = 0;
    _resources.connsOutbound = 0;
    _resources.fds = 0;

    _isDone = true;
    // TODO: trace.DestroyScope(name);
    // log.debug('Scope done: $name');
  }

  // Called by a child (or span) when it's done to release its resources from this scope
  void _releaseResourcesForChild(ScopeStat childStat) {
    if (_isDone) return;
    _resources.releaseMemory(childStat.memory);
    
    // Only this scope: the caller releases from every ancestor itself.
    for (int i = 0; i < childStat.numStreamsInbound; i++) {
      _resources.removeStream(Direction.inbound, name);
    }
    for (int i = 0; i < childStat.numStreamsOutbound; i++) {
      _resources.removeStream(Direction.outbound, name);
    }
    // Assuming childStat.numFD is the number of connections that used FDs
    // And that conns are released one by one with their direction and fd usage.
    // This is a simplification. Go's model is more granular.
    // For now, just reduce counts.
    _resources.connsInbound -= childStat.numConnsInbound;
    if(_resources.connsInbound < 0) _resources.connsInbound = 0;
    _resources.connsOutbound -= childStat.numConnsOutbound;
    if(_resources.connsOutbound < 0) _resources.connsOutbound = 0;
    _resources.fds -= childStat.numFD;
    if(_resources.fds < 0) _resources.fds = 0;

    // TODO: More detailed trace calls for released resources
  }


  void incRef() {
    _refCnt++;
  }

  void decRef() {
    _refCnt--;
    if (_refCnt < 0) {
      _logWarn('BUG: refCnt for scope $name went negative');
      _refCnt = 0;
    }
  }

  /// Whether nothing uses this scope: it holds no resource and no scope or
  /// span refers to it. [ownRefs] references are not counted; the resource
  /// manager holds one on each peer scope it keeps.
  bool isUnused({int ownRefs = 0}) {
    if (_isDone) {
      return true;
    }
    if (_refCnt > ownRefs) {
      return false;
    }
    final s = stat;
    return s.numStreamsInbound == 0 &&
        s.numStreamsOutbound == 0 &&
        s.numConnsInbound == 0 &&
        s.numConnsOutbound == 0 &&
        s.numFD == 0 &&
        s.memory == 0;
  }

  // The following methods (addStream, removeStream, addConn, removeConn) are not
  // part of the public ResourceScope interface but are used by specific scope types
  // (like ConnScope, StreamScope) which will embed/extend ResourceScopeImpl.
  // They mirror Go's internal resourceScope methods.

  void addStream(Direction dir) {
    if (_isDone) {
      throw _wrapError(network_errors.ResourceScopeClosedException());
    }
    
    final err = _resources.addStream(dir, name); // Pass owner id (name)
    if (err != null) {
      throw _wrapError(err); // Wrap it for context
    }

    try {
      _addStreamForAncestors(dir);
    } catch (e) {
      _resources.removeStream(dir, name); // Rollback, Pass owner id (name)
      if (e is network_errors.ResourceLimitExceededException ||
          e is network_errors.ResourceScopeClosedException) {
        rethrow; 
      } else if (e is Exception) {
        throw _wrapError(e); 
      } else {
        rethrow; 
      }
    }
  }

  void _addStreamForAncestors(Direction dir) {
    final added = <ResourceScopeImpl>[];
    for (final scope in _ancestors) {
      final err = scope._addStreamForChild(dir);
      if (err != null) {
        for (final a in added) {
          a._removeStreamForChild(dir);
        }
        throw scope._wrapError(err);
      }
      added.add(scope);
    }
  }
  
  Exception? _addStreamForChild(Direction dir) {
    // This method is for a parent to update its own resources when directly told so by a child.
    // It does NOT trigger further propagation up from this parent.
    // That's the responsibility of the child calling the parent's public addStream method.
    if (_isDone) return network_errors.ResourceScopeClosedException();
    return _resources.addStream(dir, name); 
  }

  void removeStream(Direction dir) {
    if (_isDone) return;
    _resources.removeStream(dir, name); 
    _removeStreamForAncestors(dir);
  }

  void _removeStreamForAncestors(Direction dir) {
    for (final scope in _ancestors) {
      scope._removeStreamForChild(dir);
    }
  }

  void _removeStreamForChild(Direction dir) {
    // This method is for a parent to update its own resources when directly told so by a child.
    // It does NOT trigger further propagation up from this parent.
    // final currentStat = _resources.stat();
    if (_isDone) {
      return;
    }
    _resources.removeStream(dir, name);
  }

  // Connections
  void addConn(Direction dir, bool usefd) {
    if (_isDone) {
      throw _wrapError(network_errors.ResourceScopeClosedException());
    }

    final err = _resources.addConn(dir, usefd);
    if (err != null) {
      throw _wrapError(err);
    }
    
    try {
      _addConnForAncestors(dir, usefd);
    } catch (e) {
      _resources.removeConn(dir, usefd); // Rollback
      if (e is network_errors.ResourceLimitExceededException ||
          e is network_errors.ResourceScopeClosedException) {
        rethrow;
      } else if (e is Exception) {
        throw _wrapError(e);
      } else {
        rethrow;
      }
    }
  }

  void _addConnForAncestors(Direction dir, bool usefd) {
    final added = <ResourceScopeImpl>[];
    for (final scope in _ancestors) {
      final err = scope._addConnForChild(dir, usefd);
      if (err != null) {
        for (final a in added) {
          a._removeConnForChild(dir, usefd);
        }
        throw scope._wrapError(err);
      }
      added.add(scope);
    }
  }

  Exception? _addConnForChild(Direction dir, bool usefd) {
    if (_isDone) return network_errors.ResourceScopeClosedException();
    return _resources.addConn(dir, usefd);
  }

  void removeConn(Direction dir, bool usefd) {
    if (_isDone) return;
    _resources.removeConn(dir, usefd);
    _removeConnForAncestors(dir, usefd);
  }

  void _removeConnForAncestors(Direction dir, bool usefd) {
    for (final scope in _ancestors) {
      scope._removeConnForChild(dir, usefd);
    }
  }
  
  void _removeConnForChild(Direction dir, bool usefd) {
    if (_isDone) return;
    _resources.removeConn(dir, usefd);
  }
}
