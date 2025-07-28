import 'dart:async';
import 'dart:math';

import 'package:multicast_dns/multicast_dns.dart';

import '../../../core/discovery.dart';
import '../../../core/peer/addr_info.dart';
import '../../../core/host/host.dart';
import '../../../core/multiaddr.dart';

import '../../../core/peer/peer_id.dart';
import 'service_registry.dart';

/// Constants for mDNS service
class MdnsConstants {
  /// The default service name for libp2p mDNS discovery
  static const String serviceName = '_p2p._udp';

  /// The domain for mDNS
  static const String mdnsDomain = 'local';

  /// Prefix for DNS address records
  static const String dnsaddrPrefix = 'dnsaddr=';

  /// Default port for mDNS (not actually used, but required by some implementations)
  static const int defaultPort = 4001;
}

/// Interface for handling discovered peers
abstract class MdnsNotifee {
  /// Called when a peer is discovered
  void handlePeerFound(AddrInfo peer);
}

/// Implementation of mDNS discovery for libp2p
class MdnsDiscovery implements Discovery {
  final Host _host;
  final String _serviceName;
  final String _peerName;
  MdnsNotifee? _notifee;

  /// Sets the notifee
  set notifee(MdnsNotifee? value) {
    _notifee = value;
  }

  MDnsClient? _client;
  MdnsServiceRegistry? _registry;
  StreamSubscription? _subscription;
  bool _isRunning = false;

  /// Creates a new MdnsDiscovery service
  MdnsDiscovery(this._host, {
    String? serviceName,
    MdnsNotifee? notifee,
  }) : 
    _serviceName = serviceName ?? MdnsConstants.serviceName,
    _peerName = _generateRandomString(32 + Random().nextInt(32)),
    _notifee = notifee;

  /// Starts the mDNS discovery service
  Future<void> start() async {
    if (_isRunning) return;

    _client = MDnsClient();
    await _client!.start();

    // Start advertising
    _startAdvertising();

    // Start discovery
    _startDiscovery();

    _isRunning = true;
  }

  /// Stops the mDNS discovery service
  Future<void> stop() async {
    if (!_isRunning) return;

    _subscription?.cancel();
    _subscription = null;

    _registry?.dispose();
    _registry = null;

    if (_client != null) {
      _client!.stop();
      _client = null;
    }

    _isRunning = false;
  }

  @override
  Future<Duration> advertise(String ns, [List<DiscoveryOption> options = const []]) async {
    if (!_isRunning) {
      await start();
    }

    final opts = DiscoveryOptions().apply(options);
    return opts.ttl ?? const Duration(minutes: 1);
  }

  @override
  Future<Stream<AddrInfo>> findPeers(String ns, [List<DiscoveryOption> options = const []]) async {
    if (!_isRunning) {
      await start();
    }

    final controller = StreamController<AddrInfo>();

    // Create a notifee that will forward discovered peers to the stream
    final streamNotifee = _StreamNotifee(controller);

    // Store the original notifee
    final originalNotifee = _notifee;

    // Create a composite notifee that will notify both the original notifee and the stream
    final compositeNotifee = _CompositeNotifee([
      if (originalNotifee != null) originalNotifee,
      streamNotifee,
    ]);

    // Set up a subscription to handle cleanup when the stream is closed
    controller.onCancel = () {
      // If the stream is closed, we don't need to forward discovered peers to it anymore
      // But we still want to notify the original notifee
      notifee = originalNotifee;
    };

    // Set the composite notifee as the current notifee
    notifee = compositeNotifee;

    return controller.stream;
  }

  void _startAdvertising() {
    if (_client == null) return;

    final addresses = _host.addrs;
    final txtRecords = <String>[];

    for (final addr in addresses) {
      txtRecords.add('${MdnsConstants.dnsaddrPrefix}${addr.toString()}');
    }

    // Create and register the service
    _registry = MdnsServiceRegistry(
      client: _client!,
      serviceName: _serviceName,
      domain: MdnsConstants.mdnsDomain,
      name: _peerName,
      port: MdnsConstants.defaultPort,
      txtRecords: txtRecords,
    );

    _registry!.register();
  }

  // Start discovery of other peers
  void _startDiscovery() {
    if (_client == null) return;

    // Listen for PTR records for our service
    _subscription = _client!.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer('$_serviceName.${MdnsConstants.mdnsDomain}'),
    ).listen((event) {
      // When a PTR record is found, query for the corresponding SRV and TXT records
      final String domainName = event.domainName;

      // Query for TXT records
      _client!.lookup<TxtResourceRecord>(
        ResourceRecordQuery.text(domainName),
      ).listen(_processTxtRecord);

      // Query for SRV records (for completeness, though we don't use them directly)
      _client!.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(domainName),
      );
    });
  }

  // Process a TXT record to extract peer information
  void _processTxtRecord(TxtResourceRecord record) {
    // Extract peer information from TXT records
    final addresses = <MultiAddr>[];
    PeerId? peerId;

    // Get the text as a string
    final String txtString = record.text.toString();

    // Check if the text contains our prefix
    if (txtString.contains(MdnsConstants.dnsaddrPrefix)) {
      // Find the start of the prefix
      final int startIndex = txtString.indexOf(MdnsConstants.dnsaddrPrefix);
      // Extract everything after the prefix
      final String remaining = txtString.substring(startIndex + MdnsConstants.dnsaddrPrefix.length);
      // Find the end of the address (if there are multiple entries)
      final int endIndex = remaining.contains(' ') ? remaining.indexOf(' ') : remaining.length;
      // Extract the address
      final String addrStr = remaining.substring(0, endIndex);

      try {
        final addr = MultiAddr(addrStr);
        addresses.add(addr);

        // Try to extract peer ID from multiaddr
        final peerIdStr = addr.valueForProtocol('p2p');
        if (peerIdStr != null) {
          peerId = PeerId.fromString(peerIdStr);
        }
      } catch (e) {
        // Ignore invalid multiaddrs
      }
    }

    // If we found addresses and a peer ID, notify the notifee
    if (addresses.isNotEmpty && peerId != null) {
      final addrInfo = AddrInfo(peerId, addresses);
      _notifee?.handlePeerFound(addrInfo);
    }
  }


  /// Generates a random string of the specified length
  static String _generateRandomString(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random();
    return String.fromCharCodes(
      List.generate(length, (_) => chars.codeUnitAt(random.nextInt(chars.length)))
    );
  }
}

/// A notifee that forwards discovered peers to a stream
class _StreamNotifee implements MdnsNotifee {
  final StreamController<AddrInfo> _controller;

  _StreamNotifee(this._controller);

  @override
  void handlePeerFound(AddrInfo peer) {
    if (!_controller.isClosed) {
      _controller.add(peer);
    }
  }
}

/// A notifee that forwards discovered peers to multiple notifees
class _CompositeNotifee implements MdnsNotifee {
  final List<MdnsNotifee> _notifees;

  _CompositeNotifee(this._notifees);

  @override
  void handlePeerFound(AddrInfo peer) {
    for (final notifee in _notifees) {
      notifee.handlePeerFound(peer);
    }
  }
}
