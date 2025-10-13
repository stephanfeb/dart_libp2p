import 'dart:async';

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
// Corrected import for Protocol constants:
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart' as multiaddr_protocol;
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/network.dart';
import 'package:logging/logging.dart';

import '../../../core/interfaces.dart';
import '../../../core/network/conn.dart';

/// DialFunc is a function that dials a peer at a specific address
typedef DialFunc = Future<Conn> Function(Context context, MultiAddr addr, PeerId peerId);

/// AddrDialer is a helper for dialing multiple addresses in parallel
class AddrDialer {
  final Logger _logger = Logger('AddrDialer');

  /// The peer ID to dial
  final PeerId _peerId;

  /// The addresses to dial
  final List<MultiAddr> _addrs;

  /// The dial function to use
  final DialFunc _dialFunc;

  /// The context for the dial operation
  final Context _context;

  /// Creates a new AddrDialer
  AddrDialer({
    required PeerId peerId,
    required List<MultiAddr> addrs,
    required DialFunc dialFunc,
    required Context context,
  }) : 
    _peerId = peerId,
    _addrs = addrs,
    _dialFunc = dialFunc,
    _context = context;

  /// Dials the addresses in parallel and returns the first successful connection
  Future<Conn> dial() async {
    if (_addrs.isEmpty) {
      throw Exception('No addresses to dial');
    }

    // Create a completer for the first successful connection
    final completer = Completer<Conn>();
    
    // Track all errors for comprehensive reporting (3b)
    final errors = <String, Exception>{};
    var dialsInProgress = _addrs.length;

    // Dial ALL addresses in parallel immediately (1a)
    for (final addr in _addrs) {
      _dialAddr(addr).then((conn) {
        // First success wins
        if (!completer.isCompleted) {
          completer.complete(conn);
        }
      }).catchError((error) {
        // Collect error for this address
        errors[addr.toString()] = error is Exception 
            ? error 
            : Exception(error.toString());
        
        dialsInProgress--;
        
        // If all dials failed, report all errors
        if (dialsInProgress == 0 && !completer.isCompleted) {
          final errorMsg = errors.entries
              .map((e) => '${e.key}: ${e.value}')
              .join('; ');
          completer.completeError(
            Exception('Failed to dial any address. Errors: $errorMsg')
          );
        }
      });
    }

    return completer.future;
  }

  /// Dials a single address
  Future<Conn> _dialAddr(MultiAddr addr) async {
    try {
      _logger.fine('Dialing $addr');
      return await _dialFunc(_context, addr, _peerId);
    } catch (e) {
      _logger.warning('Failed to dial $addr: $e');
      rethrow;
    }
  }
}

/// DialRanker implementation that ranks addresses by delay
class DelayDialRanker {
  /// Call method to make this class callable as a function
  List<AddrDelay> call(List<MultiAddr> addrs) {
    final nonRelayAddrs = <MultiAddr>[];
    final relayAddrs = <MultiAddr>[];

    for (final addr in addrs) {
      bool isRelay = false;
      for (final p in addr.protocols) { // This 'p' is of type multiaddr_protocol.Protocol
        if (p.code == multiaddr_protocol.Protocols.circuit.code) { // Corrected access to P_CIRCUIT code
          isRelay = true;
          break;
        }
      }

      if (isRelay) {
        relayAddrs.add(addr);
      } else {
        nonRelayAddrs.add(addr);
      }
    }

    final result = <AddrDelay>[];
    // Add non-relay addresses first, with zero delay
    for (final addr in nonRelayAddrs) {
      result.add(AddrDelay(addr: addr, delay: Duration.zero));
    }
    // Add relay addresses next, also with zero delay for now (could add a slight delay later)
    for (final addr in relayAddrs) {
      result.add(AddrDelay(addr: addr, delay: Duration.zero));
    }

    return result;
  }
}

/// DialBackoff implements exponential backoff for failed dials
class DialBackoff {
  /// The base delay for backoff
  final Duration _baseDelay;

  /// The maximum delay for backoff
  final Duration _maxDelay;

  /// The current delay
  Duration _currentDelay;

  /// Creates a new DialBackoff
  DialBackoff({
    Duration baseDelay = const Duration(milliseconds: 100),
    Duration maxDelay = const Duration(minutes: 5),
  }) : 
    _baseDelay = baseDelay,
    _maxDelay = maxDelay,
    _currentDelay = baseDelay;

  /// Gets the next delay and increases the backoff
  Duration nextDelay() {
    final delay = _currentDelay;

    // Double the delay for next time, but don't exceed max
    _currentDelay = Duration(milliseconds: _currentDelay.inMilliseconds * 2);
    if (_currentDelay > _maxDelay) {
      _currentDelay = _maxDelay;
    }

    return delay;
  }

  /// Resets the backoff to the base delay
  void reset() {
    _currentDelay = _baseDelay;
  }
}
