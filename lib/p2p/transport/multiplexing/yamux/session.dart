import 'dart:async';
import 'dart:typed_data';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:logging/logging.dart'; // Added for logging

import '../../../../core/network/conn.dart';
import '../../../../core/network/stream.dart';
import '../../../../core/network/transport_conn.dart';
import '../../../../core/crypto/keys.dart'; // For PublicKey
import '../../../../core/multiaddr.dart'; // For Multiaddr
import '../multiplexer.dart'; // This now brings in core_mux.MuxedConn and PeerScope via its own imports
import '../../../../core/network/mux.dart' as core_mux; // Explicit import for MuxedConn, MuxedStream
import '../../../../core/network/rcmgr.dart'; // Explicit import for PeerScope
import '../../../../core/network/context.dart'; // Explicit import for Context
import 'frame.dart';
import 'stream.dart';

// Added logger instance
final _log = Logger('YamuxSession');

/// Reasons for closing a Yamux session
enum YamuxCloseReason {
  /// Normal closure
  normal(0x0),
  /// Protocol error
  protocolError(0x1),
  /// Internal error
  internalError(0x2);

  final int value;
  const YamuxCloseReason(this.value);
}


class YamuxConstants {
  static const String protocolId = '/yamux/1.0.0';
}

/// Yamux session that implements the Multiplexer and MuxedConn interfaces
class YamuxSession implements Multiplexer, core_mux.MuxedConn, Conn { // Added Conn
  static int _instanceCounter = 0; // Added instance counter
  final int _instanceId; // Added instance ID field

  // Session-level performance constants for adaptive behavior
  static const int _maxMetricsHistory = 50;
  static const int _maxFramesPerBatch = 20;
  static const Duration _batchProcessingDelay = Duration(milliseconds: 5);
  static const Duration _stressThreshold = Duration(milliseconds: 50);

  @override
  final String protocolId = YamuxConstants.protocolId;

  final TransportConn _connection;
  final MultiplexerConfig _config;
  final bool _isClient;
  PeerScope? _peerScope; 

  final _streams = <int, YamuxStream>{};
  int _nextStreamId;
  Future<void> Function(P2PStream stream)? _streamHandler;
  final _incomingStreamsController = StreamController<P2PStream>.broadcast();
  bool _closed = false;
  bool _cleanupStarted = false; 
  final _initCompleter = Completer<void>();
  Timer? _keepaliveTimer;
  String get _logPrefix => "[$_instanceId][${_isClient ? "Client" : "Server"}]";
  int _lastPingId = 0;
  final _pendingStreams = <int, Completer<void>>{};

  YamuxSession(this._connection, this._config, this._isClient, [this._peerScope])
      : _instanceId = _instanceCounter++, 
        _nextStreamId = _isClient ? 1 : 2 {
    _log.fine('$_logPrefix Constructor. IsClient: $_isClient');
    _init();
  }

  void _init() {
    _readFrames().catchError((error, stackTrace) { 
      if (!_closed) {
        _log.severe('$_logPrefix Uncaught error in _readFrames, initiating GO_AWAY: $error', stackTrace);
        _goAway(YamuxCloseReason.internalError);
      } else {
        _log.fine('$_logPrefix Error in _readFrames after session closed: $error', stackTrace);
      }
    });
    _startKeepalive();
    _initCompleter.complete();
  }

  void _startKeepalive() {
    if (_config.keepAliveInterval == Duration.zero) {
      return;
    }
    _keepaliveTimer = Timer.periodic(_config.keepAliveInterval, (_) => _sendPing());
  }

  Future<void> _sendPing() async {
    if (_closed) return;
    final pingId = ++_lastPingId;
    _log.finer('$_logPrefix Sending PING frame, id: $pingId');
    try {
      final frame = YamuxFrame.ping(false, pingId);
      await _sendFrame(frame);
    } catch (e) {
      _log.warning('$_logPrefix Error sending PING: $e. Session may be unhealthy.');
      // Consider closing session if ping fails repeatedly, but for now just log.
    }
  }

  Future<void> _readFrames() async {
    final headerSize = 12;
    var buffer = Uint8List(0); 
    int frameCount = 0;
    int framesInCurrentBatch = 0;
    final startTime = DateTime.now();
    
    // Session-level performance tracking for adaptive behavior
    final List<Duration> _recentFrameProcessingTimes = [];

    // High-volume mode detection to reduce logging overhead
    bool _isHighVolumeMode = false;
    int _recentFrameCount = 0;
    DateTime _lastFrameCountReset = DateTime.now();

    void _updateVolumeMode() {
      final now = DateTime.now();
      if (now.difference(_lastFrameCountReset) > Duration(seconds: 1)) {
        _isHighVolumeMode = _recentFrameCount > 50; // 50+ frames/sec = high volume
        _recentFrameCount = 0;
        _lastFrameCountReset = now;
        
        if (_isHighVolumeMode) {
          _log.fine('$_logPrefix Entering high-volume mode (50+ frames/sec) - reducing logging overhead');
        }
      }
    }

    void _logFrameProcessing(String message) {
      if (!_isHighVolumeMode) {
        _log.fine(message);
      }
    }

    void _recordFrameProcessingTime(Duration duration) {
      _recentFrameProcessingTimes.add(duration);
      if (_recentFrameProcessingTimes.length > _maxMetricsHistory) {
        _recentFrameProcessingTimes.removeAt(0);
      }
    }

    bool _isSessionUnderStress() {
      if (_recentFrameProcessingTimes.length < 10) return false;
      
      final avgTime = _recentFrameProcessingTimes.reduce((a, b) => a + b) ~/ 
                     _recentFrameProcessingTimes.length;
      return avgTime > _stressThreshold;
    }

    Future<void> _applyAdaptiveDelay() async {
      if (_isSessionUnderStress()) {
        // Apply longer delay when session is under stress
        await Future.delayed(Duration(milliseconds: 10));
        _logFrameProcessing('$_logPrefix Applied stress-relief delay (10ms) due to slow frame processing');
      } else {
        // Standard batch processing delay
        await Future.delayed(_batchProcessingDelay);
        _logFrameProcessing('$_logPrefix Applied standard batch processing delay (${_batchProcessingDelay.inMilliseconds}ms)');
      }
    }

    try {
      while (!_closed) {
        final loopStartTime = DateTime.now();
        frameCount++;
        framesInCurrentBatch++;
        _recentFrameCount++;
        
        // Update volume mode detection
        _updateVolumeMode();
        
        _logFrameProcessing('$_logPrefix 🔧 [YAMUX-FRAME-READER-LOOP-$frameCount] Starting frame read iteration. Buffer size: ${buffer.length}, Session closed: $_closed, Connection closed: ${_connection.isClosed}');
        
        // Adaptive yielding based on batch processing and session stress
        if (framesInCurrentBatch >= _maxFramesPerBatch) {
          await _applyAdaptiveDelay();
          framesInCurrentBatch = 0;
          _logFrameProcessing('$_logPrefix 🔧 [YAMUX-FRAME-READER-BATCH-YIELD] Applied adaptive delay after $frameCount frames (batch size: $_maxFramesPerBatch)');
        } else {
          // Minimal yield for event loop cooperation during normal processing
          await Future.delayed(Duration.zero);
        }
        
        // Ensure we have enough bytes for at least a header
        _logFrameProcessing('$_logPrefix 🔧 [YAMUX-FRAME-READER-HEADER-$frameCount] Need $headerSize bytes for header, have ${buffer.length} bytes');
        while (buffer.length < headerSize) {
          if (_closed || _connection.isClosed) { // Check before read
             _log.warning('$_logPrefix 🔧 [YAMUX-FRAME-READER-EXIT-$frameCount] Loop condition met (_closed=$_closed, _conn.isClosed=${_connection.isClosed}) before reading for header. Exiting.');
             await _cleanupWithoutFrames(); return;
          }
          
          final bytesNeeded = headerSize - buffer.length;
          _log.fine('$_logPrefix 🔧 [YAMUX-FRAME-READER-HEADER-READ-$frameCount] About to read $bytesNeeded bytes for header from connection');
          
          final readStartTime = DateTime.now();
          final chunk = await _connection.read(bytesNeeded);
          final readDuration = DateTime.now().difference(readStartTime);
          
          _log.fine('$_logPrefix 🔧 [YAMUX-FRAME-READER-HEADER-READ-RESULT-$frameCount] Read ${chunk.length} bytes in ${readDuration.inMilliseconds}ms (requested $bytesNeeded)');
          
          if (chunk.isEmpty) { // Connection closed by peer
            _log.warning('$_logPrefix 🔧 [YAMUX-FRAME-READER-EOF-$frameCount] Connection closed by peer while reading header. Cleaning up.');
            await _cleanupWithoutFrames(); return;
          }
          final newBuffer = Uint8List(buffer.length + chunk.length);
          newBuffer.setAll(0, buffer);
          newBuffer.setAll(buffer.length, chunk);
          buffer = newBuffer;
          
          _log.fine('$_logPrefix 🔧 [YAMUX-FRAME-READER-HEADER-PROGRESS-$frameCount] Header buffer now has ${buffer.length}/$headerSize bytes');
        }

        _log.fine('$_logPrefix 🔧 [YAMUX-FRAME-READER-HEADER-COMPLETE-$frameCount] Header read complete, parsing frame info');
        
        final headerView = ByteData.view(buffer.buffer, buffer.offsetInBytes, headerSize);
        final bodyLength = headerView.getUint32(8, Endian.big);
        final expectedTotalFrameLength = headerSize + bodyLength;
        
        _log.fine('$_logPrefix 🔧 [YAMUX-FRAME-READER-BODY-$frameCount] Frame body length: $bodyLength, total expected: $expectedTotalFrameLength, current buffer: ${buffer.length}');

        // Ensure we have the full frame (header + body) in the buffer
        while (buffer.length < expectedTotalFrameLength) {
          if (_closed || _connection.isClosed) { // Check before read
             _log.warning('$_logPrefix 🔧 [YAMUX-FRAME-READER-EXIT-BODY-$frameCount] Loop condition met (_closed=$_closed, _conn.isClosed=${_connection.isClosed}) before reading for body. Exiting.');
             await _cleanupWithoutFrames(); return;
          }
          final stillNeeded = expectedTotalFrameLength - buffer.length;
          _log.fine('$_logPrefix 🔧 [YAMUX-FRAME-READER-BODY-READ-$frameCount] About to read $stillNeeded bytes for frame body from connection');
          
          final bodyReadStartTime = DateTime.now();
          final chunk = await _connection.read(stillNeeded);
          final bodyReadDuration = DateTime.now().difference(bodyReadStartTime);
          
          _log.fine('$_logPrefix 🔧 [YAMUX-FRAME-READER-BODY-READ-RESULT-$frameCount] Read ${chunk.length} bytes in ${bodyReadDuration.inMilliseconds}ms (requested $stillNeeded)');
          
          if (chunk.isEmpty) { // Connection closed by peer
             _log.warning('$_logPrefix 🔧 [YAMUX-FRAME-READER-EOF-BODY-$frameCount] Connection closed by peer while reading body (header indicated bodyLength $bodyLength). Cleaning up.');
            await _cleanupWithoutFrames(); return;
          }
          final newBuffer = Uint8List(buffer.length + chunk.length);
          newBuffer.setAll(0, buffer);
          newBuffer.setAll(buffer.length, chunk);
          buffer = newBuffer;
          
          _log.fine('$_logPrefix 🔧 [YAMUX-FRAME-READER-BODY-PROGRESS-$frameCount] Body buffer now has ${buffer.length}/$expectedTotalFrameLength bytes');
        }

        _log.fine('$_logPrefix 🔧 [YAMUX-FRAME-READER-PARSE-$frameCount] Full frame received, parsing frame from ${expectedTotalFrameLength} bytes');
        
        final frameBytesForParser = buffer.sublist(0, expectedTotalFrameLength);
        final parseStartTime = DateTime.now();
        final frame = YamuxFrame.fromBytes(frameBytesForParser);
        final parseDuration = DateTime.now().difference(parseStartTime);
        

        _log.fine('$_logPrefix 🔧 [YAMUX-FRAME-READER-RAW-$frameCount] Raw frame bytes (${frameBytesForParser.length}): ${frameBytesForParser.take(64)}...');
        
        if (frame.length != bodyLength) {
            _log.severe("$_logPrefix 🔧 [YAMUX-FRAME-READER-ERROR-$frameCount] Frame body length mismatch! Header said $bodyLength, frame parser said ${frame.length}. Frame: ${frame.type}, StreamID: ${frame.streamId}, Flags: ${frame.flags}");
            await _goAway(YamuxCloseReason.protocolError);
            return; 
        }
        if (frame.data.length != bodyLength) { // Should be redundant if YamuxFrame.fromBytes is correct
            _log.severe("$_logPrefix 🔧 [YAMUX-FRAME-READER-ERROR-$frameCount] Frame data actual length mismatch! Header said bodyLength $bodyLength, frame.data.length is ${frame.data.length}. Frame: ${frame.type}, StreamID: ${frame.streamId}, Flags: ${frame.flags}");
             await _goAway(YamuxCloseReason.protocolError);
            return;
        }


        final handleStartTime = DateTime.now();
        
        try {
          await _handleFrame(frame);
          final handleDuration = DateTime.now().difference(handleStartTime);
          
          // Record frame processing time for adaptive behavior
          _recordFrameProcessingTime(handleDuration);

        } catch (e, st) {
          final handleDuration = DateTime.now().difference(handleStartTime);
          _log.severe('$_logPrefix 🔧 [YAMUX-FRAME-READER-HANDLE-ERROR-$frameCount] Frame handling failed after ${handleDuration.inMilliseconds}ms: $e\n$st');
          rethrow;
        }
        
        buffer = buffer.sublist(expectedTotalFrameLength);
        final loopDuration = DateTime.now().difference(loopStartTime);
        _logFrameProcessing('$_logPrefix 🔧 [YAMUX-FRAME-READER-LOOP-COMPLETE-$frameCount] Frame $frameCount processed in ${loopDuration.inMilliseconds}ms, buffer remaining: ${buffer.length} bytes');
      }
    } catch (e, st) {
      final bool connIsClosed = _connection.isClosed; // Capture current state
      if (!_closed && !connIsClosed) {
        _log.severe('$_logPrefix Error in _readFrames loop (session and conn not marked closed): $e', st);
        await _goAway(YamuxCloseReason.internalError);
      } else if (!_closed && connIsClosed) {
        _log.fine('$_logPrefix _readFrames: Underlying connection found closed, error during read: $e', st);
        await _cleanupWithoutFrames(); 
      } else { // _closed is true
        _log.fine('$_logPrefix _readFrames: Error after session already marked closed: $e', st);
      }
    } finally {
      if (!_closed) { 
        _log.warning('$_logPrefix _readFrames loop exited unexpectedly while session not marked closed. Forcing cleanup.');
        await _goAway(YamuxCloseReason.internalError); // This will also call _cleanupWithoutFrames
      }
      _log.fine('$_logPrefix _readFrames loop exited. Final state: _closed=$_closed, ConnClosed=${_connection.isClosed}');
    }
  }

  Future<void> _handleFrame(YamuxFrame frame) async {
    final handleStartTime = DateTime.now();
    _log.fine('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME] START: Type=${frame.type}, StreamID=${frame.streamId}, Flags=${frame.flags}, Length=${frame.length}, Session closed: $_closed');
    
    // If session is closing/closed, only process essential frames like GO_AWAY or RESETs for cleanup.
    if (_closed && frame.type != YamuxFrameType.goAway && frame.type != YamuxFrameType.reset) {
        _log.warning('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-SKIP] Session closed, ignoring frame type ${frame.type} for stream ${frame.streamId}');
        return;
    }

    try {
      // Fast path for common frame types to improve performance
      switch (frame.type) {
        case YamuxFrameType.dataFrame:
          await _handleDataFrame(frame);
          break;
        case YamuxFrameType.windowUpdate:
          await _handleWindowUpdateFrame(frame);
          break;
        case YamuxFrameType.newStream:
          await _handleNewStreamFrame(frame);
          break;
        case YamuxFrameType.reset:
          await _handleResetFrame(frame);
          break;
        case YamuxFrameType.ping:
          await _handlePing(frame);
          break;
        case YamuxFrameType.goAway:
          await _handleGoAway(frame);
          break;
        default:
          _log.severe('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-UNKNOWN] Unknown frame type: ${frame.type} for stream ${frame.streamId}');
          break;
      }
      
      final handleDuration = DateTime.now().difference(handleStartTime);
      _log.fine('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-SUCCESS] Frame handled successfully in ${handleDuration.inMilliseconds}ms: Type=${frame.type}, StreamID=${frame.streamId}');
      
    } catch (e, st) {
      final handleDuration = DateTime.now().difference(handleStartTime);
      _log.severe('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-ERROR] Error handling frame after ${handleDuration.inMilliseconds}ms: Type=${frame.type}, StreamID=${frame.streamId}, Error: $e\n$st');
      rethrow;
    }
  }

  /// Optimized handler for DATA frames (most common frame type)
  Future<void> _handleDataFrame(YamuxFrame frame) async {
    _log.fine('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-DATA] Processing DATA frame for stream ${frame.streamId}, length: ${frame.length}, flags: ${frame.flags}');
    
    // Notify activity on the underlying connection when data is received
    _connection.notifyActivity(); 
    final streamData = _streams[frame.streamId];
    if (streamData != null) {
      _log.fine('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-DATA-DISPATCH] Dispatching DATA frame to stream ${frame.streamId}, stream state: ${streamData.streamState}');
      
      final streamHandleStart = DateTime.now();
      await streamData.handleFrame(frame);
      final streamHandleDuration = DateTime.now().difference(streamHandleStart);
      _log.fine('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-DATA-COMPLETE] Stream ${frame.streamId} handled DATA frame in ${streamHandleDuration.inMilliseconds}ms');
    } else {
      _log.warning('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-DATA-ERROR] Received ${frame.type} for unknown/closed stream ID ${frame.streamId}. Flags: ${frame.flags}, Length: ${frame.length}');
      // If it's a DATA for a non-existent stream, it could be a protocol error.
      // Consider sending a RESET for this stream ID if it's unexpected data.
    }
  }

  /// Optimized handler for WINDOW_UPDATE frames (second most common)
  Future<void> _handleWindowUpdateFrame(YamuxFrame frame) async {
    _log.fine('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-WINDOW] Processing WINDOW_UPDATE frame for stream ${frame.streamId}');
    final stream = _streams[frame.streamId];
    if (stream != null) {
      _log.fine('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-WINDOW-DISPATCH] Dispatching WINDOW_UPDATE to stream ${frame.streamId}');
      await stream.handleFrame(frame);
      _log.fine('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-WINDOW-COMPLETE] Stream ${frame.streamId} handled WINDOW_UPDATE');
    } else {
      _log.warning('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-WINDOW-ERROR] Received ${frame.type} for unknown/closed stream ID ${frame.streamId}. Flags: ${frame.flags}, Length: ${frame.length}');
    }
  }

  /// Handler for NEW_STREAM frames
  Future<void> _handleNewStreamFrame(YamuxFrame frame) async {
    _log.fine('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-NEWSTREAM] Processing NEW_STREAM frame for stream ${frame.streamId}, flags: ${frame.flags}');

    if (frame.flags & YamuxFlags.syn != 0 && frame.flags & YamuxFlags.ack != 0) {
      _log.fine('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-SYN-ACK] Received SYN-ACK for outgoing stream ID ${frame.streamId}');
      final completer = _pendingStreams.remove(frame.streamId);
      if (completer != null && !completer.isCompleted) {
        completer.complete();
        _log.fine('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-SYN-ACK-COMPLETE] Completed pending stream completer for ID ${frame.streamId}');
      } else {
        _log.warning('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-SYN-ACK-ERROR] Received SYN-ACK for stream ID ${frame.streamId}, but no pending completer found or already completed.');
      }
    } else if (frame.flags & YamuxFlags.syn != 0) {
      _log.fine('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-SYN] Processing incoming SYN for stream ${frame.streamId}');
      await _handleNewStream(frame);
    } else {
      _log.warning('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-NEWSTREAM-ERROR] Received NEW_STREAM frame with unexpected flags: ${frame.flags} for stream ID ${frame.streamId}');
      // Consider sending GO_AWAY protocol error
    }
  }

  /// Handler for RESET frames
  Future<void> _handleResetFrame(YamuxFrame frame) async {
    _log.fine('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-RESET] Processing RESET frame for stream ${frame.streamId}');
    final stream = _streams[frame.streamId];
    if (stream != null) {
      _log.fine('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-RESET-DISPATCH] Dispatching RESET to stream ${frame.streamId}');
      await stream.handleFrame(frame);
      _log.fine('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-RESET-COMPLETE] Stream ${frame.streamId} handled RESET');
    } else {
      _log.fine('$_logPrefix 🔧 [YAMUX-HANDLE-FRAME-RESET-UNKNOWN] Received RESET for unknown/closed stream ID ${frame.streamId} (this is normal for cleanup)');
    }
  }

  Future<void> _handleNewStream(YamuxFrame frame) async { 
    // DEBUG: Add detailed inbound stream creation logging
    final caller = StackTrace.current.toString().split('\n').length > 1 
        ? StackTrace.current.toString().split('\n')[1].trim() 
        : 'unknown_caller';

    
    _log.fine('$_logPrefix _handleNewStream: START for incoming stream ID ${frame.streamId}. Flags: ${frame.flags}'); // Elevated log level
    if (frame.flags & YamuxFlags.syn == 0) { // Should be redundant due to earlier check in _handleFrame
      _log.severe('$_logPrefix New stream frame missing SYN flag for ID ${frame.streamId}');
      await _goAway(YamuxCloseReason.protocolError); return;
    }
    
    // YAMUX PROTOCOL COMPLIANCE: Validate incoming stream ID follows Yamux specification
    // Incoming streams from client should have odd IDs (1, 3, 5, ...)
    // Incoming streams from server should have even IDs (2, 4, 6, ...)
    final isIncomingFromClient = frame.streamId % 2 == 1;
    final weAreServer = !_isClient;

    if (isIncomingFromClient && !weAreServer) {
      // We're a client receiving an odd stream ID (client-initiated) - this is wrong
      _log.severe('$_logPrefix YAMUX PROTOCOL VIOLATION: Client received client-initiated stream ID ${frame.streamId}');
      await _goAway(YamuxCloseReason.protocolError);
      return;
    }

    if (!isIncomingFromClient && weAreServer) {
      // We're a server receiving an even stream ID (server-initiated) - this is wrong
      _log.severe('$_logPrefix YAMUX PROTOCOL VIOLATION: Server received server-initiated stream ID ${frame.streamId}');
      await _goAway(YamuxCloseReason.protocolError);
      return;
    }
    

    if (_closed || !canCreateStream) {
      _log.warning('$_logPrefix Cannot accept new stream ID ${frame.streamId}. Session closed: $_closed, Can create: $canCreateStream. Sending RESET.');
      final rstFrame = YamuxFrame.reset(frame.streamId);
      await _sendFrame(rstFrame).catchError((e) {
        _log.warning('$_logPrefix Error sending RESET for unaccepted stream ${frame.streamId}: $e');
      });
      return;
    }
    
    final ackFrame = YamuxFrame(
      type: YamuxFrameType.newStream,
      flags: YamuxFlags.syn | YamuxFlags.ack,
      streamId: frame.streamId,
      length: 0,
      data: Uint8List(0),
    );
    _log.fine('$_logPrefix _handleNewStream: Attempting to send SYN-ACK for stream ID ${frame.streamId}.'); // Elevated log level
    try {
      await _sendFrame(ackFrame); 
      _log.fine('$_logPrefix _handleNewStream: Successfully sent SYN-ACK for stream ID ${frame.streamId}.'); // Elevated log level
    } catch (e) {
      _log.severe('$_logPrefix _handleNewStream: FAILED to send SYN-ACK for stream ID ${frame.streamId}: $e. Aborting stream setup.'); // More specific message
      return; 
    }

    final initialWindow = _config.initialStreamWindowSize;
    _log.fine('$_logPrefix _handleNewStream: Creating local YamuxStream for ID ${frame.streamId}. Initial local receive window: $initialWindow'); // Elevated log level
    final stream = YamuxStream(
      id: frame.streamId,
      protocol: '', 
      metadata: {},
      initialWindowSize: initialWindow, 
      sendFrame: _sendFrame,
      parentConn: this, // Added parentConn
      logPrefix: "$_logPrefix StreamID=${frame.streamId}",
    );

    _streams[frame.streamId] = stream;
    
    // DEBUG: Add session-level stream tracking for inbound streams


    try {
      await stream.open(); 
      _log.fine('$_logPrefix _handleNewStream: Local YamuxStream ID ${frame.streamId} opened.'); // Elevated log level
      _log.fine('$_logPrefix _handleNewStream: Adding fully initialized stream ID ${frame.streamId} to _incomingStreamsController.'); // Elevated log level
      _incomingStreamsController.add(stream);

      if (_streamHandler != null) {
        _log.fine('$_logPrefix _handleNewStream: Invoking _streamHandler for stream ID ${frame.streamId}.'); // Elevated log level
        _streamHandler!(stream).catchError((e, st) { // Added stackTrace
          _log.severe('$_logPrefix _handleNewStream: Error in _streamHandler for stream ID ${frame.streamId}: $e', st); // More specific message
          stream.reset().catchError((_) {});
        });
      }
    } catch (e, st) { // Added stackTrace
      _log.severe('$_logPrefix _handleNewStream: Error during local stream open or handler setup for ID ${frame.streamId}: $e', st); // More specific message
      _streams.remove(frame.streamId);
      await stream.reset().catchError((_) {}); 
      // Do not rethrow here as it might kill the _readFrames loop unnecessarily if one stream handler fails.
    }
  }

  Future<void> _handlePing(YamuxFrame frame) async {
    final opaqueValue = frame.length; 
    if (frame.flags & YamuxFlags.ack != 0) { 
      _log.finer('$_logPrefix Received PONG (PING ACK), opaque: $opaqueValue');
      return;
    }
    _log.finer('$_logPrefix Received PING request, opaque: $opaqueValue. Sending PONG.');
    final response = YamuxFrame.ping(true, opaqueValue); 
    await _sendFrame(response);
  }

  Future<void> _handleGoAway(YamuxFrame frame) async {
    _log.fine('$_logPrefix Received GO_AWAY frame. Reason code: ${frame.length}. Closing session.');
    // The reason code from frame.length is an int. We need to map it to YamuxCloseReason or use a default.
    YamuxCloseReason reason;
    try {
      reason = YamuxCloseReason.values.firstWhere((r) => r.value == frame.length);
    } catch (_) {
      reason = YamuxCloseReason.protocolError; // Default if unknown code
    }
    await _goAway(reason); 
  }

  Future<void> _sendFrame(YamuxFrame frame) async {
    if (_closed && !_cleanupStarted) { // Allow sending GO_AWAY even if _closed is true but cleanup hasn't started
        if (frame.type != YamuxFrameType.goAway) {
             _log.warning('$_logPrefix Attempted to send frame (type ${frame.type}) on closed session. Allowed only for GO_AWAY.');
             throw StateError('Session is closing/closed, cannot send frame type ${frame.type}');
        }
    } else if (_closed && _cleanupStarted) {
        _log.warning('$_logPrefix Attempted to send frame (type ${frame.type}) during/after cleanup. Suppressing.');
        return; // Suppress send if cleanup fully started
    }

    try {
      _log.fine('$_logPrefix SEND: Type=${frame.type}, StreamID=${frame.streamId}, Flags=${frame.flags}, Length=${frame.length}');
      // Detailed logging for outgoing frames, especially Identify SYN
      if (frame.streamId == 1 && (frame.flags & YamuxFlags.syn != 0)) {
        final bytes = frame.toBytes();
        _log.warning('$_logPrefix SENDING IDENTIFY SYN (StreamID 1): Type=${frame.type}, Flags=0x${frame.flags.toRadixString(16).padLeft(2, '0')}, Length=${frame.length}, Bytes: $bytes');
      } else if (frame.type == YamuxFrameType.newStream && (frame.flags & YamuxFlags.syn != 0)) { // Log other SYN frames too for context
        final bytes = frame.toBytes();
        _log.fine('$_logPrefix SENDING SYN (StreamID ${frame.streamId}): Type=${frame.type}, Flags=0x${frame.flags.toRadixString(16).padLeft(2, '0')}, Length=${frame.length}, Bytes: $bytes');
      }
      await _connection.write(frame.toBytes());
    } catch (e) {
      _log.severe('$_logPrefix Error sending frame: Type=${frame.type}, StreamID=${frame.streamId}. Error: $e');
      if (!_closed) { // If not already closing due to this error, initiate closure.
        _log.warning('$_logPrefix Error sending frame indicates session issue. Initiating GO_AWAY. Error: $e.');
        // Don't await _goAway here to avoid potential deadlocks if _goAway itself tries to send.
        // The error will propagate up and likely cause _readFrames to terminate and cleanup.
        // Or, if this sendFrame was called from _goAway, the finally block there will handle cleanup.
      }
      rethrow; // Rethrow to allow caller to handle (e.g., stream reset)
    }
  }

  Future<void> _goAway(YamuxCloseReason reason) async {
    if (_closed && _cleanupStarted) {
      _log.fine('$_logPrefix _goAway(${reason.name}) called, but session already closed and cleanup started/finished.');
      return;
    }
    if (_closed && !_cleanupStarted) {
        _log.warning('$_logPrefix _goAway(${reason.name}) called when _closed=true but _cleanupStarted=false. Ensuring cleanup.');
        // _closed is true, so _sendFrame will only allow GO_AWAY if it's not already in cleanup.
        // This path implies _goAway might be called recursively or from different error paths.
        // The primary goal now is to ensure cleanup.
    } else {
       _closed = true; 
       _log.fine('$_logPrefix _goAway(${reason.name}): Attempting to send GO_AWAY. Session marked _closed=true.');
    }

    try {
      if (!_connection.isClosed && !_cleanupStarted) { // Only send if conn open and cleanup not started
        final frame = YamuxFrame.goAway(reason.value);
        await _sendFrame(frame); 
        _log.fine('$_logPrefix _goAway(${reason.name}): GO_AWAY frame send attempt complete.');
      } else {
        _log.fine('$_logPrefix _goAway(${reason.name}): Underlying connection closed or cleanup started. Skipping GO_AWAY frame send.');
      }
    } catch (e) {
      _log.warning('$_logPrefix _goAway(${reason.name}): Error occurred during _sendFrame for GO_AWAY: $e. Proceeding to cleanup.');
    } finally {
      await _cleanupWithoutFrames(); // This will set _cleanupStarted = true
      _log.fine('$_logPrefix _goAway(${reason.name}): Cleanup finished.');
    }
  }

  // This newStream() was for the Multiplexer interface, which no longer defines newStream().
  // It's superseded by MuxedConn.openStream(Context) and Conn.newStream(Context, int).
  // Future<P2PStream> newStream() async { 
  //   _log.finer('$_logPrefix YamuxSession.newStream (initiator path) CALLED.');
  //   if (_closed) {
  //     _log.warning('$_logPrefix newStream called on closed session.');
  //     throw StateError('Session is closed');
  //   }

  //   if (!canCreateStream) {
  //     _log.warning('$_logPrefix newStream: Maximum streams reached ($maxStreams).');
  //     throw StateError('Maximum streams reached');
  //   }

  //   final streamId = _nextStreamId;
  //   _nextStreamId += 2;
  //   _log.finer('$_logPrefix YamuxSession.newStream: Assigned streamId $streamId. Next will be $_nextStreamId.');

  //   final stream = YamuxStream(
  //     id: streamId,
  //     protocol: '', 
  //     metadata: {},
  //     initialWindowSize: _config.initialStreamWindowSize, 
  //     sendFrame: _sendFrame,
  //     parentConn: this, 
  //     logPrefix: "$_logPrefix StreamID=$streamId",
  //   );

  //   _streams[streamId] = stream;
  //   _log.finer('$_logPrefix YamuxSession.newStream: YamuxStream for ID $streamId instantiated and added to _streams map.');

  //   final completer = Completer<void>();
  //   _pendingStreams[streamId] = completer;
  //   _log.finer('$_logPrefix YamuxSession.newStream: Added pending stream completer for ID $streamId.');

  //   try {
  //     _log.finer('$_logPrefix YamuxSession.newStream: Sending SYN for stream ID $streamId.');
  //     final frame = YamuxFrame.newStream(streamId); 
  //     await _sendFrame(frame);
  //     _log.finer('$_logPrefix YamuxSession.newStream: _sendFrame for SYN on ID $streamId completed.');

  //     _log.finer('$_logPrefix YamuxSession.newStream: Waiting for SYN-ACK for stream ID $streamId (timeout: ${_config.streamWriteTimeout}).');
  //     await completer.future.timeout(_config.streamWriteTimeout);
  //     _log.finer('$_logPrefix YamuxSession.newStream: Received SYN-ACK for stream ID $streamId.');

  //     _log.finer('$_logPrefix YamuxSession.newStream: Calling stream.open() for ID $streamId.');
  //     await stream.open();
  //     _log.finer('$_logPrefix YamuxSession.newStream: Outgoing YamuxStream ID $streamId opened locally.');
  //     return stream;
  //   } catch (e) {
  //     _log.severe('$_logPrefix YamuxSession.newStream: Error opening new stream ID $streamId: $e');
  //     _pendingStreams.remove(streamId);
  //     _streams.remove(streamId); 
  //     _log.finer('$_logPrefix YamuxSession.newStream: Removed stream ID $streamId from _pendingStreams and _streams due to error.');
  //     if (e is TimeoutException) {
  //       await stream.reset().catchError((resetError) {
  //         _log.warning('$_logPrefix YamuxSession.newStream: Error resetting stream ID $streamId during newStream timeout handling: $resetError');
  //       });
  //     } else {
  //       await stream.forceReset().catchError((forceResetError) {
  //            _log.warning('$_logPrefix YamuxSession.newStream: Error force-resetting stream ID $streamId: $forceResetError');
  //       });
  //     }
  //     rethrow;
  //   }
  // }

  @override
  Future<core_mux.MuxedStream> openStream(Context context) async {
    _log.fine('$_logPrefix openStream: START for outgoing stream. Next Stream ID: $_nextStreamId. Context HashCode: ${context.hashCode}'); // Elevated log level
    // This is the actual logic for creating an outbound stream for Yamux.
    // The old newStream() (no-args) was essentially this.
    if (_closed) {
      _log.warning('$_logPrefix openStream called on closed session.');
      throw StateError('Session is closed');
    }

    if (!canCreateStream) {
      _log.warning('$_logPrefix newStream: Maximum streams reached ($maxStreams).');
      throw StateError('Maximum streams reached');
    }

    final streamId = _nextStreamId;
    _nextStreamId += 2;
    
    // YAMUX PROTOCOL COMPLIANCE: Validate stream ID assignment follows Yamux specification
    // Client should only create odd-numbered streams (1, 3, 5, ...)
    // Server should only create even-numbered streams (2, 4, 6, ...)
    if (_isClient && streamId % 2 == 0) {
      _log.severe('$_logPrefix YAMUX PROTOCOL VIOLATION: Client attempted to create even stream ID: $streamId');
      throw StateError('Yamux protocol violation: Client cannot create even stream ID: $streamId');
    }
    if (!_isClient && streamId % 2 == 1) {
      _log.severe('$_logPrefix YAMUX PROTOCOL VIOLATION: Server attempted to create odd stream ID: $streamId');
      throw StateError('Yamux protocol violation: Server cannot create odd stream ID: $streamId');
    }
    
    // DEBUG: Add detailed stream creation logging with caller info
    final caller = StackTrace.current.toString().split('\n').length > 1 
        ? StackTrace.current.toString().split('\n')[1].trim() 
        : 'unknown_caller';


    
    _log.finer('$_logPrefix YamuxSession.newStream: Assigned streamId $streamId. Next will be $_nextStreamId.');

    final stream = YamuxStream(
      id: streamId,
      protocol: '', 
      metadata: {},
      initialWindowSize: _config.initialStreamWindowSize, 
      sendFrame: _sendFrame,
      parentConn: this, // Added parentConn
      logPrefix: "$_logPrefix StreamID=$streamId",
    );

    _streams[streamId] = stream;
    
    // DEBUG: Add session-level stream tracking

    
    _log.finer('$_logPrefix YamuxSession.newStream: YamuxStream for ID $streamId instantiated and added to _streams map.');

    final completer = Completer<void>();
    _pendingStreams[streamId] = completer;
    _log.finer('$_logPrefix YamuxSession.newStream: Added pending stream completer for ID $streamId.');

    try {
      _log.fine('$_logPrefix openStream: Attempting to send SYN for new stream ID $streamId.'); // Elevated log level
      final frame = YamuxFrame.newStream(streamId);
      _log.fine('$_logPrefix openStream: Created Frame for SYN: Type=${frame.type}, StreamID=${frame.streamId}, Flags=${frame.flags}, Length=${frame.length}'); // ADDED LOG
      await _sendFrame(frame);
      _log.fine('$_logPrefix openStream: Successfully sent SYN for new stream ID $streamId.'); // Elevated log level

      _log.fine('$_logPrefix openStream: Waiting for SYN-ACK for stream ID $streamId (timeout: ${_config.streamWriteTimeout}).'); // Elevated log level
      await completer.future.timeout(_config.streamWriteTimeout);
      _log.fine('$_logPrefix openStream: Received SYN-ACK for stream ID $streamId.'); // Elevated log level

      _log.finer('$_logPrefix openStream: Calling stream.open() for ID $streamId.');
      await stream.open();
      _log.fine('$_logPrefix openStream: Outgoing YamuxStream ID $streamId opened locally.'); // Elevated log level
      return stream;
    } catch (e) {
      _log.severe('$_logPrefix openStream: FAILED to open new stream ID $streamId: $e'); // More specific message
      _pendingStreams.remove(streamId);
      _streams.remove(streamId); // Ensure stream is removed if setup fails
      _log.finer('$_logPrefix openStream: Removed stream ID $streamId from _pendingStreams and _streams due to error.');
      // Don't await reset if stream.open() failed, as stream might not be in a state to send reset.
      // Just ensure local cleanup of the stream object if it was partially initialized.
      // If _sendFrame for SYN failed, stream.reset() would also fail.
      // If timeout occurred, stream.reset() is appropriate.
      if (e is TimeoutException) {
        await stream.reset().catchError((resetError) {
          _log.warning('$_logPrefix openStream: Error resetting stream ID $streamId during newStream timeout handling: $resetError');
        });
      } else {
        // For other errors (e.g. _sendFrame failed), a simple local cleanup might be best.
        await stream.forceReset().catchError((forceResetError) {
             _log.warning('$_logPrefix openStream: Error force-resetting stream ID $streamId: $forceResetError');
        });
      }
      rethrow;
    }
  }

  @override
  Future<YamuxStream> acceptStream() async {
    // Changed from AND to OR - if either is closed, we can't accept
    if (_closed || _incomingStreamsController.isClosed) {
        throw StateError('Session is closed, cannot accept new streams.');
    }
    
    try {
      final p2pStream = await incomingStreams.first;
      if (p2pStream is YamuxStream) {
        return p2pStream;
      } else {
        throw StateError('Incoming stream is not a YamuxStream, which is unexpected.');
      }
    } on StateError {
      // Handle the case where the stream was closed during the await
      if (_closed || _incomingStreamsController.isClosed) {
        throw StateError('Session closed while waiting for stream');
      }
      // If it's a different StateError (like "not a YamuxStream"), rethrow it
      rethrow;
    }
  }

  @override
  Stream<P2PStream> get incomingStreams => _incomingStreamsController.stream;

  @override
  Future<void> close() async {
    _log.fine('$_logPrefix close() called. Initial _closed state: $_closed, _cleanupStarted: $_cleanupStarted');
    if (_closed && _cleanupStarted) {
      _log.fine('$_logPrefix close(): Session already closed and cleanup started/finished.');
      return;
    }
    await _goAway(YamuxCloseReason.normal);
    _log.fine('$_logPrefix close(): _goAway(normal) completed.');
  }

  @override
  bool get isClosed => _closed;

  @override
  int get maxStreams => _config.maxStreams;

  @override
  int get numStreams => _streams.length;

  @override
  bool get canCreateStream => numStreams < maxStreams;

  @override
  void setStreamHandler(Future<void> Function(P2PStream stream) handler) {
    _streamHandler = handler;
  }

  @override
  void removeStreamHandler() {
    _streamHandler = null;
  }

  Future<void> _cleanupWithoutFrames() async {
    if (_cleanupStarted) {
      _log.fine('$_logPrefix _cleanupWithoutFrames: Cleanup already started or completed.');
      return;
    }
    _cleanupStarted = true; // Set flag at the beginning
    _closed = true; 
    _log.fine('$_logPrefix _cleanupWithoutFrames: Starting cleanup. _closed=true, _cleanupStarted=true.');

    _keepaliveTimer?.cancel();
    _log.finer('$_logPrefix _cleanupWithoutFrames: Keepalive timer cancelled.');

    // Fail any pending outgoing streams
    _pendingStreams.forEach((id, completer) {
        if (!completer.isCompleted) {
            _log.finer('$_logPrefix _cleanupWithoutFrames: Failing pending stream ID $id.');
            completer.completeError(StateError('Session closed while opening stream $id'));
        }
    });
    _pendingStreams.clear();

    final activeStreams = List<YamuxStream>.from(_streams.values); 
    _streams.clear(); 
    _log.finer('$_logPrefix _cleanupWithoutFrames: Active streams map cleared. Processing ${activeStreams.length} streams for reset.');
    for (final stream in activeStreams) {
      try {
        _log.finer('$_logPrefix _cleanupWithoutFrames: Forcibly resetting stream ${stream.id()}.');
        await stream.forceReset(); 
      } catch (e) {
        _log.warning('$_logPrefix _cleanupWithoutFrames: Error force-resetting stream ${stream.id()}: $e');
      }
    }

    try {
      if (!_incomingStreamsController.isClosed) {
        await _incomingStreamsController.close();
        _log.finer('$_logPrefix _cleanupWithoutFrames: Incoming streams controller closed.');
      }
    } catch (e) {
      _log.warning('$_logPrefix _cleanupWithoutFrames: Error closing incoming streams controller: $e');
    }

    try {
      if (!_connection.isClosed) {
        await _connection.close();
        _log.finer('$_logPrefix _cleanupWithoutFrames: Underlying connection closed.');
      }
    } catch (e) {
      _log.warning('$_logPrefix _cleanupWithoutFrames: Error closing underlying connection: $e');
    }
    _log.fine('$_logPrefix _cleanupWithoutFrames: Cleanup finished.');
  }

  @override
  Future<core_mux.MuxedConn> newConnOnTransport(
    TransportConn secureConnection, 
    bool isServer,                 
    PeerScope scope
  ) async {
    if (secureConnection != this._connection) {
      _log.warning('YamuxSession.newConnOnTransport: secureConnection mismatch. Expected ${_connection.id}, got ${secureConnection.id}');
    }
    if (isServer == this._isClient) { // isServer from perspective of Multiplexer interface
      _log.warning('YamuxSession.newConnOnTransport: isServer flag mismatch. Expected isServer=${!_isClient}, got $isServer');
    }

    this._peerScope = scope; 
    await _initCompleter.future;
    return this;
  }

  // Conn interface implementation
  @override
  String get id => _connection.id;

  // Conn.newStream signature: Future<P2PStream> newStream(Context context, int streamId);
  // This implements Conn.newStream by calling the MuxedConn.openStream method.
  @override
  Future<P2PStream> newStream(Context context) async {
    return await openStream(context) as P2PStream; // openStream returns MuxedStream, cast to P2PStream
  }

  // This `streams` getter satisfies both Multiplexer.streams (now Future) and Conn.streams (Future).
  @override
  Future<List<P2PStream>> get streams async => List.unmodifiable(_streams.values);

  // isClosed is already implemented by MuxedConn and satisfies Conn.

  @override
  PeerId get localPeer => _connection.localPeer;

  @override
  PeerId get remotePeer => _connection.remotePeer;

  @override
  Future<PublicKey?> get remotePublicKey => _connection.remotePublicKey;

  @override
  ConnState get state {
    // Construct ConnState based on this session and underlying connection
    final underlyingState = _connection.state;
    return ConnState(
      streamMultiplexer: protocolId, // Yamux is the multiplexer
      security: underlyingState.security, // Get security from underlying conn
      transport: underlyingState.transport, // Get transport from underlying conn
      usedEarlyMuxerNegotiation: underlyingState.usedEarlyMuxerNegotiation, // Get from underlying
    );
  }

  @override
  MultiAddr get localMultiaddr => _connection.localMultiaddr;

  @override
  MultiAddr get remoteMultiaddr => _connection.remoteMultiaddr;

  @override
  ConnStats get stat => _connection.stat; // Assumes TransportConn provides a compatible ConnStats

  @override
  ConnScope get scope {
    // YamuxSession has its own _peerScope which might be more specific
    // or fall back to the underlying connection's scope.
    // The _peerScope is typically set via newConnOnTransport.
    if (_peerScope != null) {
      // This is tricky because PeerScope is not directly a ConnScope.
      // ConnScope is an interface with methods like IncRef, Done, etc.
      // PeerScope is a ResourceScope.
      // For now, if _peerScope is set, we might need to adapt it or
      // this indicates a mismatch in how scopes are handled at this level.
      // Let's assume for now that if _peerScope is available, it's the one to use,
      // but this might need a more robust adapter if ConnScope has methods not on PeerScope.
      // A simpler approach: ConnScope is about managing the connection's lifecycle within rcmgr.
      // The YamuxSession itself is scoped.
      // The _connection (TransportConn) should have its own scope.
      return _connection.scope; 
    }
    return _connection.scope;
  }
}
