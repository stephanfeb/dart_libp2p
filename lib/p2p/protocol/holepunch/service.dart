/// Implementation of the holepunch service.

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/holepunch_service.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/holepuncher.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/pb/holepunch.pb.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/util.dart';
import 'package:dart_libp2p/p2p/protocol/identify/id_service.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';

import '../../../core/network/context.dart';
import '../../../core/network/rcmgr.dart';
import '../../../core/network/stream.dart'; // For P2PStream
import '../../../core/network/common.dart' show Direction; // Import Direction
import '../../../core/peer/addr_info.dart';
import '../../discovery/peer_info.dart';

/// Logger for the holepunch service
final _log = Logger('p2p-holepunch');

/// Options for the holepunch service
class HolePunchOptions {
  /// Tracer for the holepunch service
  final HolePunchTracer? tracer;

  /// Address filter for the holepunch service
  final AddrFilter? filter;

  /// Creates new holepunch options
  const HolePunchOptions({
    this.tracer,
    this.filter,
  });
}


/// Result of an incoming hole punch
class IncomingHolePunchResult {
  final int rtt;
  final List<MultiAddr> remoteAddrs;
  final List<MultiAddr> ownAddrs;

  IncomingHolePunchResult(this.rtt, this.remoteAddrs, this.ownAddrs);
}

/// Implementation of the holepunch service
class HolePunchServiceImpl implements HolePunchService {
  /// The context for the service
  final _ctx = Completer<void>();
  final _ctxCancel = Completer<void>();

  /// The host this service is running on
  final Host _host;

  /// The identify service
  final IDService _ids;

  /// Function to get listen addresses
  final List<MultiAddr> Function() _listenAddrs;

  /// Holepuncher
  HolePuncher? _holePuncher;
  final _holePuncherMutex = Lock();

  /// Channel for when we have public addresses
  final _hasPublicAddrsChan = Completer<void>();

  /// Tracer for the service
  final HolePunchTracer? _tracer;

  /// Address filter
  final AddrFilter? _filter;

  /// Reference count for async operations
  final _refCount = Completer<void>();
  var _refCountValue = 0;
  final _refCountMutex = Lock();

  /// Creates a new holepunch service
  ///
  /// listenAddrs MUST only return public addresses.
  HolePunchServiceImpl(this._host, this._ids, this._listenAddrs, {
    HolePunchOptions? options,
  }) : 
    _tracer = options?.tracer,
    _filter = options?.filter {

    _incrementRefCount();
    _waitForPublicAddr();
  }

  /// Increments the reference count
  Future<void> _incrementRefCount() async {
    await _refCountMutex.synchronized(() {
      _refCountValue++;
    });
  }

  /// Decrements the reference count
  Future<void> _decrementRefCount() async {
    await _refCountMutex.synchronized(() {
      _refCountValue--;
      if (_refCountValue == 0) {
        _refCount.complete();
      }
    });
  }

  /// Waits for the host to have at least one public address
  Future<void> _waitForPublicAddr() async {
    _log.fine('Waiting until we have at least one public address', _host.id);

    // TODO: We should have an event here that fires when identify discovers a new
    // address.
    // As we currently don't have an event like this, just check our observed addresses
    // regularly (exponential backoff starting at 250 ms, capped at 5s).
    var duration = const Duration(milliseconds: 250);
    const maxDuration = Duration(seconds: 5);

    while (true) {
      // Check for cancellation BEFORE calling _listenAddrs() in a new iteration
      if (_ctxCancel.isCompleted) {
        _log.fine('HolePunchService._waitForPublicAddr: Context cancelled at loop start, exiting.');
        await _decrementRefCount(); // Ensure ref count is decremented on this path
        return;
      }

      if (_listenAddrs().isNotEmpty) {
        _log.fine('Host now has a public address. Starting holepunch protocol.');
        _host.setStreamHandler(protocolId, _handleNewStream);
        break;
      }

      try {
        await Future.any([
          Future.delayed(duration),
          _ctxCancel.future,
        ]);
      } catch (_) {
        // Context cancelled (e.g., if _ctxCancel.future completed with an error)
        _log.fine('HolePunchService._waitForPublicAddr: Context cancelled via Future.any catch, exiting.');
        await _decrementRefCount();
        return;
      }

      // Explicit check for cancellation after Future.any completes normally
      if (_ctxCancel.isCompleted) {
        _log.fine('HolePunchService._waitForPublicAddr: Context cancelled after delay/event, exiting loop.');
        await _decrementRefCount(); // Ensure ref count is decremented on this path
        return;
      }

      duration *= 2;
      if (duration > maxDuration) {
        duration = maxDuration;
      }
    }

    await _holePuncherMutex.synchronized(() {
      if (_ctxCancel.isCompleted) {
        // Service is closed
        return;
      }
      _holePuncher = HolePuncher(_host, _ids, _listenAddrs, tracer: _tracer, filter: _filter);
    });

    _hasPublicAddrsChan.complete();
    await _decrementRefCount();
  }

  @override
  Future<void> start() async {
    // Nothing to do here, initialization is done in the constructor
  }

  @override
  Future<void> close() async {
    _ctxCancel.complete();

    await _holePuncherMutex.synchronized(() {
      if (_holePuncher != null) {
        return _holePuncher!.close();
      }
    });

    _tracer?.close();
    _host.removeStreamHandler(protocolId);

    await _refCount.future;
    _ctx.complete();
    return _ctx.future;
  }


  /// Handles an incoming hole punch
  Future<IncomingHolePunchResult> _incomingHolePunch(P2PStream str) async {
    // Sanity check: a hole punch request should only come from peers behind a relay
    if (!isRelayAddress(str.conn.remoteMultiaddr)) {
      throw Exception('Received hole punch stream: ${str.conn.remoteMultiaddr}');
    }

    var ownAddrs = _listenAddrs();
    if (_filter != null) {
      ownAddrs = _filter!.filterLocal(str.conn.remotePeer, ownAddrs);
    }

    // If we can't tell the peer where to dial us, there's no point in starting the hole punching.
    if (ownAddrs.isEmpty) {
      throw Exception('Rejecting hole punch request, as we don\'t have any public addresses');
    }

    await str.scope().reserveMemory(maxMsgSize, ReservationPriority.always);
    try {
      str.setDeadline(DateTime.now().add(streamTimeout));

      // Read Connect message
      final msgBytes = await str.read();
      final msg = HolePunch.fromBuffer(msgBytes);
      if (msg.type != HolePunch_Type.CONNECT) {
        throw Exception('Expected CONNECT message from initiator but got ${msg.type}');
      }

      var obsDial = removeRelayAddrs(addrsFromBytes(msg.obsAddrs));
      if (_filter != null) {
        obsDial = _filter!.filterRemote(str.conn.remotePeer, obsDial);
      }

      _log.fine('Received hole punch request from ${str.conn.remotePeer} with addresses: $obsDial');
      if (obsDial.isEmpty) {
        throw Exception('Expected CONNECT message to contain at least one address');
      }

      // Write CONNECT message
      final response = HolePunch()
        ..type = HolePunch_Type.CONNECT
        ..obsAddrs.addAll(addrsToBytes(ownAddrs));

      final tstart = DateTime.now();
      final responseBytes = response.writeToBuffer();
      await str.write(Uint8List.fromList(responseBytes));

      // Read SYNC message
      final syncMsgBytes = await str.read();
      final syncMsg = HolePunch.fromBuffer(syncMsgBytes);
      if (syncMsg.type != HolePunch_Type.SYNC) {
        throw Exception('Expected SYNC message from initiator but got ${syncMsg.type}');
      }

      return IncomingHolePunchResult(
        DateTime.now().difference(tstart).inMilliseconds,
        obsDial,
        ownAddrs,
      );
    } finally {
      str.scope().releaseMemory(maxMsgSize);
    }
  }

  /// Handles a new stream
  Future<void> _handleNewStream(P2PStream str, PeerId peerId) async {
    // Check directionality of the underlying connection.
    // Peer A receives an inbound connection from peer B.
    // Peer A opens a new hole punch stream to peer B.
    // Peer B receives this stream, calling this function.
    // Peer B sees the underlying connection as an outbound connection.

    if (str.conn.stat.stats.direction == Direction.inbound) {
      await str.reset();
      return;
    }

    try {
      await str.scope().setService(serviceName);
    } catch (err) {
      _log.fine('Error attaching stream to holepunch service: $err');
      await str.reset();
      return;
    }

    final rp = str.conn.remotePeer;
    IncomingHolePunchResult? result;
    try {
      result = await _incomingHolePunch(str);
      await str.close();
    } catch (err) {
      _tracer?.protocolError(rp, err);
      _log.fine('Error handling holepunching stream from ${rp}: $err');
      await str.reset();
      return;
    }

    // Hole punch now by forcing a connect
    final pi = PeerInfo(peerId: rp, addrs: result.remoteAddrs.toSet());
    _tracer?.startHolePunch(rp, result.remoteAddrs, result.rtt);
    _log.fine('Starting hole punch', rp);

    final start = DateTime.now();
    _tracer?.holePunchAttempt(pi.peerId);

    try {
      await _holePunchConnect(pi, false);
      final dt = DateTime.now().difference(start);
      _tracer?.endHolePunch(rp, dt, null);
      _tracer?.holePunchFinished('receiver', 1, result.remoteAddrs, result.ownAddrs, getDirectConnection(_host, rp));
    } catch (err) {
      final dt = DateTime.now().difference(start);
      _tracer?.endHolePunch(rp, dt, err);
    }
  }


  /// Performs a hole punch connection
  Future<void> _holePunchConnect(PeerInfo pi, bool isClient) async {
    final holePunchCtx = Context()
        .withValue('simultaneousConnect', true)
        .withValue('simultaneousConnectIsClient', isClient)
        .withValue('simultaneousConnectReason', 'hole-punching');

    final forceDirectConnCtx = Context()
        .withValue('forceDirectDial', true)
        .withValue('forceDirectDialReason', 'hole-punching');

    try {
      final addrInfo = AddrInfo(pi.peerId, pi.addrs.toList());
      await _host.connect(
        addrInfo,
        context: holePunchCtx.withValue('forceDirectDial', true)
            .withValue('forceDirectDialReason', 'hole-punching'),
      );
      _log.fine('Hole punch successful for peer ${pi.peerId}');
    } catch (err) {
      _log.fine('Hole punch attempt with peer ${pi.peerId} failed: $err');
      rethrow;
    }
  }

  @override
  Future<void> directConnect(PeerId peerId) async {
    await _hasPublicAddrsChan.future;

    final holePuncher = await _holePuncherMutex.synchronized(() => _holePuncher);
    if (holePuncher == null) {
      throw Exception('Holepunch service not initialized');
    }

    return holePuncher.directConnect(peerId);
  }
}

/// Extension for the HolePunchTracer
extension HolePunchTracerExt on HolePunchTracer {
  /// Closes the tracer
  void close() {}
}
