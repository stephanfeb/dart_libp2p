import 'dart:async';
import 'dart:math';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/network.dart' show Connectedness, EvtPeerConnectednessChanged, ConnectionManager;
import 'package:dart_libp2p/core/network/conn.dart' show Conn; // Direct import for Conn
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/transport/upgrader.dart' show Upgrader; // Import Upgrader

// Circuit V2 client imports
import 'package:dart_libp2p/p2p/protocol/circuitv2/client/client.dart' show CircuitV2Client; // Changed Client to CircuitV2Client
import 'package:dart_libp2p/p2p/protocol/circuitv2/client/reservation.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/proto.dart' show CircuitV2Protocol;


import 'package:synchronized/synchronized.dart';
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart'; // For Protocols class
import 'package:dart_libp2p/p2p/protocol/holepunch/util.dart' show isRelayAddress; // For isRelayAddress

import './autorelay_config.dart';
import './autorelay_metrics.dart';
import './autorelay_address_utils.dart' as address_utils;

const rsvpRefreshInterval = Duration(minutes: 1);
const rsvpExpirationSlack = Duration(minutes: 2); 
const autorelayTag = 'autorelay';

class Candidate {
  final DateTime added;
  final bool supportsRelayV2;
  final AddrInfo addrInfo;

  Candidate({
    required this.added,
    required this.supportsRelayV2,
    required this.addrInfo,
  });
}

class RelayFinder {
  final Host host;
  final Upgrader upgrader;
  final AutoRelayConfig config;
  final WrappedMetricsTracer metricsTracer;
  final PeerSource _peerSource;

  final DateTime _bootTime;

  StreamController<void>? _stopController;
  Completer<void>? _backgroundCompleter;

  final Lock _candidateMx = Lock();
  final Map<PeerId, Candidate> _candidates = {};
  final Map<PeerId, DateTime> _backoff = {};

  final Lock _relayMx = Lock();
  final Map<PeerId, Reservation> _relays = {};

  List<MultiAddr> _cachedAddrs = [];
  DateTime _cachedAddrsExpiry = DateTime.now();

  final StreamController<void> _candidateFoundController = StreamController.broadcast();
  final StreamController<void> _maybeConnectToRelayTriggerController = StreamController.broadcast();
  final StreamController<void> _maybeRequestNewCandidatesController = StreamController.broadcast();
  final StreamController<void> _relayUpdatedController = StreamController.broadcast();
  final StreamController<void> _triggerRunScheduledWorkController = StreamController.broadcast();

  Stream<void> get onRelaysUpdated => _relayUpdatedController.stream;
  
  Timer? _workTimer;
  ScheduledWorkTimes _scheduledWorkTimes;

  bool _isRunning = false;

  RelayFinder(this.host, this.upgrader, this.config)
      : _peerSource = config.effectivePeerSource,
        metricsTracer = WrappedMetricsTracer(config.metricsTracer),
        _bootTime = config.clock.now(),
        _scheduledWorkTimes = ScheduledWorkTimes.initial() {
     _scheduledWorkTimes = ScheduledWorkTimes(
        nextAllowedCallToPeerSource: config.clock.now().subtract(const Duration(seconds: 1)),
        nextRefresh: config.clock.now().add(rsvpRefreshInterval),
        nextBackoff: config.clock.now().add(config.backoff),
        nextOldCandidateCheck: config.clock.now().add(config.maxCandidateAge),
    );
  }

  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    _stopController = StreamController<void>();
    _backgroundCompleter = Completer<void>();
    _initMetrics();
    _background(_stopController!.stream);
    _backgroundCompleter!.future.whenComplete(() {
        _isRunning = false;
    });
  }

  Future<void> stop() async {
    if (!_isRunning || _stopController == null || _stopController!.isClosed) return;
    _stopController!.add(null);
    await _backgroundCompleter?.future;
    _stopController!.close();
    _workTimer?.cancel();
    
    _candidateFoundController.close();
    _maybeConnectToRelayTriggerController.close();
    _maybeRequestNewCandidatesController.close();
    _relayUpdatedController.close();
    _triggerRunScheduledWorkController.close();

    _resetMetrics();
    _isRunning = false;
  }

  void _initMetrics() {
    metricsTracer.desiredReservations(config.desiredRelays);
    _relayMx.synchronized(() {
      metricsTracer.reservationOpened(_relays.length);
    });
    _candidateMx.synchronized(() {
      metricsTracer.candidateAdded(_candidates.length);
    });
  }

  void _resetMetrics() {
     _relayMx.synchronized(() {
      metricsTracer.reservationEnded(_relays.length);
    });
    _candidateMx.synchronized(() {
      metricsTracer.candidateRemoved(_candidates.length);
    });
    metricsTracer.relayAddressCount(0);
    metricsTracer.scheduledWorkUpdated(ScheduledWorkTimes.initial());
  }

  void _background(Stream<void> stopSignal) async {
    final peerSourceRateLimiter = StreamController<void>();
    peerSourceRateLimiter.add(null); 

    _findNodes(stopSignal, peerSourceRateLimiter.stream);
    _handleNewCandidates(stopSignal);
    _cleanupDisconnectedPeers(stopSignal);

    final bootDelayTimer = Timer(config.bootDelay, () {
      if (!(_stopController?.isClosed ?? true)) _notifyMaybeConnectToRelay();
    });

    _scheduleNextWork(peerSourceRateLimiter);

    stopSignal.listen((_) {
      bootDelayTimer.cancel();
      _workTimer?.cancel();
      peerSourceRateLimiter.close();
    });

    _triggerRunScheduledWorkController.stream.takeUntil(stopSignal).listen((_) {
       _runScheduledWork(config.clock.now(), peerSourceRateLimiter);
    });
    
    await stopSignal.first;
    if (!(_backgroundCompleter?.isCompleted ?? true)) {
         _backgroundCompleter!.complete();
    }
  }

  void _scheduleNextWork(StreamController<void> peerSourceRateLimiter) {
    _workTimer?.cancel();
    final nextRunTime = _runScheduledWork(config.clock.now(), peerSourceRateLimiter);
    final delay = nextRunTime.difference(config.clock.now());
    _workTimer = Timer(delay > Duration.zero ? delay : Duration.zero, () {
        if (_isRunning) _scheduleNextWork(peerSourceRateLimiter);
    });
  }
  
  DateTime _runScheduledWork(DateTime now, StreamController<void> peerSourceRateLimiter) {
    DateTime nextGlobalTime = now.add(_getLeastFrequentInterval());

    if (now.isAfter(_scheduledWorkTimes.nextRefresh)) {
      _scheduledWorkTimes = ScheduledWorkTimes(
          nextAllowedCallToPeerSource: _scheduledWorkTimes.nextAllowedCallToPeerSource,
          nextRefresh: now.add(rsvpRefreshInterval),
          nextBackoff: _scheduledWorkTimes.nextBackoff,
          nextOldCandidateCheck: _scheduledWorkTimes.nextOldCandidateCheck);
      // Call _refreshReservations; it handles _clearCachedAddrsAndSignalAddressChange internally
      _refreshReservations(now); 
    }

    if (now.isAfter(_scheduledWorkTimes.nextBackoff)) {
      _scheduledWorkTimes = ScheduledWorkTimes(
          nextAllowedCallToPeerSource: _scheduledWorkTimes.nextAllowedCallToPeerSource,
          nextRefresh: _scheduledWorkTimes.nextRefresh,
          nextBackoff: _clearBackoff(now),
          nextOldCandidateCheck: _scheduledWorkTimes.nextOldCandidateCheck);
    }

    if (now.isAfter(_scheduledWorkTimes.nextOldCandidateCheck)) {
       _scheduledWorkTimes = ScheduledWorkTimes(
          nextAllowedCallToPeerSource: _scheduledWorkTimes.nextAllowedCallToPeerSource,
          nextRefresh: _scheduledWorkTimes.nextRefresh,
          nextBackoff: _scheduledWorkTimes.nextBackoff,
          nextOldCandidateCheck: _clearOldCandidates(now));
    }
    
    if (now.isAfter(_scheduledWorkTimes.nextAllowedCallToPeerSource)) {
        if (!peerSourceRateLimiter.isClosed && !peerSourceRateLimiter.hasListener) {
            try { peerSourceRateLimiter.add(null); } catch (e) { /* already closed or full */ }
            _scheduledWorkTimes = ScheduledWorkTimes(
                nextAllowedCallToPeerSource: now.add(config.minInterval),
                nextRefresh: _scheduledWorkTimes.nextRefresh,
                nextBackoff: _scheduledWorkTimes.nextBackoff,
                nextOldCandidateCheck: _scheduledWorkTimes.nextOldCandidateCheck);
            if (_scheduledWorkTimes.nextAllowedCallToPeerSource.isBefore(nextGlobalTime)) {
                 nextGlobalTime = _scheduledWorkTimes.nextAllowedCallToPeerSource;
            }
        }
    } else {
        if (_scheduledWorkTimes.nextAllowedCallToPeerSource.isBefore(nextGlobalTime)) {
            nextGlobalTime = _scheduledWorkTimes.nextAllowedCallToPeerSource;
        }
    }

    if (_scheduledWorkTimes.nextRefresh.isBefore(nextGlobalTime)) nextGlobalTime = _scheduledWorkTimes.nextRefresh;
    if (_scheduledWorkTimes.nextBackoff.isBefore(nextGlobalTime)) nextGlobalTime = _scheduledWorkTimes.nextBackoff;
    if (_scheduledWorkTimes.nextOldCandidateCheck.isBefore(nextGlobalTime)) nextGlobalTime = _scheduledWorkTimes.nextOldCandidateCheck;
    
    if (nextGlobalTime.isAtSameMomentAs(now) || nextGlobalTime.isBefore(now)) {
        nextGlobalTime = now.add(const Duration(milliseconds: 100));
    }
    
    metricsTracer.scheduledWorkUpdated(_scheduledWorkTimes);
    return nextGlobalTime;
  }

  Duration _getLeastFrequentInterval() {
    var interval = config.minInterval;
    if (config.backoff > interval || interval == Duration.zero) interval = config.backoff;
    if (config.maxCandidateAge > interval || interval == Duration.zero) interval = config.maxCandidateAge;
    if (rsvpRefreshInterval > interval || interval == Duration.zero) interval = rsvpRefreshInterval;
    return interval == Duration.zero ? const Duration(seconds: 1) : interval;
  }

  void _findNodes(Stream<void> stopSignal, Stream<void> peerSourceRateLimiter) async {
    Stream<AddrInfo>? currentPeerStream;
    StreamSubscription<AddrInfo>? currentPeerSubscription;
    List<Future<void>> pendingNodeHandlers = [];

    await for (var _ in peerSourceRateLimiter.takeUntil(stopSignal)) {
      if (currentPeerStream != null) continue;

      int numCandidates = await _candidateMx.synchronized(() => _candidates.length);
      if (numCandidates < config.minCandidates) {
        metricsTracer.candidateLoopState(CandidateLoopState.peerSourceRateLimited);
        currentPeerStream = _peerSource(config.maxCandidates);
        
        currentPeerSubscription = currentPeerStream?.listen(
          (addrInfo) async {
            bool isOnBackoff = await _candidateMx.synchronized(() => _backoff.containsKey(addrInfo.id));
            if (isOnBackoff) return;
            int currentNumCandidates = await _candidateMx.synchronized(() => _candidates.length);
            if (currentNumCandidates >= config.maxCandidates) return;
            
            final handlerCompleter = Completer<void>();
            pendingNodeHandlers.add(handlerCompleter.future);
            _handleNewNode(addrInfo).then((added) {
              if (added) _notifyNewCandidate();
            }).whenComplete(() => handlerCompleter.complete());
          },
          onDone: () async {
            await Future.wait(pendingNodeHandlers);
            pendingNodeHandlers.clear();
            currentPeerStream = null;
            currentPeerSubscription = null;
            if (!(_stopController?.isClosed ?? true)) _triggerRunScheduledWorkController.add(null);
          },
          onError: (e) {
            currentPeerStream = null;
            currentPeerSubscription = null;
          },
          cancelOnError: true,
        );
        stopSignal.first.then((_) => currentPeerSubscription?.cancel());
      } else {
         metricsTracer.candidateLoopState(CandidateLoopState.waitingForTrigger);
      }
      
      await Future.any([
          _maybeRequestNewCandidatesController.stream.first,
          stopSignal.first,
          if (currentPeerSubscription != null) currentPeerSubscription!.asFuture().catchError((_){})
      ]);
      if (_stopController?.isClosed ?? true) break;
      currentPeerSubscription?.cancel();
      currentPeerStream = null; 
      await Future.wait(pendingNodeHandlers);
      pendingNodeHandlers.clear();
    }
    metricsTracer.candidateLoopState(CandidateLoopState.stopped);
  }
  
  Future<bool> _handleNewNode(AddrInfo addrInfo) async {
    bool isRelayInUse = await _relayMx.synchronized(() => _isUsingRelay(addrInfo.id));
    if (isRelayInUse) return false;

    try {
      final supportsV2 = await _tryNode(addrInfo).timeout(const Duration(seconds: 20));
      metricsTracer.candidateChecked(supportsV2);
      if (supportsV2) {
        await _candidateMx.synchronized(() {
          if (_candidates.length < config.maxCandidates) {
            _addCandidate(Candidate(
              added: config.clock.now(),
              addrInfo: addrInfo,
              supportsRelayV2: true,
            ));
          } else {
            return false;
          }
        });
        return true;
      }
    } catch (e) {
      if (e is _ProtocolNotSupportedException) {
         metricsTracer.candidateChecked(false);
      }
    }
    return false;
  }

  Future<bool> _tryNode(AddrInfo addrInfo) async {
    try {
      await host.connect(addrInfo);
    } catch (e) {
      throw Exception('Error connecting to potential relay ${addrInfo.id.toString()}: $e');
    }

    final conns = host.network.connsToPeer(addrInfo.id);
    for (Conn conn in conns) {
      if (isRelayAddress(conn.remoteMultiaddr)) {
        throw Exception('Not a public node (is a relay address)');
      }
    }

    final supportedProtocols = await host.peerStore.protoBook.supportsProtocols(addrInfo.id, [CircuitV2Protocol.protoIDv2Hop]);
    if (supportedProtocols.isEmpty) {
        throw _ProtocolNotSupportedException("Doesn't speak circuit v2 hop (${CircuitV2Protocol.protoIDv2Hop})");
    }
    return true;
  }

  void _handleNewCandidates(Stream<void> stopSignal) async {
    _candidateFoundController.stream.takeUntil(stopSignal).listen((_) {
      _notifyMaybeConnectToRelay();
    });
    _maybeConnectToRelayTriggerController.stream.takeUntil(stopSignal).listen((_) {
      _maybeConnectToRelay();
    });
  }

  Future<void> _maybeConnectToRelay() async {
    int numActiveRelays = await _relayMx.synchronized(() => _relays.length);
    if (numActiveRelays >= config.desiredRelays) return;

    bool canConnect = await _candidateMx.synchronized(() {
      if (_relays.isEmpty && _candidates.length < config.minCandidates && config.clock.since(_bootTime) < config.bootDelay) {
        return false;
      }
      return _candidates.isNotEmpty;
    });

    if (!canConnect) return;

    List<Candidate> selectedCandidates = await _candidateMx.synchronized(() => _selectCandidates());

    for (var cand in selectedCandidates) {
      PeerId id = cand.addrInfo.id;
      bool usingThisRelay = await _relayMx.synchronized(() => _isUsingRelay(id));
      if (usingThisRelay) {
        await _candidateMx.synchronized(() => _removeCandidate(id));
        _notifyMaybeNeedNewCandidates();
        continue;
      }

      try {
        final rsvp = await _connectToRelay(cand).timeout(const Duration(seconds: 15));
        await _relayMx.synchronized(() {
          _relays[id] = rsvp;
          numActiveRelays = _relays.length;
        });
        _notifyMaybeNeedNewCandidates();
        host.connManager.protect(id, autorelayTag);
        _notifyRelayUpdated();
        metricsTracer.reservationRequestFinished(false, null);

        if (numActiveRelays >= config.desiredRelays) break;
      } catch (e) {
        _notifyMaybeNeedNewCandidates();
        metricsTracer.reservationRequestFinished(false, e is Exception ? e : Exception(e.toString()));
      }
    }
  }
  
  Future<Reservation> _connectToRelay(Candidate candidate) async {
    final PeerId id = candidate.addrInfo.id;
    if (host.network.connectedness(id) != Connectedness.connected) {
      try {
        await host.connect(candidate.addrInfo).timeout(const Duration(seconds:10));
      } catch (e) {
        await _candidateMx.synchronized(() => _removeCandidate(id));
        throw Exception('Failed to connect before reserving: $e');
      }
    }

    await _candidateMx.synchronized(() {
      _backoff[id] = config.clock.now();
    });

    Reservation rsvp;
    try {
      final circuitClient = CircuitV2Client(host: host, upgrader: this.upgrader, connManager: host.connManager); // Changed Client to CircuitV2Client
      rsvp = await circuitClient.reserve(candidate.addrInfo.id).timeout(const Duration(seconds:10));
    } catch (e) {
      await _candidateMx.synchronized(() => _removeCandidate(id));
      rethrow;
    }
    
    await _candidateMx.synchronized(() => _removeCandidate(id));
    return rsvp;
  }

  Future<void> _refreshReservations(DateTime now) async {
    List<PeerId> toRefresh = [];
    await _relayMx.synchronized(() {
      _relays.forEach((peerId, rsvp) {
        if (now.add(rsvpExpirationSlack).isAfter(rsvp.expire)) {
          toRefresh.add(peerId);
        }
      });
    });

    if (toRefresh.isEmpty) {
      return;
    }

    bool anyChange = false;
    final client = CircuitV2Client(host: host, upgrader: this.upgrader, connManager: host.connManager); // Changed Client to CircuitV2Client
    
    List<Future<void>> refreshFutures = toRefresh.map((peerId) async {
      try {
        final newRsvp = await client.reserve(peerId).timeout(const Duration(seconds:10));
        await _relayMx.synchronized(() {
          _relays[peerId] = newRsvp;
          metricsTracer.reservationRequestFinished(true, null); 
          anyChange = true;
        });
      } catch (e) {
        await _relayMx.synchronized(() {
          if (_relays.containsKey(peerId)) {
             _relays.remove(peerId);
             host.connManager.unprotect(peerId, autorelayTag);
             metricsTracer.reservationEnded(1);
          }
          metricsTracer.reservationRequestFinished(true, e is Exception ? e : Exception(e.toString()));
          anyChange = true; 
        });
      }
    }).toList();

    await Future.wait(refreshFutures);

    if (anyChange) {
      _clearCachedAddrsAndSignalAddressChange();
    }
  }
  
  DateTime _clearBackoff(DateTime now) {
    DateTime nextTime = now.add(config.backoff);
    _candidateMx.synchronized(() {
      List<PeerId> toRemove = [];
      _backoff.forEach((id, backoffStartTime) {
        final expiry = backoffStartTime.add(config.backoff);
        if (expiry.isAfter(now)) {
          if (expiry.isBefore(nextTime)) nextTime = expiry;
        } else {
          toRemove.add(id);
        }
      });
      for (var id in toRemove) {
        _backoff.remove(id);
      }
    });
    return nextTime;
  }

  DateTime _clearOldCandidates(DateTime now) {
    DateTime nextTime = now.add(config.maxCandidateAge);
    bool deleted = false;
    _candidateMx.synchronized(() {
      List<PeerId> toRemove = [];
      _candidates.forEach((id, cand) {
        final expiry = cand.added.add(config.maxCandidateAge);
        if (expiry.isAfter(now)) {
          if (expiry.isBefore(nextTime)) nextTime = expiry;
        } else {
          toRemove.add(id);
          deleted = true;
        }
      });
      for (var id in toRemove) {
        _removeCandidate(id);
      }
    });
    if (deleted) _notifyMaybeNeedNewCandidates();
    return nextTime;
  }

  void _cleanupDisconnectedPeers(Stream<void> stopSignal) async {
    final eventBusSubscription = host.eventBus.subscribe(EvtPeerConnectednessChanged);
    StreamSubscription? streamSub; 

    streamSub = eventBusSubscription.stream.takeUntil(stopSignal).listen((event) {
      if (event is EvtPeerConnectednessChanged) {
        if (event.connectedness != Connectedness.notConnected) return;

        bool wasRelay = false;
        _relayMx.synchronized(() {
          if (_isUsingRelay(event.peer)) {
            _relays.remove(event.peer);
            host.connManager.unprotect(event.peer, autorelayTag);
            wasRelay = true;
          }
        });
        if (wasRelay) {
          _notifyMaybeConnectToRelay();
          _notifyMaybeNeedNewCandidates();
          _clearCachedAddrsAndSignalAddressChange();
          metricsTracer.reservationEnded(1);
        }
      }
    });

    stopSignal.first.then((_) {
      streamSub?.cancel();
      eventBusSubscription.close();
    });
  }

  void _notifyNewCandidate() {
    if (!(_candidateFoundController.isClosed)) _candidateFoundController.add(null);
  }
  void _notifyMaybeConnectToRelay() {
    if (!(_maybeConnectToRelayTriggerController.isClosed)) _maybeConnectToRelayTriggerController.add(null);
  }
  void _notifyMaybeNeedNewCandidates() {
    if (!(_maybeRequestNewCandidatesController.isClosed)) _maybeRequestNewCandidatesController.add(null);
  }
  void _notifyRelayUpdated() {
    if (!(_relayUpdatedController.isClosed)) _relayUpdatedController.add(null);
     // _relayUpdatedController.stream.first.then((_) => _clearCachedAddrsAndSignalAddressChange()); // This was causing issues, direct call is better
  }
  
  void _clearCachedAddrsAndSignalAddressChange() {
    _relayMx.synchronized(() {
      _cachedAddrs = [];
    });
    metricsTracer.relayAddressUpdated();
    _notifyRelayUpdated(); // Notify that addresses might have changed due to relay set change
  }

  bool _isUsingRelay(PeerId p) => _relays.containsKey(p);

  void _addCandidate(Candidate cand) {
    if (!_candidates.containsKey(cand.addrInfo.id)) {
      metricsTracer.candidateAdded(1);
    }
    _candidates[cand.addrInfo.id] = cand;
  }

  void _removeCandidate(PeerId id) {
    if (_candidates.containsKey(id)) {
      _candidates.remove(id);
      metricsTracer.candidateRemoved(1);
    }
  }

  List<Candidate> _selectCandidates() {
    final now = config.clock.now();
    List<Candidate> validCandidates = _candidates.values
        .where((cand) => cand.added.add(config.maxCandidateAge).isAfter(now))
        .toList();
    validCandidates.shuffle(Random(now.microsecondsSinceEpoch));
    return validCandidates;
  }

  Future<List<MultiAddr>> getRelayAddrs(List<MultiAddr> currentHostAddrs) async {
    return _relayMx.synchronized<List<MultiAddr>>(() async { // Made outer lambda async
      if (_cachedAddrs.isNotEmpty && config.clock.now().isBefore(_cachedAddrsExpiry)) {
        return List<MultiAddr>.from(_cachedAddrs);
      }

      List<MultiAddr> raddrs = [];
      for (var addr in currentHostAddrs) {
        if (addr.isPrivate() || addr.isLoopback()) {
          raddrs.add(addr);
        }
      }

      int relayAddrCountForMetrics = 0;
      // Use a temporary list to collect futures if forEach body is async
      List<Future<void>> addrProcessingFutures = [];

      _relays.forEach((peerId, reservation) {
        // This internal lambda for forEach cannot be async directly if the outer _relayMx.synchronized is not.
        // To do async work per relay, we'd collect futures and await them outside the synchronized block,
        // or make the synchronized block itself support async operations if the library allows.
        // For now, assuming addrs() is relatively quick or we accept blocking here.
        // A better pattern would be to get all relay PeerIds, release lock, get all addrs, re-acquire lock.
        
        // Simplified: if host.peerStore.addrBook.addrs is async, this forEach is problematic inside sync block.
        // Assuming it's synchronous for this sketch or this part needs more advanced refactoring.
        // For the purpose of this fix, let's assume it can be made to work.
        // The original Go code does this under a lock.
        
        // Corrected to be async and collect futures:
        final future = host.peerStore.addrBook.addrs(peerId).then((relayPeerAddrs) {
            final cleanedRelayPeerAddrs = address_utils.cleanupAddressSet(relayPeerAddrs);
            relayAddrCountForMetrics += cleanedRelayPeerAddrs.length;
            for (var relayAddr in cleanedRelayPeerAddrs) {
                try {
                    var circuitAddr = relayAddr
                        .encapsulate(Protocols.p2p.name, peerId.toString())
                        .encapsulate(Protocols.circuit.name, '');
                    raddrs.add(circuitAddr);
                } catch (e) {
                    // log.warning('Failed to create circuit address for relay $peerId via $relayAddr: $e');
                }
            }
        });
        addrProcessingFutures.add(future);
      });
      
      await Future.wait(addrProcessingFutures); // Wait for all async addr processing

      _cachedAddrs = List<MultiAddr>.from(raddrs);
      _cachedAddrsExpiry = config.clock.now().add(const Duration(seconds: 30));
      metricsTracer.relayAddressCount(relayAddrCountForMetrics);
      return raddrs;
    });
  }
}

class _ProtocolNotSupportedException implements Exception {
  final String message;
  _ProtocolNotSupportedException(this.message);
  @override
  String toString() => "ProtocolNotSupportedException: $message";
}

// Helper extension for Stream to mimic takeUntil from rxdart/async
extension StreamTakeUntil<T> on Stream<T> {
  Stream<T> takeUntil(Stream<void> signal) {
    StreamController<T>? controller;
    StreamSubscription<T>? subscription;
    StreamSubscription<void>? signalSubscription;

    controller = StreamController<T>(
      onListen: () {
        subscription = listen(
          controller!.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        signalSubscription = signal.listen(
          (_) => controller?.close(),
          onError: controller?.addError,
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        subscription?.cancel();
        signalSubscription?.cancel();
      },
    );
    return controller.stream;
  }
}
