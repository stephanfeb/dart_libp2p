import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

/// A class that handles mDNS service registration and discovery
class MdnsServiceRegistry {
  final MDnsClient _client;
  final String _serviceName;
  final String _domain;
  final String _name;
  final int _port;
  final List<String> _txtRecords;

  bool _isRegistered = false;
  StreamSubscription? _ptrSubscription;

  /// Creates a new MdnsServiceRegistry
  MdnsServiceRegistry({
    required MDnsClient client,
    required String serviceName,
    required String domain,
    required String name,
    required int port,
    required List<String> txtRecords,
  }) : 
    _client = client,
    _serviceName = serviceName,
    _domain = domain,
    _name = name,
    _port = port,
    _txtRecords = txtRecords;

  /// Registers the service with mDNS
  void register() {
    if (_isRegistered) return;

    // Listen for PTR queries for our service
    _ptrSubscription = _client.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer('$_serviceName.$_domain'),
    ).listen((event) {
      // When someone queries for our service, respond with our records
      _sendServiceRecords();
    });

    // Announce our service immediately
    _sendServiceRecords();

    _isRegistered = true;
  }

  /// Sends all service records to announce our presence
  void _sendServiceRecords() {
    // Send PTR record
    _client.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer('$_serviceName.$_domain'),
    );

    final String fullName = '$_name.$_serviceName.$_domain';

    // Send SRV record
    _client.lookup<SrvResourceRecord>(
      ResourceRecordQuery.service(fullName),
    );

    // Send TXT records
    _client.lookup<TxtResourceRecord>(
      ResourceRecordQuery.text(fullName),
    );
  }

  /// Unregisters the service
  void unregister() {
    if (!_isRegistered) return;

    // Cancel the subscription to PTR queries
    _ptrSubscription?.cancel();
    _ptrSubscription = null;

    // Send goodbye packets (TTL=0) for all our records
    final String fullName = '$_name.$_serviceName.$_domain';

    // Send PTR record (TTL=0 not supported in this version)
    _client.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer('$_serviceName.$_domain'),
    );

    // Send SRV record (TTL=0 not supported in this version)
    _client.lookup<SrvResourceRecord>(
      ResourceRecordQuery.service(fullName),
    );

    // Send TXT records (TTL=0 not supported in this version)
    _client.lookup<TxtResourceRecord>(
      ResourceRecordQuery.text(fullName),
    );

    _isRegistered = false;
  }

  /// Disposes of the registry
  void dispose() {
    unregister();
  }
}
