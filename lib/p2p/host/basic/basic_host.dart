import 'dart:async';
import 'dart:io' show NetworkInterface, InternetAddressType; // Added for NetworkInterface

import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/connmgr/conn_manager.dart';
import 'package:dart_libp2p/core/event/addrs.dart';
import 'package:dart_libp2p/core/event/bus.dart';
import 'package:dart_libp2p/core/event/protocol.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/network.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/core/protocol/protocol.dart';
import 'package:dart_libp2p/core/protocol/switch.dart';
import 'package:dart_libp2p/core/record/envelope.dart'; // Added for Envelope
import 'package:dart_libp2p/core/peer/record.dart' as peer_record; // Added for PeerRecord
import 'package:dart_libp2p/core/certified_addr_book.dart'; // Added for CertifiedAddrBook
import 'package:dart_libp2p/p2p/host/basic/natmgr.dart';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';

import 'package:dart_libp2p/core/host/host.dart' show AddrsFactory; // Import AddrsFactory
import 'package:dart_libp2p/p2p/protocol/multistream/multistream.dart';
import 'package:dart_libp2p/p2p/protocol/identify/id_service.dart'; // Added import
import 'package:dart_libp2p/p2p/protocol/identify/identify.dart';   // Added import
import 'package:dart_libp2p/p2p/protocol/identify/options.dart';  // Added import
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/notifiee.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'internal/backoff/backoff.dart';
import 'package:dart_libp2p/p2p/network/connmgr/null_conn_mgr.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart';
import 'package:dart_libp2p/config/config.dart'; // Added import for Config
import 'package:dart_libp2p/p2p/protocol/ping/ping.dart'; // Added for PingService
import 'package:dart_libp2p/p2p/host/relaysvc/relay_manager.dart'; // Added for RelayManager
import 'package:dart_libp2p/p2p/host/autonat/autonat.dart'; // Added for AutoNAT
import 'package:dart_libp2p/p2p/protocol/holepunch/holepunch_service.dart'; // Added for HolePunchService interface
import 'package:dart_libp2p/p2p/protocol/holepunch/service.dart' as holepunch_impl; // Added for HolePunchServiceImpl and Options
import 'package:dart_libp2p/p2p/protocol/holepunch/util.dart' show isRelayAddress; // Added for isRelayAddress
import 'package:dart_libp2p/p2p/transport/basic_upgrader.dart'; // Added for BasicUpgrader

final _log = Logger('basichost');

/// Default negotiation timeout
const Duration defaultNegotiationTimeout = Duration(seconds: 10);

/// Default addresses factory function.
/// Filters out loopback and unspecified addresses from the provided list.
List<MultiAddr> defaultAddrsFactory(List<MultiAddr> addrs) {
  return addrs.where((addr) {
    // Check for loopback
    if (addr.isLoopback()) {
      return false;
    }
    // Check for unspecified (0.0.0.0 or ::)
    final ip4Val = addr.valueForProtocol('ip4');
    final ip6Val = addr.valueForProtocol('ip6');
    if ((ip4Val == '0.0.0.0' || ip4Val == '0.0.0.0.0.0') || (ip6Val == '::' || ip6Val == '0:0:0:0:0:0:0:0')) {
      return false;
    }
    // Potentially add more filters here, e.g., for link-local, private IPs if desired by default.
    return true;
  }).toList();
}

// Removed AddrsFactory typedef as it's now imported

// Removed MockProtocolSwitch class definition

/// BasicHost is the basic implementation of the Host interface. This
/// particular host implementation:
///   - uses a protocol muxer to mux per-protocol streams
///   - uses an identity service to send + receive node information
///   - uses a nat service to establish NAT port mappings
class BasicHost implements Host {
  final _closeSync = Completer<void>();
  bool _closed = false;

  final Config _config; // Store the config instance
  final Network _network;
  final MultistreamMuxer _mux; // Using actual MultistreamMuxer
  late final IDService _idService; // Added IDService field
  NATManager? _natmgr; // Not final so it can be initialized in constructor
  final ConnManager _cmgr;
  final EventBus _eventBus;
  PingService? _pingService; // Added PingService field
  RelayManager? _relayManager; // Added RelayManager field
  AutoNAT? _autoNATService; // Added AutoNATService field
  HolePunchService? _holePunchService; // Added HolePunchService field
  late final BasicUpgrader _upgrader; // Added BasicUpgrader field

  // Event emitters
  Emitter? _evtLocalProtocolsUpdated;
  Emitter? _evtLocalAddrsUpdated;

  final AddrsFactory _addrsFactory;

  final Duration _negtimeout;

  late final StreamController<void> _addrChangeChan;

  final _addrMu = Lock();
  final ExpBackoff _updateLocalIPv4Backoff = ExpBackoff();
  final ExpBackoff _updateLocalIPv6Backoff = ExpBackoff();
  List<MultiAddr> _filteredInterfaceAddrs = [];
  List<MultiAddr> _allInterfaceAddrs = [];
  Timer? _addressMonitorTimer; // Added to store the timer

  /// Creates a new BasicHost with the given Network and Config.
  /// Use BasicHost.create() instead for proper async initialization.
  BasicHost._({
    required Network network,
    required Config config, // Changed to accept Config
  }) :
    _config = config, // Initialize _config
    _network = network,
    // TODO: Select muxer from config.muxers if populated and compatible.
    // For now, BasicHost directly uses MultistreamMuxer.
    // If config provides a specific MultistreamMuxer instance, it could be used.
    // This part needs further refinement on how Config.muxers (List<StreamMuxer>)
    // maps to the single MultistreamMuxer instance.
    // For simplicity, we'll assume a MultistreamMuxer might be passed via a new config field
    // or BasicHost continues to default. Let's assume config might have a direct muxer field later.
    // For now, keeping the direct instantiation or passed muxer logic.
    // This will be simplified to use config.muxer if available, or default.
    // Let's assume config.muxer is of type MultistreamMuxer? for now.
    // For now, BasicHost will manage its own MultistreamMuxer instance.
    // Config.muxers is for stream multiplexers (e.g., Yamux, Mplex), not the protocol muxer.
    _mux = MultistreamMuxer(),
    _negtimeout = config.negotiationTimeout ?? defaultNegotiationTimeout,
    _addrsFactory = config.addrsFactory ?? defaultAddrsFactory,
    _cmgr = config.connManager ?? NullConnMgr(),
    _eventBus = config.eventBus ?? BasicBus(),
    // Initialize _upgrader using the network's resourceManager
    // This assumes _network is already initialized and has its resourceManager.
    // Network (Swarm) is passed in, so its resourceManager should be accessible.
    _upgrader = BasicUpgrader(resourceManager: network.resourceManager) {

    // Initialize IDService using options from Config
    final identifyOpts = IdentifyOptions(
      userAgent: config.identifyUserAgent, // Use config.identifyUserAgent
      protocolVersion: config.identifyProtocolVersion, // Use config.identifyProtocolVersion
      disableSignedPeerRecord: config.disableSignedPeerRecord ?? false,
      disableObservedAddrManager: config.disableObservedAddrManager ?? false,
      // metricsTracer: config.identifyMetricsTracer, // If added to Config
    );
    _idService = IdentifyService(this, options: identifyOpts);
    _idService.start();

    // Initialize PingService if enabled in Config
    if (config.enablePing) {
      _pingService = PingService(this);
    }

    _addrChangeChan = StreamController<void>.broadcast();

    // Initialize event emitters
    _eventBus.emitter(EvtLocalProtocolsUpdated).then((emitter) {
      _evtLocalProtocolsUpdated = emitter;
    });

    _eventBus.emitter(EvtLocalAddressesUpdated).then((emitter) {
      _evtLocalAddrsUpdated = emitter;
    });

    // Initialize NAT manager if provided by config.natManagerFactory
    _natmgr = config.natManagerFactory != null ? config.natManagerFactory!(network) : null;

    // Set up stream handler
    _network.setStreamHandler("/libp2p/host", (dynamic stream, PeerId remotePeer) async {
      _newStreamHandler(stream as P2PStream);
    });

    // Set up network notifications for address changes
    _network.notify(_AddressChangeNotifiee(this));
    _log.fine('[BasicHost CONSTRUCTOR] for host ${id.toString()} - Initial _network.listenAddresses: ${_network.listenAddresses}');
  }

  /// Creates a new BasicHost with proper async initialization.
  /// This ensures interface addresses are available at startup.
  static Future<BasicHost> create({
    required Network network,
    required Config config,
  }) async {
    final host = BasicHost._(network: network, config: config);
    
    // Update local IP addresses with proper async handling
    await host._updateLocalIpAddr();
    
    return host;
  }

  /// Starts the host's background tasks.
  @override
  Future<void> start() async {
    _log.fine('[BasicHost start] BEGIN. Host ID: ${id.toString()}, network.hashCode: ${_network.hashCode}, initial network.listenAddresses: ${_network.listenAddresses}');
    _log.fine('[BasicHost start] Initial _config.listenAddrs: ${_config.listenAddrs}'); // Added log

    // If this host is configured with listen addresses, start listening on them.
    // Assuming _config.listenAddrs is List<MultiAddr> and defaults to empty list if not set.
    if (_config.listenAddrs.isNotEmpty) {
      _log.fine('[BasicHost start] Configured with listenAddrs: ${_config.listenAddrs}. Attempting to listen via _network.listen().');
      _log.fine('[BasicHost start] INVOKING _network.listen() with: ${_config.listenAddrs}'); // Added log
      try {
        await _network.listen(_config.listenAddrs);
        _log.fine('[BasicHost start] _network.listen() completed. Current network.listenAddresses: ${_network.listenAddresses}');
      } catch (e, s) {
        _log.severe('[BasicHost start] Error during _network.listen(): $e\n$s');
        // Rethrowing to indicate a fundamental setup issue.
        // Services depending on listen addresses might not function correctly.
        rethrow; 
      }
    } else {
      _log.fine('[BasicHost start] No listenAddrs configured in host config. Skipping explicit _network.listen() call from BasicHost.start().');
    }

    // Start IDService
    _log.fine('[BasicHost start] Before _idService.start. Current network.listenAddresses: ${_network.listenAddresses}');
    // await _idService.start();
    _log.fine('[BasicHost start] After _idService.start. Current network.listenAddresses: ${_network.listenAddresses}');

    // Persist a signed peer record for self to the peerstore if enabled.
    // This ensures that when IdentifyService requests our own record, it's available.
    if (!(_config.disableSignedPeerRecord ?? false)) {
      _log.fine('Attempting to create and persist self signed peer record.');
      if (peerStore.addrBook is CertifiedAddrBook) {
        final cab = peerStore.addrBook as CertifiedAddrBook;
        final selfId = id; // Host's own PeerId
        final privKey = await peerStore.keyBook.privKey(selfId);

        if (privKey == null) {
          _log.fine('Unable to access host private key for selfId $selfId; cannot create self signed record.');
        } else {
          final currentAddrs = addrs; // Uses the host's addrs getter, which should be up-to-date
          if (currentAddrs.isEmpty) {
            _log.fine('Host has no addresses at the moment of self-record creation; record will reflect this.');
          }
          
          try {
            // Create PeerRecord payload
            // Note: The actual structure of PeerRecord and how it's created from AddrInfo
            // or directly might differ slightly from Go. This assumes a Dart equivalent.
            // The key is to get PeerId, sequence number, and addresses into a signable format.
            final recordPayload = peer_record.PeerRecord(
              peerId: selfId, // Corrected: expects PeerId object
              seq: DateTime.now().millisecondsSinceEpoch, // Using timestamp for sequence number
              addrs: currentAddrs, // Corrected: expects List<MultiAddr> and param name is 'addrs'
            );
            
            // Create and sign the Envelope
            // Envelope.seal should handle marshalling the recordPayload and signing
            final envelope = await Envelope.seal(recordPayload, privKey);

            if (envelope != null) {
              await cab.consumePeerRecord(envelope, AddressTTL.permanentAddrTTL);
              _log.fine('Successfully created and persisted self signed peer record to peerstore.');
            } else {
              _log.fine('Failed to create or seal self signed peer record envelope (seal returned null).');
            }
          } catch (e, s) {
            _log.severe('Error creating or persisting self signed peer record: $e\n$s');
          }
        }
      } else {
        _log.fine('Peerstore AddrBook is not a CertifiedAddrBook; cannot persist self signed record.');
      }
    }

    // PingService is started implicitly by its constructor registering a handler.

    // Initialize RelayManager if enabled
    if (_config.enableRelay) {
      _log.fine('[BasicHost start] Before RelayManager.create. network.hashCode: ${_network.hashCode}, network.listenAddresses: ${_network.listenAddresses}');
      _relayManager = await RelayManager.create(this);
      _log.fine('[BasicHost start] After RelayManager.create. network.hashCode: ${_network.hashCode}, network.listenAddresses: ${_network.listenAddresses}');
      // RelayManager starts its own background tasks on creation.
      _log.fine('RelayManager created and service monitoring started.');
    }

    // Initialize AutoNATService if enabled
    if (_config.enableAutoNAT) {
      _log.fine('[BasicHost start] Before newAutoNAT. network.hashCode: ${_network.hashCode}, network.listenAddresses: ${_network.listenAddresses}');
      // For now, using default options for AutoNAT.
      // More specific options can be plumbed through Config if needed.
      _autoNATService = await newAutoNAT(this, [
        // Example: autonat_options.withScheduleDelay(Duration(seconds: 15)),
        // autonat_options.withBootDelay(Duration(seconds: 5)),
      ]);
      _log.fine('[BasicHost start] After newAutoNAT. network.hashCode: ${_network.hashCode}, network.listenAddresses: ${_network.listenAddresses}');
      _log.fine('AutoNAT service created and started.');
    }

    // Initialize HolePunchService if enabled
    if (_config.enableHolePunching) {
      _log.fine('[BasicHost start] Before _holePunchService.start. network.hashCode: ${_network.hashCode}, network.listenAddresses: ${_network.listenAddresses}');
      _holePunchService = holepunch_impl.HolePunchServiceImpl(
        this,
        _idService, // Pass the existing IDService instance
        () => publicAddrs, // Pass a function that returns only public/observed addrs
        options: const holepunch_impl.HolePunchOptions(), // Default options for now
      );
      await _holePunchService!.start(); // Call start as per its interface
      _log.fine('[BasicHost start] After _holePunchService.start. network.hashCode: ${_network.hashCode}, network.listenAddresses: ${_network.listenAddresses}');
      _log.fine('HolePunch service started.');
    }
    
    _log.fine('[BasicHost start] Before calling _startBackground. network.hashCode: ${_network.hashCode}, network.listenAddresses: ${_network.listenAddresses}');
    // Start other background tasks
    return await _startBackground();
  }

  Future<void> _startBackground() async {
    // Start background address change monitoring
    // Note: IdentifyService also listens to address/protocol changes.
    return await _monitorAddressChanges();
  }

  /// Emits an address change event when the host's addresses change.
  void _emitAddressChangeEvent(List<MultiAddr> prev, List<MultiAddr> current) async {
    if (prev.isEmpty && current.isEmpty) return;

    // Create maps for easier comparison
    final prevMap = <String, MultiAddr>{};
    final currMap = <String, MultiAddr>{};

    for (final addr in prev) {
      prevMap[addr.toString()] = addr;
    }

    for (final addr in current) {
      currMap[addr.toString()] = addr;
    }

    // Create lists for the event
    final currentAddrs = <UpdatedAddress>[];
    final removedAddrs = <UpdatedAddress>[];
    var addrsAdded = false;

    // Check for added or maintained addresses
    for (final addr in currMap.values) {
      final addrStr = addr.toString();
      final action = prevMap.containsKey(addrStr) ? AddrAction.maintained : AddrAction.added;

      if (action == AddrAction.added) {
        addrsAdded = true;
      }

      currentAddrs.add(UpdatedAddress(address: addr, action: action));
      prevMap.remove(addrStr);
    }

    // Check for removed addresses
    for (final addr in prevMap.values) {
      removedAddrs.add(UpdatedAddress(address: addr, action: AddrAction.removed));
    }

    // If no addresses were added or removed, don't emit an event
    if (!addrsAdded && removedAddrs.isEmpty) return;

    // Create and emit the event
    final event = EvtLocalAddressesUpdated(
      diffs: true,
      current: currentAddrs,
      removed: removedAddrs,
    );

    try {
      if (_evtLocalAddrsUpdated != null) {
        await _evtLocalAddrsUpdated!.emit(event);
      }
    } catch (e) {
      _log.severe('Error emitting address change event: $e');
    }
  }

  Future<void> _monitorAddressChanges() async {
    var lastAddrs = <MultiAddr>[];

    // Set up a periodic timer to check for address changes
    _addressMonitorTimer = Timer.periodic(Duration(seconds: 5), (_) { // Store the timer
      if (_closed) return;

      // Update local IP addresses if we have listen addresses
      if (_network.listenAddresses.isNotEmpty) {
        _updateLocalIpAddr();
      }


      // Get current addresses
      final curr = addrs;

      // Check if addresses have changed
      if (!_areAddrsEqual(curr, lastAddrs)) {
        // Emit address change event
        _emitAddressChangeEvent(lastAddrs, curr);
        _log.fine('Address change detected');
      }

      lastAddrs = List.from(curr);
    });

    // Also listen for explicit address change signals
    _addrChangeChan.stream.listen((_) {
      if (_closed) return;

      // Update local IP addresses
      if (_network.listenAddresses.isNotEmpty) {
        _updateLocalIpAddr();
      }

      // Get current addresses
      final curr = addrs;

      // Check if addresses have changed
      if (!_areAddrsEqual(curr, lastAddrs)) {
        _emitAddressChangeEvent(lastAddrs, curr);
      }

      lastAddrs = List.from(curr);
    });
  }

  bool _areAddrsEqual(List<MultiAddr> a, List<MultiAddr> b) {
    if (a.length != b.length) return false;

    for (int i = 0; i < a.length; i++) {
      if (a[i].toString() != b[i].toString()) return false;
    }

    return true;
  }

  Future<void> _updateLocalIpAddr() async {
    await _addrMu.synchronized(() async {
      final newFilteredInterfaceAddrs = <MultiAddr>[];
      final newAllInterfaceAddrs = <MultiAddr>[];

      try {
        // Get both IPv4 and IPv6 interfaces, excluding loopback
        final interfaces = await NetworkInterface.list(
          includeLoopback: false,
          type: InternetAddressType.any, // Get both IPv4 and IPv6
        );

        _log.fine('Discovered ${interfaces.length} network interfaces');

        for (final interface in interfaces) {
          _log.finer('Processing interface: ${interface.name}');
          
          for (final address in interface.addresses) {
            // Strip zone identifier / scope ID for IPv6 addresses
            final canonicalAddress = address.address.split('%')[0];
            
            // Skip link-local addresses for IPv6 (fe80::/10)
            if (address.type == InternetAddressType.IPv6 && 
                canonicalAddress.toLowerCase().startsWith('fe80:')) {
              _log.finer('Skipping IPv6 link-local address: $canonicalAddress');
              continue;
            }

            _log.finer('Discovered interface IP: $canonicalAddress on ${interface.name} (${address.type})');
            
            try {
              // Create basic IP multiaddr for this interface
              final protocolName = address.type == InternetAddressType.IPv4 ? 'ip4' : 'ip6';
              final ma = MultiAddr('/$protocolName/$canonicalAddress');
              
              newAllInterfaceAddrs.add(ma);
              
              // Apply filtering: include all non-loopback, non-link-local addresses
              // This includes private ranges like 192.168.x.x, 10.x.x.x, 172.16-31.x.x
              newFilteredInterfaceAddrs.add(ma);
              
              _log.finer('Added interface address: ${ma.toString()}');
            } catch (e) {
              _log.severe('Could not create Multiaddr from IP $canonicalAddress: $e');
            }
          }
        }

        _log.fine('Interface discovery completed. Found ${newAllInterfaceAddrs.length} addresses');
        
      } catch (e) {
        _log.severe('Failed to get network interfaces: $e');
        
        // Fallback strategy: try to extract non-unspecified addresses from current listen addresses
        // This is a last resort if interface discovery completely fails
        final fallbackAddrs = _network.listenAddresses.where((m) {
          final ip4Val = m.valueForProtocol('ip4');
          final ip6Val = m.valueForProtocol('ip6');
          // Only include addresses that are not unspecified (0.0.0.0 or ::)
          return !((ip4Val == '0.0.0.0' || ip4Val == '0.0.0.0.0.0') || 
                   (ip6Val == '::' || ip6Val == '0:0:0:0:0:0:0:0'));
        }).toList();
        
        if (fallbackAddrs.isNotEmpty) {
          _log.warning('Using listen addresses as fallback for interface discovery: $fallbackAddrs');
          newAllInterfaceAddrs.addAll(fallbackAddrs);
          newFilteredInterfaceAddrs.addAll(fallbackAddrs);
        } else {
          _log.warning('No fallback addresses available - interface discovery failed and no concrete listen addresses found');
        }
      }
      
      // Update the stored addresses if they have changed
      if (!_areAddrsEqual(_filteredInterfaceAddrs, newFilteredInterfaceAddrs) || 
          !_areAddrsEqual(_allInterfaceAddrs, newAllInterfaceAddrs)) {
        _filteredInterfaceAddrs = newFilteredInterfaceAddrs;
        _allInterfaceAddrs = newAllInterfaceAddrs;
        _log.fine('Local interface addresses updated. Filtered: ${_filteredInterfaceAddrs.length}, All: ${_allInterfaceAddrs.length}');
        _log.finer('Filtered interface addresses: $_filteredInterfaceAddrs');
      }
    });
  }

  void _newStreamHandler(P2PStream stream) async {
    final startTime = DateTime.now();

    // Set negotiation timeout if configured
    if (_negtimeout > Duration.zero) {
      stream.setDeadline(DateTime.now().add(_negtimeout));
    }

    try {
      // Negotiate protocol
      final (protocol, handler) = await _mux.negotiate(stream); // Use MultistreamMuxer.negotiate

      // Clear deadline after negotiation
      if (_negtimeout > Duration.zero) {
        stream.setDeadline(null);
      }

      // Set protocol on stream
      await stream.setProtocol(protocol);

      final elapsed = DateTime.now().difference(startTime);
      _log.fine('Negotiated protocol: $protocol (took ${elapsed.inMilliseconds}ms)');

      // Handle the stream using the handler returned by negotiate
      handler(protocol, stream);
    } catch (e) {
      final elapsed = DateTime.now().difference(startTime);
      _log.severe('Protocol negotiation failed for incoming stream: $e (took ${elapsed.inMilliseconds}ms)');
      stream.reset();
    }
  }

  /// Signals that the host's addresses may have changed.
  void signalAddressChange() {
    _log.fine('[BasicHost signalAddressChange] Called. _addrChangeChan.isClosed: ${_addrChangeChan.isClosed}, _closed: $_closed. Host: ${id.toString()}');
    if (!_addrChangeChan.isClosed) {
      _addrChangeChan.add(null);
    }
  }

  @override
  PeerId get id => _network.localPeer as PeerId;

  @override
  Peerstore get peerStore => _network.peerstore;

  @override
  List<MultiAddr> get addrs => _addrsFactory(allAddrs);

  /// Returns all addresses the host is listening on.
  List<MultiAddr> get allAddrs {
    // _log.fine('[BasicHost allAddrs] for host ${id.toString()} - Called.');
    final currentListenAddrs = _network.listenAddresses;
    // _log.fine('[BasicHost allAddrs] for host ${id.toString()} - _network.listenAddresses: $currentListenAddrs');
    // _log.fine('[BasicHost allAddrs] for host ${id.toString()} - _filteredInterfaceAddrs: $_filteredInterfaceAddrs');
    final observedFromID = _idService.ownObservedAddrs();
    // _log.fine('[BasicHost allAddrs] for host ${id.toString()} - _idService.ownObservedAddrs(): $observedFromID');

    if (currentListenAddrs.isEmpty && observedFromID.isEmpty) {
      // _log.fine('[BasicHost allAddrs] for host ${id.toString()} - Returning early: no listen or observed addrs.');
      return [];
    }

    final resolvedAddrs = <MultiAddr>{}; // Use a Set to handle duplicates

    // 1. Resolve unspecified listen addresses using filtered interface addresses
    //    (obtained by _updateLocalIpAddr)
    for (final listenAddr in currentListenAddrs) {
      final listenIp4 = listenAddr.valueForProtocol('ip4');
      final listenIp6 = listenAddr.valueForProtocol('ip6');
      final isUnspecified = (listenIp4 == '0.0.0.0' || listenIp4 == '0.0.0.0.0.0') || (listenIp6 == '::' || listenIp6 == '0:0:0:0:0:0:0:0');

      if (isUnspecified) {
        // Resolve unspecified listen addresses (e.g., /ip4/0.0.0.0/udp/port/udx)
        // by combining them with specific interface addresses.
        String suffixString = '';
        final listenComponents = listenAddr.components;
        int ipComponentIndex = -1;

        // Find the index of the first IP component
        for (int i = 0; i < listenComponents.length; i++) {
          final protoName = listenComponents[i].$1.name;
          if (protoName == 'ip4' || protoName == 'ip6') {
            ipComponentIndex = i;
            break;
          }
        }

        if (ipComponentIndex != -1 && ipComponentIndex < listenComponents.length - 1) {
          // If an IP component was found and it's not the last component,
          // construct the suffix string from subsequent components.
          final suffixComponents = listenComponents.sublist(ipComponentIndex + 1);
          final sb = StringBuffer();
          for (final (protocol, value) in suffixComponents) {
            sb.write('/${protocol.name}');
            // Only add value if protocol is not size 0 (e.g., for /udx)
            // or if the value is not empty (for protocols that might have optional values, though less common here)
            if (protocol.size != 0 || value.isNotEmpty) {
              sb.write('/$value');
            }
          }
          suffixString = sb.toString();
        } else if (ipComponentIndex == -1) {
           _log.fine('Listen address $listenAddr does not start with ip4 or ip6, cannot resolve unspecified.');
        }
        // If ipComponentIndex is the last component, suffixString remains empty, which is correct.


        if (suffixString.isNotEmpty) {
          if (_filteredInterfaceAddrs.isNotEmpty) {
            for (final interfaceAddr in _filteredInterfaceAddrs) {
              // interfaceAddr is a bare IP MultiAddr, e.g., /ip4/192.168.10.118
              try {
                // Combine the interface address string with the suffix string
                final combinedAddrString = interfaceAddr.toString() + suffixString;
                final newAddr = MultiAddr(combinedAddrString);
                resolvedAddrs.add(newAddr);
                _log.finer('Resolved unspecified listen addr: $listenAddr with interface $interfaceAddr to ${newAddr.toString()}');
              } catch (e) {
                _log.severe('Failed to create resolved address by encapsulating $interfaceAddr with suffix $suffixString (from $listenAddr): $e');
              }
            }
          } else {
            // No interface addresses available - trigger interface discovery and warn
            _log.warning('No interface addresses available to resolve unspecified listen address: $listenAddr. Triggering interface discovery.');
            _updateLocalIpAddr(); // Try to update interface addresses
            
            // If still no interface addresses after update, this unspecified address cannot be resolved
            if (_filteredInterfaceAddrs.isEmpty) {
              _log.warning('Interface discovery failed or returned no addresses. Unspecified listen address $listenAddr cannot be resolved to concrete addresses.');
            }
          }
        } else if (isUnspecified) {
          // This case means it was an unspecified IP, but we couldn't get a suffix
          // (e.g., listenAddr was just /ip4/0.0.0.0).
          _log.warning('Could not determine suffix for unspecified listen address: $listenAddr. It will not be resolved against interface IPs.');
          // We don't add the original unspecified listenAddr to resolvedAddrs here,
          // as it would be filtered out by defaultAddrsFactory anyway.
        }
      } else {
        // Address is already specific, add it directly.
        resolvedAddrs.add(listenAddr);
      }
    }
    
    // If there were no listen addresses, but we have interface addresses,
    // this part might need refinement. Typically, host addresses are listen addresses.
    // If currentListenAddrs is empty, resolvedAddrs will be empty here.

    final natAppliedAddrs = <MultiAddr>{};
    // 2. Apply NAT mappings if available
    if (_natmgr != null && _natmgr!.hasDiscoveredNAT()) {
      for (final addr in resolvedAddrs) {
        // If resolvedAddrs is empty (e.g. all listen addrs were unspecified and no interface addrs found),
        // try to map original listen addrs.
        final mapped = _natmgr!.getMapping(addr);
        if (mapped != null) {
          natAppliedAddrs.add(mapped);
        } else {
          natAppliedAddrs.add(addr); // Keep original if no mapping
        }
      }
    } else {
      natAppliedAddrs.addAll(resolvedAddrs);
    }
    
    // If resolvedAddrs was empty and currentListenAddrs was not, but NAT manager didn't map anything,
    // natAppliedAddrs would still be based on resolvedAddrs (empty).
    // We should ensure that if resolvedAddrs is empty due to no interface IPs for 0.0.0.0,
    // we still consider the original listen addresses for NAT mapping or inclusion.
    // Let's refine: if resolvedAddrs is empty but currentListenAddrs is not, it means all were unspecified
    // and no local IPs were found. In this case, `allAddrs` should probably be empty or only observed.

    final finalAddrs = <MultiAddr>{};
    finalAddrs.addAll(natAppliedAddrs);


    // 3. Add observed addresses from identify service
    // These are addresses observed by other peers, potentially behind NAT.
    final observed = _idService.ownObservedAddrs();
    finalAddrs.addAll(observed);
    
    // If after all this, finalAddrs is empty, but we had original listen addresses,
    // it implies they were all unspecified, no local IPs found, no NAT mapping, and no observed.
    // This scenario should result in an empty list.

    // Convert Set to List for the return type.
    // The _addrsFactory can then do further filtering/sorting.
    final result = finalAddrs.toList();
    _log.fine('[BasicHost allAddrs] for host ${id.toString()} - resolvedAddrs: $resolvedAddrs');
    _log.fine('[BasicHost allAddrs] for host ${id.toString()} - natAppliedAddrs: $natAppliedAddrs');
    _log.fine('[BasicHost allAddrs] for host ${id.toString()} - finalAddrs (before toList): $finalAddrs');
    _log.fine('[BasicHost allAddrs] for host ${id.toString()} - Returning: $result');
    return result;
  }

  @override
  Network get network => _network;

  @override
  ProtocolSwitch get mux => _mux;

  @override
  EventBus get eventBus => _eventBus;

  @override
  ConnManager get connManager => _cmgr;

  @override
  HolePunchService? get holePunchService => _holePunchService;

  /// Returns only public/observed addresses suitable for holepunching.
  /// This includes:
  /// - Observed addresses from identify service (external addresses seen by peers)
  /// - Addresses that AutoNAT has verified as reachable (when AutoNAT status is public)
  /// - Excludes private network addresses that are not reachable externally
  List<MultiAddr> get publicAddrs {
    final publicAddresses = <MultiAddr>[];
    
    // Get observed addresses from identify service
    // These are addresses that other peers have seen us on, which should be public-facing
    final observed = _idService.ownObservedAddrs();
    publicAddresses.addAll(observed);
    
    // If AutoNAT v1 indicates we're publicly reachable, include addresses that appear public
    // This is a heuristic until we have proper AutoNAT v2 address verification
    if (_autoNATService != null) {
      final autonatStatus = _autoNATService!.status;
      _log.fine('[BasicHost publicAddrs] AutoNAT status: $autonatStatus');
      
      if (autonatStatus == Reachability.public) {
        // When AutoNAT confirms we're publicly reachable, we can trust addresses that "look public"
        // This helps when observed addresses aren't available yet
        final candidateAddrs = allAddrs.where((addr) {
          // Only include addresses that appear to be public (not private ranges)
          return addr.isPublic() && !isRelayAddress(addr);
        }).toList();
        
        _log.fine('[BasicHost publicAddrs] AutoNAT reports public reachability, adding ${candidateAddrs.length} candidate addresses');
        publicAddresses.addAll(candidateAddrs);
      } else {
        _log.fine('[BasicHost publicAddrs] AutoNAT status is $autonatStatus, not adding candidate addresses');
      }
    }
    
    // Remove duplicates and filter out any private addresses that may have slipped through
    final uniqueAddrs = <String, MultiAddr>{};
    for (final addr in publicAddresses) {
      if (addr.isPublic()) {
        uniqueAddrs[addr.toString()] = addr;
      }
    }
    
    final result = uniqueAddrs.values.toList();
    
    // TESTING FALLBACK: If no public addresses found, use non-relay addresses for testing
    // This allows holepunching to work in controlled NAT environments like Docker
    if (result.isEmpty) {
      final fallbackAddrs = allAddrs.where((addr) => !isRelayAddress(addr)).toList();
      _log.fine('[BasicHost publicAddrs] No public addresses found, using ${fallbackAddrs.length} fallback addresses for testing: $fallbackAddrs');
      return fallbackAddrs;
    }
    
    _log.fine('[BasicHost publicAddrs] for host ${id.toString()} - Observed: ${observed.length}, Final result: ${result.length} addresses: $result');
    return result;
  }

  @override
  Future<void> connect(AddrInfo pi, {Context? context}) async {
    final startTime = DateTime.now();

    
    // Prevent self-dialing
    if (pi.id == id) {

      return;
    }

    // Phase 1: Address Filtering and Peerstore Update

    final filterStartTime = DateTime.now();
    
    final filteredAddrs = _addrsFactory(pi.addrs);

    
    await peerStore.addrBook.addAddrs(pi.id, filteredAddrs, Duration(minutes: 5));
    
    final filterTime = DateTime.now().difference(filterStartTime);


    // Phase 2: Connection Check

    final connectedness = _network.connectedness(pi.id);

    
    if (connectedness == Connectedness.connected) {
      final totalTime = DateTime.now().difference(startTime);

      return;
    }

    // Phase 3: Context Creation

    final ctx = context ?? Context();


    // Phase 4: Dial Peer

    final dialStartTime = DateTime.now();
    
    try {
      await _dialPeer(pi.id, ctx);
      
      final dialTime = DateTime.now().difference(dialStartTime);
      final totalTime = DateTime.now().difference(startTime);


    } catch (e, stackTrace) {
      final dialTime = DateTime.now().difference(dialStartTime);
      final totalTime = DateTime.now().difference(startTime);
      _log.severe('❌ [CONNECT-ERROR] Connection failed after ${totalTime.inMilliseconds}ms (dial: ${dialTime.inMilliseconds}ms): $e\n$stackTrace');
      rethrow;
    }
  }

  Future<void> _dialPeer(PeerId p, Context context) async {
    final startTime = DateTime.now();


    try {
      // Phase 1: Network Dial
      final conn = await _network.dialPeer(context, p);

      // Phase 2: Identify Wait
      final identifyStartTime = DateTime.now();
      
      await _idService.identifyWait(conn);
      
      final identifyTime = DateTime.now().difference(identifyStartTime);

    } catch (e, stackTrace) {
      final totalTime = DateTime.now().difference(startTime);
      _log.severe('❌ [DIAL-PEER-ERROR] Failed to dial ${p.toString()} after ${totalTime.inMilliseconds}ms: $e\n$stackTrace');
      throw Exception('Failed to dial: $e');
    }
  }

  @override
  void setStreamHandler(ProtocolID pid, StreamHandler handler) {
    // Convert StreamHandler to HandlerFunc
    final handlerFunc = (ProtocolID protocol, P2PStream stream) {
      // Extract remotePeer from the stream's connection
      final remotePeer = stream.conn.remotePeer;
      // Call the handler with both stream and remotePeer
      handler(stream, remotePeer);
    };

    _mux.addHandler(pid, handlerFunc);

    // Emit protocol updated event
    if (_evtLocalProtocolsUpdated != null) {
      _evtLocalProtocolsUpdated!.emit(EvtLocalProtocolsUpdated(added: [pid], removed: []));
    }
  }

  @override
  void setStreamHandlerMatch(ProtocolID pid, bool Function(ProtocolID) match, StreamHandler handler) {
    // Convert StreamHandler to HandlerFunc
    // final handlerFunc = (ProtocolID protocol, P2PStream stream) {
    //   handler(stream);
    // };
    final handlerFunc = (ProtocolID protocol, P2PStream stream) {
      // Extract remotePeer from the stream's connection
      final remotePeer = stream.conn.remotePeer;
      // Call the handler with both stream and remotePeer
      handler(stream, remotePeer);
    };

    _mux.addHandlerWithFunc(pid, match, handlerFunc);

    // Emit protocol updated event
    if (_evtLocalProtocolsUpdated != null) {
      _evtLocalProtocolsUpdated!.emit(EvtLocalProtocolsUpdated(added: [pid], removed: []));
    }
  }

  @override
  void removeStreamHandler(ProtocolID pid) {
    _mux.removeHandler(pid);

    // Emit protocol updated event
    if (_evtLocalProtocolsUpdated != null) {
      _evtLocalProtocolsUpdated!.emit(EvtLocalProtocolsUpdated(added: [], removed: [pid]));
    }
  }

  @override
  Future<P2PStream> newStream(PeerId p, List<ProtocolID> pids, Context context) async {
    final startTime = DateTime.now();

    
    // Set up a timeout context if needed
    final hasTimeout = _negtimeout > Duration.zero;
    final deadline = hasTimeout ? DateTime.now().add(_negtimeout) : null;


    // Phase 1: Connection

    final connectStartTime = DateTime.now();
    
    await connect(AddrInfo(p, []), context: context);
    
    final connectTime = DateTime.now().difference(connectStartTime);


    // Phase 2: Stream Creation

    final streamCreateStartTime = DateTime.now();
    
    final stream = await _network.newStream(context, p);
    
    final streamCreateTime = DateTime.now().difference(streamCreateStartTime);


    // DEBUG: Add protocol assignment tracking


    // Phase 3: Identify Wait

    final identifyStartTime = DateTime.now();
    
    await _idService.identifyWait(stream.conn);
    
    final identifyTime = DateTime.now().difference(identifyStartTime);


    // Phase 4: Protocol Negotiation

    final negotiationStartTime = DateTime.now();
    
    try {
      if (hasTimeout && deadline != null) {

        stream.setDeadline(deadline);
      }


      // DEBUG: Add detailed protocol negotiation tracking

      final selectStartTime = DateTime.now();
      
      final selectedProtocol = await _mux.selectOneOf(stream, pids);
      
      final selectTime = DateTime.now().difference(selectStartTime);

      
      // DEBUG: Add protocol selection result tracking


      if (hasTimeout) {

        stream.setDeadline(null); // Clear deadline after successful negotiation
      }

      if (selectedProtocol == null) {
        _log.severe('🤝 [NEWSTREAM-PHASE-4] No protocol selected from: $pids');
        stream.reset();
        throw Exception('Failed to negotiate any of the requested protocols: $pids with peer $p');
      }

      // Phase 5: Protocol Setup

      final setupStartTime = DateTime.now();
      
      // DEBUG: Add protocol assignment tracking

      await stream.setProtocol(selectedProtocol);
      
      // Ensure the stream's scope is also updated with the protocol.
      // This is crucial for services like Identify that attach to the scope.

      await stream.scope().setProtocol(selectedProtocol);
      
      // Add the successfully negotiated protocol to the peerstore for the remote peer.
      // Note: The go-libp2p implementation adds this *after* the stream handler returns,
      // but it seems more robust to add it as soon as negotiation succeeds.
      // This ensures that even if the handler has issues, we've recorded the protocol.
      peerStore.protoBook.addProtocols(p, [selectedProtocol]);
      
      final setupTime = DateTime.now().difference(setupStartTime);
      final negotiationTime = DateTime.now().difference(negotiationStartTime);
      final totalTime = DateTime.now().difference(startTime);
      



      
      // DEBUG: Add final protocol assignment confirmation

      
      return stream;

    } catch (e, stackTrace) {
      final negotiationTime = DateTime.now().difference(negotiationStartTime);
      final totalTime = DateTime.now().difference(startTime);
      _log.severe('❌ [NEWSTREAM-ERROR] Stream creation failed after ${totalTime.inMilliseconds}ms (negotiation: ${negotiationTime.inMilliseconds}ms): $e\n$stackTrace');
      
      try {
        stream.reset();

      } catch (resetError) {
        _log.warning('⚠️ [NEWSTREAM-ERROR] Error during stream reset: $resetError');
      }
      
      // No need to check for UnimplementedError specifically anymore
      throw Exception('Failed to negotiate protocol with $p for $pids: $e');
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;

    _closeSync.complete(); // Signal that close has been initiated
    _closed = true;

    // Close IDService
    await _idService.close();

    // If PingService was initialized (i.e., enabled), remove its handler.
    if (_pingService != null) {
      // Assuming PingConstants.protocolId is accessible or we use the string directly.
      // For now, let's use the string directly as PingConstants is not imported here.
      // Ideally, PingConstants.protocolId would be exposed or PingService would have a static getter.
      removeStreamHandler('/ipfs/ping/1.0.0');
    }

    // Close RelayManager if initialized
    await _relayManager?.close();

    // Close AutoNATService if initialized
    await _autoNATService?.close();

    // Close HolePunchService if initialized
    await _holePunchService?.close();

    // Close NAT manager if available
    if (_natmgr != null) {
      await _natmgr!.close();
    }

    // Close connection manager
    await _cmgr.close();

    // Close address change channel
    await _addrChangeChan.close();

    // Cancel the address monitor timer
    _addressMonitorTimer?.cancel();

    // Close network
    await _network.close();

    // Close peerstore
    await peerStore.close();
  }
}

/// Network notifiee for address changes.
class _AddressChangeNotifiee implements Notifiee {
  final BasicHost _host;

  _AddressChangeNotifiee(this._host);

  @override
  void listen(Network network, MultiAddr addr) {
    _host.signalAddressChange();
  }

  @override
  void listenClose(Network network, MultiAddr addr) {
    _host.signalAddressChange();
  }

  @override
  Future<void> connected(Network network, Conn conn) async {
    return await Future.delayed(Duration(milliseconds: 10));
  }

  @override
  Future<void> disconnected(Network network, Conn conn) async {
    return await Future.delayed(Duration(milliseconds: 10));
  }
}
