

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:dart_libp2p/p2p/transport/udx_exceptions.dart';
import 'package:dart_udx/dart_udx.dart';

import 'package:dart_libp2p/core/connmgr/conn_manager.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/common.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/mux.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/p2p/transport/listener.dart';
import 'package:logging/logging.dart';

final Logger _logger = Logger('UDXStreamAdapter');

class UDXP2PStreamAdapter implements MuxedStream, P2PStream<Uint8List> {
  final UDXStream _udxStream;
  UDXStream get udxStream => _udxStream; // Expose the underlying stream
  final UDXSessionConn _parentConn;
  final Direction _direction;
  String _protocol = '';
  bool _isClosed = false;
  final StreamController<Uint8List> _incomingDataController = StreamController<Uint8List>.broadcast(); // Kept for .stream getter if used elsewhere
  final List<Uint8List> _readBuffer = [];
  Completer<Uint8List>? _pendingReadCompleter; // For direct signaling to a waiting read()
  StreamSubscription? _udxStreamDataSubscription;
  StreamSubscription? _udxStreamCloseSubscription;
  final Completer<void> _closedCompleter = Completer<void>();

  UDXP2PStreamAdapter({
    required UDXStream udxStream,
    required UDXSessionConn parentConn,
    required Direction direction,
  }) : _udxStream = udxStream,
        _parentConn = parentConn,
        _direction = direction {
    _logger.fine('[UDXP2PStreamAdapter ${id()}] Constructor: udxStreamId=${udxStream.id}, direction=$_direction');
    _udxStreamDataSubscription = _udxStream.data.listen(
            (data) {
          _logger.fine('[UDXP2PStreamAdapter ${id()}] _udxStream.data listener received ${data.length} bytes.');
          if (_pendingReadCompleter != null && !_pendingReadCompleter!.isCompleted) {
            _logger.fine('[UDXP2PStreamAdapter ${id()}] Completing pending read with ${data.length} bytes.');
            _pendingReadCompleter!.complete(data);
            _pendingReadCompleter = null; // Consume the completer
          } else if (!_incomingDataController.isClosed) { // Fallback to controller/buffer if no pending read
            _logger.fine('[UDXP2PStreamAdapter ${id()}] No pending read, adding ${data.length} bytes to _readBuffer (via _incomingDataController).');
            // We'll add to _readBuffer directly now, _incomingDataController might be removed if not used by .stream getter
            _readBuffer.add(data);
            // If .stream getter is vital, can still add to controller too, or rethink .stream
            if (!_incomingDataController.isClosed) _incomingDataController.add(data);

          } else {
            _logger.fine('[UDXP2PStreamAdapter ${id()}] No pending read and _incomingDataController is closed. Data might be lost or handled by buffer.');
            // If controller is closed, but stream isn't, buffer it.
            if (!_isClosed) {
              _readBuffer.add(data);
            }
          }
          _parentConn.notifyActivity();
        },
        onError: (err, s) {
          _logger.fine('[UDXP2PStreamAdapter ${id()}] Error on UDXStream data: $err');
          
          // Classify UDX error and isolate stream failure from connection
          final classifiedException = UDXExceptionHandler.classifyUDXException(
            err, 
            'UDXP2PStreamAdapter(${id()}).data.onError', 
            s,
          );
          
          // Log specific handling for packet loss
          if (classifiedException is UDXPacketLossException) {
            _logger.warning('[UDXP2PStreamAdapter ${id()}] Packet permanently lost on stream. Stream will be closed but connection should remain stable.');
          } else if (classifiedException is UDXStreamException) {
            _logger.info('[UDXP2PStreamAdapter ${id()}] Stream-specific error: ${classifiedException.message}');
          }
          
          if (_pendingReadCompleter != null && !_pendingReadCompleter!.isCompleted) {
            _pendingReadCompleter!.completeError(classifiedException, s);
            _pendingReadCompleter = null;
          }
          if (!_incomingDataController.isClosed) { 
            _incomingDataController.addError(classifiedException, s); 
          }
          _closeWithError(classifiedException, s);
        },
        onDone: () {
          _logger.fine('[UDXP2PStreamAdapter ${id()}] UDXStream data stream done.');
          _close();
        }
    );
    _udxStreamCloseSubscription = _udxStream.closeEvents.listen(
            (_) {
          _logger.fine('[UDXP2PStreamAdapter ${id()}] UDXStream close event received.');
          _close();
        },
        onError: (err, s) {
          _logger.fine('[UDXP2PStreamAdapter ${id()}] UDXStream close event error: $err');
          _closeWithError(err, s);
        }
    );
  }

  @override
  String id() {
    return _udxStream.id.toString();
  }

  @override
  String protocol() {
    return _protocol;
  }

  @override
  Future<void> setProtocol(String protocolId) async {
    _logger.fine('[UDXP2PStreamAdapter ${id()}] setProtocol: $protocolId');
    _protocol = protocolId;
  }

  @override
  Stream<Uint8List> get stream {
    return _incomingDataController.stream;
  }

  @override
  Future<Uint8List> read([int? maxLength]) async {
    _logger.fine('[UDXP2PStreamAdapter ${id()}] read called. maxLength: $maxLength, isClosed: $_isClosed, buffer: ${_readBuffer.length}, pendingRead: ${_pendingReadCompleter != null}');

    if (_isClosed && _readBuffer.isEmpty) {
      _logger.fine('[UDXP2PStreamAdapter ${id()}] Stream closed and buffer empty. Returning EOF.');
      return Uint8List(0);
    }

    if (_readBuffer.isNotEmpty) {
      final currentChunk = _readBuffer.removeAt(0);
      if (maxLength == null || currentChunk.length <= maxLength) {
        _logger.fine('[UDXP2PStreamAdapter ${id()}] Consumed ${currentChunk.length} bytes from buffer.');
        return currentChunk;
      } else {
        final toReturn = currentChunk.sublist(0, maxLength);
        final remainder = currentChunk.sublist(maxLength);
        _readBuffer.insert(0, remainder);
        _logger.fine('[UDXP2PStreamAdapter ${id()}] Consumed $maxLength bytes from buffer, remainder ${remainder.length} put back.');
        return toReturn;
      }
    }

    // Buffer is empty, and stream is not closed (or if closed, there might still be a pending completer from data that arrived just before close)
    if (_pendingReadCompleter != null) {
      // This should ideally not happen if completers are managed strictly (i.e., only one pending read).
      // However, if it does, it means a read was called while another was already pending.
      _logger.fine('[UDXP2PStreamAdapter ${id()}] Warning: Another read was already pending. This new read will also wait.');
      // Fall through to create a new completer, the old one will be orphaned or error.
      // A better approach might be to queue read requests, but for now, let's keep it simpler.
    }

    _logger.fine('[UDXP2PStreamAdapter ${id()}] Buffer empty, creating _pendingReadCompleter.');
    _pendingReadCompleter = Completer<Uint8List>();

    try {
      final newData = await _pendingReadCompleter!.future.timeout(
          const Duration(seconds: 30), // Slightly increased timeout
          onTimeout: () {
            _logger.fine('[UDXP2PStreamAdapter ${id()}] Read timeout on _pendingReadCompleter.');
            if (_pendingReadCompleter?.isCompleted == false) {
              _pendingReadCompleter!.completeError(TimeoutException('Read timeout on UDXP2PStreamAdapter', const Duration(seconds: 25)));
            }
            throw TimeoutException('Read timeout on UDXP2PStreamAdapter', const Duration(seconds: 30));
          }
      );
      // _pendingReadCompleter is set to null by the listener when it completes it.
      // Or it should be nulled here if completed by timeout error path, though throw happens first.

      _logger.fine('[UDXP2PStreamAdapter ${id()}] Received ${newData.length} bytes via _pendingReadCompleter.');

      if (maxLength == null || newData.length <= maxLength) {
        return newData;
      } else {
        final toReturn = newData.sublist(0, maxLength);
        final remainder = newData.sublist(maxLength);
        _readBuffer.add(remainder); // Buffer the remainder
        _logger.fine('[UDXP2PStreamAdapter ${id()}] Consumed $maxLength bytes from completer, remainder ${remainder.length} buffered.');
        return toReturn;
      }
    } catch (e) {
      _logger.fine('[UDXP2PStreamAdapter ${id()}] Error awaiting _pendingReadCompleter: $e');
      // Ensure completer is nulled if it was this read's completer that errored
      if (_pendingReadCompleter?.isCompleted == false) {
        // If error is not from the completer itself (e.g. future cancelled), complete it with error.
        // _pendingReadCompleter!.completeError(e); // This might cause issues if already completing.
      }
      _pendingReadCompleter = null; // Nullify on error too
      if (_isClosed && _readBuffer.isEmpty) return Uint8List(0); // EOF if closed
      rethrow; // Rethrow the error (e.g., TimeoutException)
    }
  }

  @override
  Future<void> write(List<int> data) async {
    _logger.fine('[UDXP2PStreamAdapter ${id()}] write called with ${data.length} bytes. isClosed: $_isClosed');
    if (_isClosed) {
      _logger.fine('[UDXP2PStreamAdapter ${id()}] Stream closed, throwing StateError on write.');
      throw StateError('Stream is closed');
    }
    await _udxStream.add(data is Uint8List ? data : Uint8List.fromList(data));
    _parentConn.notifyActivity();
    _logger.fine('[UDXP2PStreamAdapter ${id()}] Data written to UDXStream.');
  }

  Future<void> _close() async {
    _logger.fine('[UDXP2PStreamAdapter ${id()}] _close called. Is already closed: $_isClosed');
    if (_isClosed) return;
    _isClosed = true;

    _logger.fine('[UDXP2PStreamAdapter ${id()}] Cancelling UDXStream subscriptions.');
    await _udxStreamDataSubscription?.cancel();
    _udxStreamDataSubscription = null;
    await _udxStreamCloseSubscription?.cancel();
    _udxStreamCloseSubscription = null;

    if (!_incomingDataController.isClosed) {
      _logger.fine('[UDXP2PStreamAdapter ${id()}] Closing incoming data controller.');
      await _incomingDataController.close();
    }
    try {
      _logger.fine('[UDXP2PStreamAdapter ${id()}] Closing underlying UDXStream.');
      await _udxStream.close();
      _logger.fine('[UDXP2PStreamAdapter ${id()}] Underlying UDXStream closed.');
    } catch (e) {
      _logger.fine('[UDXP2PStreamAdapter ${id()}] Error closing UDXStream: $e');
    }
    if (!_closedCompleter.isCompleted) {
      _logger.fine('[UDXP2PStreamAdapter ${id()}] Completing close completer.');
      _closedCompleter.complete();
    }
  }

  Future<void> _closeWithError(dynamic error, [StackTrace? stackTrace]) async {
    _logger.fine('[UDXP2PStreamAdapter ${id()}] _closeWithError called with error: $error');
    if (!_closedCompleter.isCompleted) {
      _logger.fine('[UDXP2PStreamAdapter ${id()}] Completing close completer with error.');
      _closedCompleter.completeError(error, stackTrace);
    }
    await _close();
  }

  @override
  Future<void> close() async {
    _logger.fine('[UDXP2PStreamAdapter ${id()}] close() called.');
    return _close();
  }

  @override
  Future<void> closeWrite() async {
    _logger.fine('[UDXP2PStreamAdapter ${id()}] closeWrite() called, performing full stream close as dart-udx does not support half-closure.');
    await _close();
  }

  @override
  Future<void> closeRead() async {
    _logger.fine('[UDXP2PStreamAdapter ${id()}] closeRead() called. This is a no-op as dart-udx does not support read-side half-closure.');
  }

  @override
  Future<void> reset() async {
    _logger.fine('[UDXP2PStreamAdapter ${id()}] reset() called, performing full stream close with error.');
    final exception = SocketException("Stream reset by local peer");
    await _closeWithError(exception, StackTrace.current);
    throw exception;
  }

  @override
  StreamStats stat() {
    return StreamStats(
      direction: _direction,
      opened: DateTime.now(),
      extra: {'udxStreamId': id(), 'protocol': _protocol},
    );
  }


  @override
  Future<void> setDeadline(DateTime? time) async => throw UnimplementedError("Deadlines not implemented.");
  @override
  Future<void> setReadDeadline(DateTime time) async => throw UnimplementedError("Deadlines not implemented.");
  @override
  Future<void> setWriteDeadline(DateTime time) async => throw UnimplementedError("Deadlines not implemented.");

  @override
  bool get isClosed {
    return _isClosed;
  }

  @override
  Future<void> get onClose {
    return _closedCompleter.future;
  }

  @override
  StreamManagementScope scope() => throw UnimplementedError("Scope not yet implemented for UDXP2PStreamAdapter.");

  @override
  P2PStream<Uint8List> get incoming {
    return this;
  }

  @override
  // TODO: implement conn
  Conn get conn => _parentConn as Conn ;
}

typedef UDXSessionConnFactory = UDXSessionConn Function({
  required UDPSocket udpSocket,
  required UDXStream initialStream,
  required MultiAddr localMultiaddr,
  required MultiAddr remoteMultiaddr,
  required UDXTransport transport,
  required ConnManager connManager,
  required bool isDialer,
  required void Function(TransportConn) onClosed,
});

class UDXListener implements Listener {
  final UDXMultiplexer _multiplexer;
  final UDX _udxInstance;
  final MultiAddr _boundAddr;
  final UDXTransport _transport;
  final ConnManager _connManager;
  final UDXSessionConnFactory _sessionConnFactory;

  final StreamController<TransportConn> _incomingSessionController = StreamController<TransportConn>.broadcast();
  late StreamSubscription _connectionSubscription;
  bool _isClosed = false;
  final Map<String, UDXSessionConn> _activeSessions = {};

  UDXListener({
    required UDXMultiplexer listeningSocket,
    required UDX udxInstance,
    required MultiAddr boundAddr,
    required UDXTransport transport,
    required ConnManager connManager,
    UDXSessionConnFactory? sessionConnFactory,
  }) : _multiplexer = listeningSocket,
        _udxInstance = udxInstance,
        _boundAddr = boundAddr,
        _transport = transport,
        _connManager = connManager,
        _sessionConnFactory = sessionConnFactory ?? UDXSessionConn.new {
    _logger.fine('[UDXListener $addr] Constructor: Initializing for $_boundAddr.');
    _logger.fine('[UDXListener $addr] Constructor: Subscribing to multiplexer connections...');

    _connectionSubscription = _multiplexer.connections.listen(
        (UDPSocket socket) {
          _logger.fine('[UDXListener $addr] Received new connection from multiplexer. Calling _handleIncomingConnection.');
          _handleIncomingConnection(socket);
        },
        onError: (err, stackTrace) {
          _logger.fine('[UDXListener $addr] !!! onError in connection subscription: $err');
          _logger.fine('[UDXListener $addr] Stack trace for onError: $stackTrace');
          if (!_incomingSessionController.isClosed) {
            _incomingSessionController.addError(err, stackTrace);
          }
          _logger.fine('[UDXListener $addr] Closing listener due to multiplexer subscription error.');
          close();
        },
        onDone: () {
          _logger.fine('[UDXListener $addr] !!! onDone in connection subscription. Multiplexer closed.');
          _logger.fine('[UDXListener $addr] Closing listener because multiplexer is done.');
          close();
        }
    );
    _logger.fine('[UDXListener $addr] Constructor: Subscription to connections complete.');
  }

  void _handleIncomingConnection(UDPSocket socket) {
    _logger.fine('[UDXListener $addr] _handleIncomingConnection EXECUTION STARTED. Socket: ${socket.remoteAddress}:${socket.remotePort}');
    if (_isClosed) {
      _logger.fine('[UDXListener $addr] Listener is already closed, ignoring incoming connection.');
      socket.close();
      return;
    }

    final remoteHost = socket.remoteAddress.address;
    final remotePort = socket.remotePort;
    final sessionKey = "$remoteHost:$remotePort";

    // Check if we already have a session for this peer
    if (_activeSessions.containsKey(sessionKey)) {
      _logger.fine('[UDXListener $addr] Session for $sessionKey already exists. Closing duplicate connection.');
      socket.close();
      return;
    }

    _logger.fine('[UDXListener $addr] New session detected from $sessionKey. Checking for buffered streams.');
    
    // First, check if there are already buffered streams (this handles the timing issue)
    final bufferedStreams = socket.getStreamBuffer();
    if (bufferedStreams.isNotEmpty) {
      _logger.fine('[UDXListener $addr] Found ${bufferedStreams.length} buffered streams, using first one.');
      final initialStream = bufferedStreams.first;
      _createSession(socket, initialStream, sessionKey, remoteHost, remotePort);
      return;
    }
    
    _logger.fine('[UDXListener $addr] No buffered streams found. Waiting for initial stream event.');
    
    // Listen for the first stream on this socket to create the session
    late StreamSubscription streamSubscription;
    streamSubscription = socket.on('stream').listen(
      (UDXEvent event) {
        final initialStream = event.data as UDXStream;
        _logger.fine('[UDXListener $addr] Received initial stream ${initialStream.id} for new session.');
        
        // Cancel the subscription since we only need the first stream
        streamSubscription.cancel();
        
        _createSession(socket, initialStream, sessionKey, remoteHost, remotePort);
      },
      onError: (err, stackTrace) {
        _logger.fine('[UDXListener $addr] Error waiting for initial stream on $sessionKey: $err');
        socket.close();
      }
    );
    
    // Also flush any streams that might be buffered to trigger the event
    socket.flushStreamBuffer();
  }
  
  void _createSession(UDPSocket socket, UDXStream initialStream, String sessionKey, String remoteHost, int remotePort) {
    try {
      final ipProtocol = socket.remoteAddress.type == InternetAddressType.IPv4 ? 'ip4' : 'ip6';
      final remoteMaString = '/$ipProtocol/$remoteHost/udp/$remotePort/udx';
      final remoteMa = MultiAddr(remoteMaString);
      _logger.fine('[UDXListener $addr] Creating UDXSessionConn for new session. Local: $_boundAddr, Remote: $remoteMa');

      final sessionConn = _sessionConnFactory(
          udpSocket: socket,
          initialStream: initialStream,
          localMultiaddr: _boundAddr,
          remoteMultiaddr: remoteMa,
          transport: _transport,
          connManager: _connManager,
          isDialer: false,
          onClosed: (conn) {
            _activeSessions.remove(sessionKey);
            _logger.fine('[UDXListener $addr] Session ${conn.id} closed and removed from active sessions.');
          }
      );
      _logger.fine('[UDXListener $addr] UDXSessionConn created for new session ${sessionConn.id}.');

      _activeSessions[sessionKey] = sessionConn;
      _logger.fine('[UDXListener $addr] Added new session ${sessionConn.id} to active sessions.');

      _connManager.registerConnection(sessionConn);
      _logger.fine('[UDXListener $addr] Registered new session ${sessionConn.id} with ConnectionManager.');

      if (!_incomingSessionController.isClosed) {
        _incomingSessionController.add(sessionConn);
        _logger.fine('[UDXListener $addr] Added new session ${sessionConn.id} to incoming session controller.');
      } else {
        _logger.fine("[UDXListener $addr] Incoming session controller closed, closing new session to $sessionKey");
        sessionConn.close();
        _activeSessions.remove(sessionKey);
      }
    } catch (e, s) {
      _logger.fine("[UDXListener $addr] Error creating new UDX session for $sessionKey: $e\n$s");
      initialStream.close();
      socket.close();
    }
  }

  @override
  MultiAddr get addr => _boundAddr;

  @override
  Stream<TransportConn> get connectionStream {
    _logger.fine('[UDXListener $addr] get connectionStream');
    return _incomingSessionController.stream;
  }

  @override
  Future<TransportConn?> accept() async {
    _logger.fine('[UDXListener $addr] accept called.');
    if (_isClosed && _incomingSessionController.isClosed) {
      _logger.fine('[UDXListener $addr] Listener closed, cannot accept.');
      return null;
    }
    final conn = await _incomingSessionController.stream.first;
    _logger.fine('[UDXListener $addr] Accepted connection: ${conn.id}');
    return conn;
  }

  @override
  Future<void> close() async {
    _logger.fine('[UDXListener $addr] close called. Is already closed: $_isClosed');
    if (_isClosed) return;
    _isClosed = true;

    if (!_incomingSessionController.isClosed) {
      _logger.fine('[UDXListener $addr] Closing incoming session controller.');
      await _incomingSessionController.close();
    }

    _logger.fine('[UDXListener $addr] Closing all active sessions (${_activeSessions.length} sessions).');
    for (var session in _activeSessions.values.toList()) {
      try {
        await session.close();
      } catch (e) {
        _logger.fine('[UDXListener $addr] Error closing session ${session.id}: $e');
      }
    }
    _activeSessions.clear();
    _logger.fine('[UDXListener $addr] All active sessions from this listener closed and cleared.');

    try {
      _logger.fine('[UDXListener $addr] Closing multiplexer.');
      _multiplexer.close();
      _logger.fine('[UDXListener $addr] Multiplexer closed.');
    } catch (e) {
      _logger.fine('[UDXListener $addr] Error closing multiplexer: $e');
    }
  }

  @override
  bool get isClosed {
    return _isClosed;
  }

  @override
  bool supportsAddr(MultiAddr addr) {
    return addr.hasProtocol('udx');
  }
}
