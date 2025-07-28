import 'dart:async';
import 'dart:math'; // Added import for Random
import 'dart:typed_data';
import 'dart:io' show SocketException, InternetAddress, InternetAddressType, Socket, RawDatagramSocket; // For specific error types and network classes

import 'package:dart_libp2p/p2p/transport/udx_stream_adapter.dart';
import 'package:dart_libp2p/p2p/transport/udx_exceptions.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:logging/logging.dart';

import 'package:meta/meta.dart';

import '../../core/connmgr/conn_manager.dart'; // For ConnManager class
import '../../p2p/transport/connection_state.dart'; // Correct import for ConnectionState enum

import '../../core/multiaddr.dart';
import '../../core/network/conn.dart' show Conn, ConnStats, ConnState, Stats; // Added Stats
import '../../core/network/transport_conn.dart';
import '../../core/network/stream.dart' show P2PStream, StreamStats;
import '../../core/network/rcmgr.dart' show ConnScope, StreamScope;
import '../../core/network/context.dart' show Context;
import '../../core/network/mux.dart' show MuxedConn, MuxedStream;
import '../../core/peer/peer_id.dart' show PeerId;
import '../../core/crypto/keys.dart';
import '../../core/network/common.dart' show Direction;

import 'listener.dart';
import 'transport.dart';
import 'transport_config.dart';


final Logger _logger = Logger('UDXTransport');

/// UDX implementation of the Transport interface using dart_udx
/// This implementation treats UDX as a multiplexing transport.
class UDXTransport implements Transport {
  static const _supportedProtocols = ['/ip4/udp/udx', '/ip6/udp/udx'];

  @override
  final TransportConfig config;
  final ConnManager _connManager;
  final UDX _udxInstance;
  final List<Listener> _activeListeners = [];
  final Set<UDXSessionConn> _activeDialerConns = {};
  // static int _nextDialStreamIdPairBase = 1; // Removed static counter

  @visibleForTesting
  ConnManager get connectionManager => _connManager;

  UDXTransport({
    TransportConfig? config,
    required ConnManager connManager,
    UDX? udxInstance,
  }) : config = config ?? TransportConfig.defaultConfig,
       _connManager = connManager,
       _udxInstance = udxInstance ?? UDX() {
    _logger.fine('[UDXTransport] Initialized with config: $config. UDX instance created.');
    // Removed problematic dynamic calls to _udxInstance.init() and .start()
    // as the UDX class from dart_udx package does not have these methods.
    // The UDX instance is ready after construction.
  }

  @override
  Future<TransportConn> dial(MultiAddr addr, {Duration? timeout}) async {
    _logger.fine('[UDXTransport.dial] Attempting to dial $addr with timeout: ${timeout ?? config.dialTimeout}');
    final host = addr.valueForProtocol('ip4') ?? addr.valueForProtocol('ip6');
    final port = int.parse(addr.valueForProtocol('udp') ?? '0');

    if (host == null || port == 0) {
      throw ArgumentError('Invalid UDX multiaddr for dialing: $addr');
    }

    final effectiveTimeout = timeout ?? config.dialTimeout;
    
    // Use UDX exception handler with retry logic for the entire dial operation
    return await UDXExceptionHandler.handleUDXOperation(
      () => _performDial(addr, host, port, effectiveTimeout),
      'UDXTransport.dial($addr)',
      retryConfig: UDXRetryConfig.regular,
    );
  }

  /// Performs the actual dial operation with comprehensive resource cleanup
  Future<TransportConn> _performDial(
    MultiAddr addr, 
    String host, 
    int port, 
    Duration effectiveTimeout,
  ) async {
    RawDatagramSocket? rawSocket;
    UDXMultiplexer? multiplexer;
    UDPSocket? udpSocket;
    UDXStream? initialStream;
    
    try {
      _logger.fine('[UDXTransport._performDial] Creating RawDatagramSocket for $host');
      
      // Create raw UDP socket and bind it with UDX exception handling
      final isIPv6 = UDX.getAddressFamily(host) == 6;
      rawSocket = await UDXExceptionHandler.handleUDXOperation(
        () => RawDatagramSocket.bind(
          isIPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4, 
          0
        ),
        'RawDatagramSocket.bind($host)',
      );
      _logger.fine('[UDXTransport._performDial] RawDatagramSocket bound to: ${rawSocket!.address.address}:${rawSocket!.port}');

      // Create multiplexer with exception handling
      multiplexer = await UDXExceptionHandler.handleUDXOperation(
        () async => UDXMultiplexer(rawSocket!),
        'UDXMultiplexer.create',
      );
      _logger.fine('[UDXTransport._performDial] UDXMultiplexer created');

      // Create UDPSocket through multiplexer with exception handling
      udpSocket = await UDXExceptionHandler.handleUDXOperation(
        () async => multiplexer!.createSocket(_udxInstance, host, port),
        'UDXMultiplexer.createSocket($host:$port)',
      );
      _logger.fine('[UDXTransport._performDial] UDPSocket created through multiplexer');

      // Generate random unique stream IDs for this dial attempt
      final random = Random();
      final int localInitialStreamId = random.nextInt(0xFFFFFFFF) + 1; // Ensure non-zero
      int remoteInitialStreamId = random.nextInt(0xFFFFFFFF) + 1;
      while (remoteInitialStreamId == localInitialStreamId) { // Ensure they are different
        remoteInitialStreamId = random.nextInt(0xFFFFFFFF) + 1;
      }

      _logger.fine('[UDXTransport._performDial] Generated UDX Stream IDs - Local: $localInitialStreamId, Remote: $remoteInitialStreamId');

      // Create initial stream to trigger handshake with timeout and exception handling
      _logger.fine('[UDXTransport._performDial] Creating outgoing UDXStream to $host:$port (localId: $localInitialStreamId, remoteId: $remoteInitialStreamId)');
      initialStream = await UDXExceptionHandler.handleUDXOperation(
        () => UDXExceptionUtils.withTimeout(
          UDXStream.createOutgoing(
            _udxInstance,
            udpSocket!,
            localInitialStreamId,
            remoteInitialStreamId,
            host,
            port,
          ),
          effectiveTimeout,
          'UDXStream.createOutgoing($host:$port)',
        ),
        'UDXStream.createOutgoing($host:$port)',
      );
      _logger.fine('[UDXTransport._performDial] Outgoing UDXStream created: ${initialStream!.id}');

      // Phase 1.2: UDX Socket Health Monitoring - Handshake timing
      _logger.fine('[UDXTransport._performDial] Handshake start for $host:$port');
      final handshakeStart = DateTime.now();
      await UDXExceptionHandler.handleUDXOperation(
        () => UDXExceptionUtils.withTimeout(
          udpSocket!.handshakeComplete,
          effectiveTimeout,
          'UDPSocket.handshakeComplete($host:$port)',
        ),
        'UDPSocket.handshakeComplete($host:$port)',
      );
      final handshakeDuration = DateTime.now().difference(handshakeStart);
      _logger.fine('[UDXTransport._performDial] Handshake completed for $host:$port, duration: ${handshakeDuration.inMilliseconds}ms');

      final localMa = MultiAddr('/ip4/${rawSocket.address.address}/udp/${rawSocket.port}/udx');
      final remoteMa = addr;

      _logger.fine('[UDXTransport._performDial] Creating UDXSessionConn for $addr. Local: $localMa, Remote: $remoteMa');
      final sessionConn = UDXSessionConn(
        udpSocket: udpSocket!,
        initialStream: initialStream!,
        localMultiaddr: localMa,
        remoteMultiaddr: remoteMa,
        transport: this,
        connManager: _connManager,
        isDialer: true,
        onClosed: (conn) {
          _activeDialerConns.remove(conn);
          _logger.fine('[UDXTransport._performDial] Dialer connection ${conn.id} closed and removed from active set.');
        },
      );
      _connManager.registerConnection(sessionConn); 
      _activeDialerConns.add(sessionConn); 
      _logger.fine('[UDXTransport._performDial] UDXSessionConn created, registered, and tracked successfully for $addr. ID: ${sessionConn.id}');
      return sessionConn;

    } catch (error) {
      _logger.warning('[UDXTransport._performDial] Error during dial to $addr: $error. Performing cleanup.');
      
      // Comprehensive resource cleanup using UDXExceptionUtils
      await UDXExceptionUtils.safeCloseAll({
        'initialStream': () async => await initialStream?.close(),
        'multiplexer': () async => multiplexer?.close(),
      });
      
      rethrow; // Let UDXExceptionHandler handle the retry logic
    }
  }

  @override
  Future<Listener> listen(MultiAddr addr) async {
    _logger.fine('[UDXTransport.listen] Attempting to listen on $addr');
    final host = addr.valueForProtocol('ip4') ?? addr.valueForProtocol('ip6');
    final port = int.parse(addr.valueForProtocol('udp') ?? '0');

    if (host == null) {
      throw ArgumentError('Invalid UDX multiaddr for listening: $addr');
    }
    
    RawDatagramSocket? rawSocket;
    UDXMultiplexer? multiplexer;
    try {
      _logger.fine('[UDXTransport.listen] Creating RawDatagramSocket for $host:$port');
      
      // Create raw UDP socket and bind it
      final isIPv6 = UDX.getAddressFamily(host) == 6;
      final bindAddress = host == '0.0.0.0' ? InternetAddress.anyIPv4 :
                         host == '::' ? InternetAddress.anyIPv6 :
                         InternetAddress(host);
      
      rawSocket = await RawDatagramSocket.bind(bindAddress, port);
      _logger.fine('[UDXTransport.listen] RawDatagramSocket bound to: ${rawSocket.address.address}:${rawSocket.port}');

      // Create multiplexer
      multiplexer = UDXMultiplexer(rawSocket);
      _logger.fine('[UDXTransport.listen] UDXMultiplexer created');

      final boundMa = MultiAddr('/ip4/${rawSocket.address.address}/udp/${rawSocket.port}/udx');
      _logger.fine('[UDXTransport.listen] Creating UDXListener for $boundMa');
      final listener = UDXListener(
        listeningSocket: multiplexer,
        udxInstance: _udxInstance,
        boundAddr: boundMa,
        transport: this,
        connManager: _connManager,
        sessionConnFactory: UDXSessionConn.new,
      );

      _activeListeners.add(listener); 
      _logger.fine('[UDXTransport.listen] UDXListener created successfully for $boundMa and added to active listeners.');
      return listener;
    } catch (e) {
      _logger.fine('[UDXTransport.listen] Exception during listen on $addr: $e. Cleaning up.');
      multiplexer?.close();
      throw Exception('Failed to listen on UDX address $addr: $e');
    }
  }

  @override
  List<String> get protocols => _supportedProtocols;

  @override
  bool canDial(MultiAddr addr) {
    return addr.hasProtocol('udx') && 
           (addr.hasProtocol('ip4') || addr.hasProtocol('ip6')) &&
           addr.hasProtocol('udp');
  }

  @override
  bool canListen(MultiAddr addr) {
    return canDial(addr);
  }

  @override
  Future<void> dispose() async {
    _logger.fine('[UDXTransport.dispose] Disposing UDXTransport. Closing ${_activeListeners.length} active listeners and ${_activeDialerConns.length} active dialer connections.');
    
    for (final listener in _activeListeners.toList()) { 
      try {
        await listener.close();
      } catch (e) {
        _logger.fine('[UDXTransport.dispose] Error closing listener ${listener.addr}: $e');
      }
    }
    _activeListeners.clear();
    _logger.fine('[UDXTransport.dispose] All active listeners closed and cleared.');

    for (final conn in _activeDialerConns.toList()) { 
      try {
        await conn.close();
      } catch (e) {
        _logger.fine('[UDXTransport.dispose] Error closing dialer connection ${conn.id}: $e');
      }
    }
    _activeDialerConns.clear();
    _logger.fine('[UDXTransport.dispose] All active dialer connections closed and cleared.');
  }
}

class UDXSessionConn implements MuxedConn, TransportConn {
  final UDPSocket _udpSocket;
  final UDXStream _initialStream; 
  final MultiAddr _localMultiaddr;
  final MultiAddr _remoteMultiaddr;
  final UDXTransport _transport;
  final ConnManager _connManager;
  final bool _isDialer;
  final void Function(UDXSessionConn conn)? _onClosedCallback;
  final DateTime _openedAt; // Added to store connection opening time

  PeerId? _localPeer;
  PeerId? _remotePeer;
  PublicKey? _remotePublicKey;
  String _securityProtocol = '';

  bool _isClosing = false; 
  bool _isClosed = false;
  final Completer<void> _closedCompleter = Completer<void>();
  final StreamController<MuxedStream> _incomingStreamsController = StreamController<MuxedStream>.broadcast();
  
  final Map<int, UDXP2PStreamAdapter> _activeStreams = {};
  StreamSubscription? _socketMessageSubscription;
  StreamSubscription? _initialStreamCloseSubscription;
  
  late int _nextOwnStreamId; 
  late int _nextExpectedRemoteStreamId; 

  @override
  final String id;

  late final UDXP2PStreamAdapter initialP2PStream;

  UDXSessionConn({
    required UDPSocket udpSocket,
    required UDXStream initialStream,
    required MultiAddr localMultiaddr,
    required MultiAddr remoteMultiaddr,
    required UDXTransport transport,
    required ConnManager connManager,
    PeerId? localPeer,
    required bool isDialer,
    void Function(UDXSessionConn conn)? onClosed,
  }) : _udpSocket = udpSocket,
       _initialStream = initialStream,
       _localMultiaddr = localMultiaddr,
       _remoteMultiaddr = remoteMultiaddr,
       _transport = transport,
       _connManager = connManager,
       _localPeer = localPeer,
       _isDialer = isDialer,
       _onClosedCallback = onClosed,
       _openedAt = DateTime.now(), // Initialize _openedAt
       id = 'udx-${DateTime.now().millisecondsSinceEpoch}-${localMultiaddr.hashCode ^ remoteMultiaddr.hashCode}' {
    // Phase 1.1: UDX Connection Lifecycle Analysis - Enhanced Constructor Logging
    _logger.fine('[UDXSessionConn $id] LIFECYCLE: Constructor start - isDialer=$_isDialer, local=$localMultiaddr, remote=$remoteMultiaddr');
    _logger.fine('[UDXSessionConn $id] LIFECYCLE: Initial stream ID=${initialStream.id}, UDPSocket created');
    _logger.fine('[UDXSessionConn $id] LIFECYCLE: Connection opened at $_openedAt');
    
    if (_isDialer) {
      _nextOwnStreamId = 3; 
      _nextExpectedRemoteStreamId = 4;
      _logger.fine('[UDXSessionConn $id] Dialer stream IDs initialized: nextOwn=$_nextOwnStreamId, nextExpectedRemote=$_nextExpectedRemoteStreamId');

      // Phase 1.2: UDX Socket Health Monitoring - Enhanced initial stream error monitoring
      _initialStream.on('error').listen((event) {
        final error = event.data;
        final timeSinceOpen = DateTime.now().difference(_openedAt);
        _logger.severe('[UDXSessionConn $id] INITIAL_STREAM_ERROR: ${error}, time_since_open: ${timeSinceOpen.inMilliseconds}ms');

        // Classify and handle the UDX error appropriately
        final classifiedException = UDXExceptionHandler.classifyUDXException(
          error, 
          'UDXSessionConn($id).initialStream.error', 
          StackTrace.current,
        );
        closeWithError(classifiedException);
      }, onError: (Object error, StackTrace stackTrace) {
        final timeSinceOpen = DateTime.now().difference(_openedAt);
        _logger.severe('[UDXSessionConn $id] INITIAL_STREAM_ERROR_HANDLER: $error, time_since_open: ${timeSinceOpen.inMilliseconds}ms');
        
        // Use UDX exception classification for comprehensive error handling
        final classifiedException = UDXExceptionHandler.classifyUDXException(
          error, 
          'UDXSessionConn($id).initialStream.onError', 
          stackTrace,
        );
        
        // Special handling for packet loss - this is a critical failure
        if (classifiedException is UDXPacketLossException) {
          _logger.warning('[UDXSessionConn $id] Packet permanently lost on initial stream. Connection failed.');
        }
        
        closeWithError(classifiedException, stackTrace);
      });

      // Phase 1.2: UDX Socket Health Monitoring - UDPSocket close monitoring
      _udpSocket.on('close').listen((event) {
        final timeSinceOpen = DateTime.now().difference(_openedAt);
        _logger.warning('[UDXSessionConn $id] UDP_SOCKET_CLOSED: reason=${event.data}, activeStreams=${_activeStreams.length}, time_since_open: ${timeSinceOpen.inMilliseconds}ms');
      });
    } else {
      _nextOwnStreamId = 1; 
      _nextExpectedRemoteStreamId = 2; 
      _logger.fine('[UDXSessionConn $id] Listener stream IDs initialized: nextOwn=$_nextOwnStreamId, nextExpectedRemote=$_nextExpectedRemoteStreamId');
    }

    _logger.fine('[UDXSessionConn $id] Subscribing to initialStream closeEvents.');
    _initialStreamCloseSubscription = _initialStream.closeEvents.listen(
      (_) {
        _logger.fine('[UDXSessionConn $id] Initial stream closed event. Closing session.');
        close(); 
      },
      onError: (err, s) { 
        _logger.fine('[UDXSessionConn $id] Initial stream error event: $err. Closing session with error.');
        closeWithError(err, s); 
      }
    );

    try {
      _logger.fine('[UDXSessionConn $id] Adapting initial stream ${_initialStream.id} to UDXP2PStreamAdapter.');
      final initialAdapter = UDXP2PStreamAdapter(
        udxStream: _initialStream,
        parentConn: this,
        direction: _isDialer ? Direction.outbound : Direction.inbound, 
      );
      _activeStreams[_initialStream.id] = initialAdapter;
      initialP2PStream = initialAdapter; 
      _logger.fine('[UDXSessionConn $id] Initial stream adapter created, stored, and assigned to initialP2PStream.');
    } catch (e, s) { 
      _logger.fine('[UDXSessionConn $id] Error adapting initial stream: $e. Closing session and rethrowing.');
      closeWithError(e, s); 
      rethrow; 
    }
    if (_isDialer) {
      _logger.fine('[UDXSessionConn $id] Dialer session, subscribing to its own UDPSocket unmatchedUDXPacket events.');
      _socketMessageSubscription = _udpSocket.on('unmatchedUDXPacket').listen(
        _handleDialerUnmatchedPacket,
        onError: (err, s) { 
          _logger.fine('[UDXSessionConn $id] (Dialer) error on UDPSocket: $err. Closing session.');
          closeWithError(err, s); 
        },
        onDone: () {
          _logger.fine('[UDXSessionConn $id] (Dialer) UDPSocket closed. Closing session.');
          close();
        },
      );
    }
  }

  void handleRemoteOpenedStream(UDXPacket packet, Uint8List rawData, InternetAddress remoteAddress, int remotePort) {
    _logger.fine('[UDXSessionConn $id] handleRemoteOpenedStream called by UDXListener. Packet for destId: ${packet.destinationStreamId}, srcId: ${packet.sourceStreamId}');
    if (_isClosed) {
      _logger.fine('[UDXSessionConn $id] Session closed, ignoring handleRemoteOpenedStream.');
      return;
    }
    try {
      final localId = packet.destinationStreamId;
      final remoteId = packet.sourceStreamId;

      _logger.fine('[UDXSessionConn $id] Creating incoming UDXStream for remote-opened stream. LocalId: $localId, RemoteId: $remoteId');
      final newRemoteStream = UDXStream.createIncoming(
        _transport._udxInstance,
        _udpSocket, 
        localId,
        remoteId,
        remoteAddress.address,
        remotePort,
        destinationCid: packet.destinationCid,
        sourceCid: packet.sourceCid,
      );
      _logger.fine('[UDXSessionConn $id] Incoming UDXStream created: ${newRemoteStream.id}');

      newRemoteStream.internalHandleSocketEvent({
        'data': rawData,
        'address': remoteAddress.address,
        'port': remotePort,
      });
      _logger.fine('[UDXSessionConn $id] Handled socket event for new incoming UDXStream ${newRemoteStream.id}');

      final adapter = UDXP2PStreamAdapter(
        udxStream: newRemoteStream,
        parentConn: this,
        direction: Direction.inbound,
      );
      _activeStreams[newRemoteStream.id] = adapter;
      _logger.fine('[UDXSessionConn $id] Adapted new incoming UDXStream ${newRemoteStream.id} and added to active streams.');
      if (!_incomingStreamsController.isClosed) {
        _incomingStreamsController.add(adapter);
        _logger.fine('[UDXSessionConn $id] Added new stream adapter ${adapter.id()} to incoming streams controller.');
      } else {
        _logger.fine('[UDXSessionConn $id] (Listener-Side): Incoming stream controller closed, closing new remote stream ${newRemoteStream.id}');
        adapter.close();
        _activeStreams.remove(newRemoteStream.id);
      }
    } catch (e, s) {
      _logger.fine('[UDXSessionConn $id] (Listener-Side): Error handling remote opened stream: $e\n$s');
    }
  }

  void _handleDialerUnmatchedPacket(dynamic event) { 
    _logger.fine('[UDXSessionConn $id] _handleDialerUnmatchedPacket called. Event: $event');
    if (_isClosed) {
      _logger.fine('[UDXSessionConn $id] Session closed, ignoring _handleDialerUnmatchedPacket.');
      return;
    }

    final eventPayload = event.data as Map<String, dynamic>;
    final packet = eventPayload['packet'] as UDXPacket;
    final remoteAddress = eventPayload['remoteAddress'] as InternetAddress;
    final remotePort = eventPayload['remotePort'] as int;
    final rawData = eventPayload['rawData'] as Uint8List;
    _logger.fine('[UDXSessionConn $id] Unmatched packet details: destId=${packet.destinationStreamId}, srcId=${packet.sourceStreamId}, from=${remoteAddress.address}:$remotePort');

    final expectedRemoteHost = _remoteMultiaddr.valueForProtocol(remoteAddress.type == InternetAddressType.IPv4 ? 'ip4' : 'ip6');
    final expectedRemotePort = int.parse(_remoteMultiaddr.valueForProtocol('udp')!);

    if (remoteAddress.address != expectedRemoteHost || remotePort != expectedRemotePort) {
      _logger.fine('[UDXSessionConn $id] (Dialer): Received unmatched packet from unexpected source ${remoteAddress.address}:$remotePort. Expected $expectedRemoteHost:$expectedRemotePort. Ignoring.');
      return;
    }
    
    try {
      final localId = packet.destinationStreamId;
      final remoteId = packet.sourceStreamId;
      _logger.fine('[UDXSessionConn $id] Creating incoming UDXStream for remote-opened stream on dialer session. LocalId: $localId, RemoteId: $remoteId');

      final newRemoteStream = UDXStream.createIncoming(
        _transport._udxInstance,
        _udpSocket, 
        localId,
        remoteId,
        remoteAddress.address,
        remotePort,
        destinationCid: packet.destinationCid,
        sourceCid: packet.sourceCid,
      );
      _logger.fine('[UDXSessionConn $id] Incoming UDXStream created on dialer session: ${newRemoteStream.id}');

      newRemoteStream.internalHandleSocketEvent({
        'data': rawData,
        'address': remoteAddress.address,
        'port': remotePort,
      });
      _logger.fine('[UDXSessionConn $id] Handled socket event for new incoming UDXStream ${newRemoteStream.id} on dialer session.');

      final adapter = UDXP2PStreamAdapter(
        udxStream: newRemoteStream,
        parentConn: this,
        direction: Direction.inbound,
      );
      _activeStreams[newRemoteStream.id] = adapter;
      _logger.fine('[UDXSessionConn $id] Adapted new incoming UDXStream ${newRemoteStream.id} on dialer session and added to active streams.');
      if (!_incomingStreamsController.isClosed) {
        _incomingStreamsController.add(adapter);
        _logger.fine('[UDXSessionConn $id] Added new stream adapter ${adapter.id()} to incoming streams controller on dialer session.');
      } else {
         _logger.fine('[UDXSessionConn $id] (Dialer): Incoming stream controller closed, closing new remote stream ${newRemoteStream.id}');
        adapter.close();
        _activeStreams.remove(newRemoteStream.id);
      }
    } catch (e, s) {
      _logger.fine('[UDXSessionConn $id] (Dialer): Error handling unmatched packet for new stream: $e\n$s');
    }
  }

  @override
  Future<MuxedStream> openStream(Context context) async {
    _logger.fine('[UDXSessionConn $id] openStream called.');
    if (_isClosed) {
      _logger.fine('[UDXSessionConn $id] Session closed, cannot open stream.');
      throw SocketException('UDX session is closed');
    }
    final localStreamId = _nextOwnStreamId;
    _nextOwnStreamId += 2;
    final remoteStreamId = _nextExpectedRemoteStreamId;
    _nextExpectedRemoteStreamId += 2;
    _logger.fine('[UDXSessionConn $id] Opening new stream. LocalId: $localStreamId, RemoteExpectedId: $remoteStreamId');

    final remoteHost = _remoteMultiaddr.valueForProtocol('ip4') ?? _remoteMultiaddr.valueForProtocol('ip6');
    final remotePort = int.parse(_remoteMultiaddr.valueForProtocol('udp') ?? '0');

    if (remoteHost == null || remotePort == 0) {
      _logger.fine('[UDXSessionConn $id] Remote address not set, cannot open stream.');
      throw StateError('Remote address not properly set for UDXSessionConn');
    }

    _logger.fine('[UDXSessionConn $id] Creating outgoing UDXStream to $remoteHost:$remotePort (localId: $localStreamId, remoteId: $remoteStreamId)');
    final udxStream = await UDXStream.createOutgoing(
      _transport._udxInstance,
      _udpSocket,
      localStreamId,
      remoteStreamId, 
      remoteHost, 
      remotePort,
      framed: true, 
    );
    _logger.fine('[UDXSessionConn $id] Outgoing UDXStream created: ${udxStream.id}');

    final muxedStream = UDXP2PStreamAdapter(
      udxStream: udxStream,
      parentConn: this,
      direction: Direction.outbound,
    );
    _activeStreams[udxStream.id] = muxedStream; 
    _logger.fine('[UDXSessionConn $id] New outgoing stream ${muxedStream.id()} adapted and stored.');
    return muxedStream;
  }

  @override
  Future<MuxedStream> acceptStream() async {
    _logger.fine('[UDXSessionConn $id] acceptStream called.');
    if (_isClosed && _incomingStreamsController.isClosed) {
       _logger.fine('[UDXSessionConn $id] Session closed, cannot accept new streams.');
       throw SocketException('UDX session is closed, cannot accept new streams.');
    }
    final stream = await _incomingStreamsController.stream.first;
    _logger.fine('[UDXSessionConn $id] Accepted stream: ${(stream as UDXP2PStreamAdapter).id()}');
    return stream;
  }
  
  @override
  Future<List<P2PStream>> get streams async => throw UnimplementedError("Use acceptStream() in a loop for MuxedConn.");

  @override
  MultiAddr get localMultiaddr => _localMultiaddr;

  @override
  MultiAddr get remoteMultiaddr => _remoteMultiaddr;

  @override
  PeerId get localPeer => _localPeer ?? (throw StateError("Local PeerId not set."));

  @override
  PeerId get remotePeer => _remotePeer ?? (throw StateError("Remote PeerId not set; established during security handshake."));
  
  void setRemotePeerDetails(PeerId peerId, PublicKey pubKey, String securityProto) {
    _remotePeer = peerId;
    _remotePublicKey = pubKey;
    _securityProtocol = securityProto;
  }

  @override
  Future<PublicKey?> get remotePublicKey async => _remotePublicKey;

  @override
  ConnState get state => ConnState( 
    streamMultiplexer: '/udx/1.0.0',
    security: _securityProtocol,
    transport: 'udx',
    usedEarlyMuxerNegotiation: false,
  );

  @override
  ConnStats get stat {
    final connStatsInstance = Stats(
      direction: _isDialer ? Direction.outbound : Direction.inbound,
      opened: _openedAt,
      limited: false, // Placeholder: UDXSessionConn doesn't have direct access to scope's limited status
      extra: {'transport': 'udx', 'security': _securityProtocol, 'muxer': '/udx/1.0.0'},
    );
    return _UDXConnStatsImpl(
      stats: connStatsInstance,
      numStreams: _activeStreams.length,
    );
  }

  @override
  ConnScope get scope => throw UnimplementedError("Scope not yet implemented for UDXSessionConn.");

  @override
  Future<P2PStream> newStream(Context context, [int? streamId]) async =>
    throw UnimplementedError("Use openStream(context) for UDXSessionConn, streamId is managed by UDX.");
  
  @override
  void setReadTimeout(Duration timeout) => throw UnimplementedError("Set timeouts on individual P2PStreams if supported.");

  @override
  void setWriteTimeout(Duration timeout) => throw UnimplementedError("Set timeouts on individual P2PStreams if supported.");
  
  @override
  Socket get socket => throw UnimplementedError("UDX connections operate over UDPSocket, not a direct dart:io.Socket.");

  @override
  Future<void> close() async {
    // Phase 1.3: Connection Resource Cleanup Analysis - Enhanced close logging
    final closeStart = DateTime.now();
    final timeSinceOpen = closeStart.difference(_openedAt);
    _logger.fine('[UDXSessionConn $id] CLOSE_START: Is already closed: $_isClosed, Is closing: $_isClosing, time_since_open: ${timeSinceOpen.inMilliseconds}ms');
    
    if (_isClosed || _isClosing) return;
    _isClosing = true;
    
    // Phase 1.1: UDX Connection Lifecycle Analysis - State change logging
    _logger.fine('[UDXSessionConn $id] STATE_CHANGE: open -> closing, reason: normal_close');
    _connManager.updateState(this, ConnectionState.closing, error: null); 

    // Phase 1.3: Resource cleanup order logging
    _logger.fine('[UDXSessionConn $id] CLEANUP_ORDER: 1. Cancelling socket and initial stream subscriptions');
    await _socketMessageSubscription?.cancel();
    _socketMessageSubscription = null;
    await _initialStreamCloseSubscription?.cancel();
    _initialStreamCloseSubscription = null;

    _logger.fine('[UDXSessionConn $id] CLEANUP_ORDER: 2. Closing incoming streams controller');
    if (!_incomingStreamsController.isClosed) {
      await _incomingStreamsController.close();
    }
    
    _logger.fine('[UDXSessionConn $id] CLEANUP_ORDER: 3. Closing all active streams (${_activeStreams.length} streams)');
    List<Future<void>> closeFutures = [];
    _activeStreams.values.toList().forEach((adapter) { 
      _logger.fine('[UDXSessionConn $id] Closing stream adapter ${adapter.id()}');
      closeFutures.add(adapter.close()); 
    });
    
    try {
      final streamCloseStart = DateTime.now();
      await Future.wait(closeFutures).catchError((e) {
        _logger.warning('[UDXSessionConn $id] Error closing one or more UDX streams: $e');
      });
      final streamCloseDuration = DateTime.now().difference(streamCloseStart);
      _logger.fine('[UDXSessionConn $id] CLEANUP_ORDER: All active streams closed in ${streamCloseDuration.inMilliseconds}ms');
      _activeStreams.clear(); 

      if (_isDialer) {
        _logger.fine('[UDXSessionConn $id] CLEANUP_ORDER: 4. Dialer session, closing its UDPSocket');
        final socketCloseStart = DateTime.now();
        await _udpSocket.close();
        final socketCloseDuration = DateTime.now().difference(socketCloseStart);
        _logger.fine('[UDXSessionConn $id] CLEANUP_ORDER: Dialer UDPSocket closed in ${socketCloseDuration.inMilliseconds}ms');
      }
    } catch (e) {
      _logger.warning('[UDXSessionConn $id] Error closing UDX resources for session $id: $e');
    }
    
    _isClosed = true;
    _isClosing = false;
    
    // Phase 1.1: UDX Connection Lifecycle Analysis - State change logging
    _logger.fine('[UDXSessionConn $id] STATE_CHANGE: closing -> closed, reason: cleanup_complete');
    _connManager.updateState(this, ConnectionState.closed, error: null); 
    _onClosedCallback?.call(this);

    if (!_closedCompleter.isCompleted) {
      _logger.fine('[UDXSessionConn $id] Completing close completer.');
      _closedCompleter.complete();
    }
    
    final totalCloseDuration = DateTime.now().difference(closeStart);
    _logger.fine('[UDXSessionConn $id] CLOSE_COMPLETE: Total close duration: ${totalCloseDuration.inMilliseconds}ms');
  }
  
  Future<void> closeWithError(dynamic error, [StackTrace? stackTrace]) async {
    _logger.fine('[UDXSessionConn $id] closeWithError called with error: $error');
    if (!_isClosed && !_isClosing) {
        _connManager.updateState(this, ConnectionState.closing, error: error); 
    }
    
    if (!_closedCompleter.isCompleted) {
        _logger.fine('[UDXSessionConn $id] Completing close completer with error: $error');
        _closedCompleter.completeError(error, stackTrace);
    }
    await close(); 
  }

  @override
  bool get isClosed {
    return _isClosed;
  }

  @override
  Future<void> get onClose => _closedCompleter.future;

  @override
  Future<Uint8List> read([int? length]) async {
    // For negotiation purposes, read from the initial stream.
    // The 'length' parameter for TransportConn.read is a suggestion,
    // P2PStream.read also takes an optional maxLength.
    _logger.fine('[UDXSessionConn $id] read() delegating to initialP2PStream.read(length: $length)');
    return initialP2PStream.read(length);
  }

  @override
  Future<void> write(Uint8List data) async {
    // For negotiation purposes, write to the initial stream.
    _logger.fine('[UDXSessionConn $id] write() delegating to initialP2PStream.write() data length: ${data.length}');
    return initialP2PStream.write(data);
  }

  @override
  Transport get transport => _transport;

  void notifyActivity() {
    if (!_isClosed && !_isClosing) {
      _connManager.recordActivity(this);
    }
  }
}

// Internal implementation of ConnStats for UDXSessionConn
class _UDXConnStatsImpl extends ConnStats {
  _UDXConnStatsImpl({
    required Stats stats,
    required int numStreams,
  }) : super(stats: stats, numStreams: numStreams);
}
