import 'dart:io';
import 'dart:typed_data';

import 'package:dart_libp2p/p2p/multiaddr/codec.dart';
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart';

/// Represents a multiaddress
class MultiAddr {
  final String _addr;
  final List<(Protocol, String)> _components;

  /// Creates a new Multiaddr from a string
  /// Format: /protocol1/value1/protocol2/value2
  /// Example: /ip4/127.0.0.1/tcp/1234
  MultiAddr(this._addr): _components = _parseAddr(_addr);


  static List<(Protocol, String)> _parseAddr(String addr) {
    final components = <(Protocol, String)>[];
    final parts = addr.split('/').where((part) => part.isNotEmpty).toList();

    for (var i = 0; i < parts.length;) {
      final protocolName = parts[i];
      final protocol = Protocols.byName(protocolName);

      if (protocol == null) {
        throw FormatException('Unknown protocol: $protocolName');
      }
      i++; // Consumed protocol name

      if (protocol.size == 0) {
        components.add((protocol, '')); // No value part, add with empty string
        // Continue to the next protocol component
      } else if (protocol.hasPath) {
        // Path protocols consume the rest of the string parts as their value.
        if (i >= parts.length) {
          // This means the multiaddr ends with the path protocol itself, e.g., "/unix"
          // In this case, the path value is considered empty.
          components.add((protocol, ''));
        } else {
          // The rest of the parts form the path value.
          final pathValue = parts.sublist(i).join('/');
          components.add((protocol, pathValue));
        }
        i = parts.length; // Consumed all remaining parts for the path protocol.
      } else {
        // Regular protocol expecting a value
        if (i >= parts.length) {
          throw FormatException('Missing value for protocol: $protocolName');
        }
        final value = parts[i];
        components.add((protocol, value));
        i++; // Consumed value
      }
    }
    return components;
  }

  @override
  String toString() => _addr;

  Uint8List toBytes() {
    final bytes = <int>[];

    for (final (protocol, value) in _components) {
      // Add protocol code as varint
      bytes.addAll(MultiAddrCodec.encodeVarint(protocol.code));

      // Add value
      final valueBytes = MultiAddrCodec.encodeValue(protocol, value);

      // Add size for variable-length values
      if (protocol.isVariableSize) {
        bytes.addAll(MultiAddrCodec.encodeVarint(valueBytes.length));
      }

      bytes.addAll(valueBytes);
    }

    return Uint8List.fromList(bytes);
  }

  /// Creates a Multiaddr from bytes
  static MultiAddr fromBytes(Uint8List bytes) {
    var offset = 0;
    final components = <(Protocol, String)>[];

    while (offset < bytes.length) {
      // Read protocol code
      final (code, protocolBytesRead) = MultiAddrCodec.decodeVarint(bytes, offset);
      offset += protocolBytesRead;

      final protocol = Protocols.byCode(code);
      if (protocol == null) {
        throw FormatException('Unknown protocol code: $code');
      }

      // Read value
      int valueLength;
      if (protocol.isVariableSize) {
        final (length, lengthBytesRead) = MultiAddrCodec.decodeVarint(bytes, offset);
        offset += lengthBytesRead;
        valueLength = length;
      } else {
        valueLength = protocol.size ~/ 8;
      }

      if (offset + valueLength > bytes.length) {
        throw FormatException('Invalid multiaddr bytes: unexpected end of input');
      }

      final valueBytes = bytes.sublist(offset, offset + valueLength);
      final value = MultiAddrCodec.decodeValue(protocol, valueBytes);
      components.add((protocol, value));

      offset += valueLength;
    }

    // Reconstruct string representation
    final sb = StringBuffer();
    for (final (protocol, value) in components) {
      sb.write('/${protocol.name}');
      if (protocol.size != 0) { // Only add value if protocol is not size 0
        sb.write('/$value');
      }
      // If protocol.size == 0, we add nothing more for this component.
    }
    final finalAddrString = sb.toString();
    return MultiAddr(finalAddrString);
  }

  bool hasProtocol(String protocol) {
    return _components.any((c) => c.$1.name == protocol);
  }

  String? valueForProtocol(String protocol) {
    final component = _components.firstWhere(
          (c) => c.$1.name == protocol,
      orElse: () => (Protocols.ip4, ''),
    );
    return component.$1.name == protocol ? component.$2 : null;
  }

  /// Returns all protocols in this multiaddr
  List<Protocol> get protocols => _components.map((c) => c.$1).toList();

  /// Returns all values in this multiaddr
  List<String> get values => _components.map((c) => c.$2).toList();

  /// Returns all protocol/value pairs in this multiaddr
  List<(Protocol, String)> get components => List.unmodifiable(_components);

  /// Encapsulates this multiaddr with another protocol/value pair
  MultiAddr encapsulate(String protocolName, String value) {
    final newAddr = toString() + '/$protocolName/$value';
    return MultiAddr(newAddr);
  }

  /// Decapsulates the last protocol/value pair from this multiaddr
  MultiAddr? decapsulate(String protocol) {
    final index = _components.lastIndexWhere((c) => c.$1.name == protocol);
    if (index == -1) return null;

    final newComponents = _components.take(index);
    final newAddr = newComponents.map((c) => '/${c.$1.name}/${c.$2}').join();
    return MultiAddr(newAddr);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MultiAddr && other._addr == _addr;
  }

  @override
  int get hashCode => _addr.hashCode;

  bool equals(MultiAddr addr) {
    return addr.toString() == _addr;
  }

  bool isLoopback() {
    for (final (protocol, value) in _components) {
      if (protocol.name == 'ip4' && value == '127.0.0.1') {
        return true;
      }
      if (protocol.name == 'ip6' &&
          (value == '::1' || value.toLowerCase() == '::1')) {
        return true;
      }
      if (protocol.name == 'unix' &&
          (value.startsWith('/tmp/') || value == '/dev/shm')) {
        return true;
      }
    }
    return false;
  }

  InternetAddress? toIP() {
    for (final (protocol, value) in _components) {
      if (protocol.name == 'ip4') {
        return InternetAddress(value, type: InternetAddressType.IPv4);
      }
      if (protocol.name == 'ip6') {
        return InternetAddress(value, type: InternetAddressType.IPv6);
      }
    }
    return null;
  }

  bool isPrivate() {
    final ip = toIP();
    if (ip == null) return false;

    final addr = ip.address;
    if (ip.type == InternetAddressType.IPv4) {
      // Check private IPv4 ranges
      if (addr.startsWith('10.')) return true;
      if (addr.startsWith('172.') &&
          int.parse(addr.split('.')[1]) >= 16 &&
          int.parse(addr.split('.')[1]) <= 31) return true;
      if (addr.startsWith('192.168.')) return true;
    } else {
      // Check private IPv6 ranges
      if (addr.toLowerCase().startsWith('fc')) return true;
      if (addr.toLowerCase().startsWith('fd')) return true;
    }
    return false;
  }

  bool isPublic() {
    return !isPrivate() && !isLoopback();
  }

  // ========== Named Component Getters ==========

  /// Network Address Getters
  
  /// Returns the IPv4 address if present
  String? get ip4 => valueForProtocol('ip4');
  
  /// Returns the IPv6 address if present
  String? get ip6 => valueForProtocol('ip6');
  
  /// Returns the first available IP address (IPv4 or IPv6)
  String? get ip => ip4 ?? ip6;
  
  /// Returns the DNS4 address if present
  String? get dns4 => valueForProtocol('dns4');
  
  /// Returns the DNS6 address if present
  String? get dns6 => valueForProtocol('dns6');
  
  /// Returns the DNS address if present
  String? get dnsaddr => valueForProtocol('dnsaddr');

  /// Port Getters
  
  /// Returns the TCP port number if present
  int? get tcpPort => _parsePort(valueForProtocol('tcp'));
  
  /// Returns the UDP port number if present
  int? get udpPort => _parsePort(valueForProtocol('udp'));
  
  /// Returns the first available port number (TCP or UDP)
  int? get port => tcpPort ?? udpPort;

  /// Protocol Flag Getters
  
  /// Returns true if UDX protocol is present
  bool get hasUdx => hasProtocol('udx');
  
  /// Returns true if QUIC-v1 protocol is present
  bool get hasQuicV1 => hasProtocol('quic-v1');
  
  /// Returns true if WebTransport protocol is present
  bool get hasWebtransport => hasProtocol('webtransport');
  
  /// Returns true if P2P circuit protocol is present
  bool get hasCircuit => hasProtocol('p2p-circuit');

  /// Identity and Path Getters
  
  /// Returns the peer ID if present
  String? get peerId => valueForProtocol('p2p');
  
  /// Returns the Unix path if present
  String? get unixPath => valueForProtocol('unix');
  
  /// Returns the certificate hash if present
  String? get certhash => valueForProtocol('certhash');
  
  /// Returns the SNI value if present
  String? get sni => valueForProtocol('sni');

  /// Convenience Methods
  
  /// Helper method for parsing port strings to integers
  int? _parsePort(String? portStr) {
    if (portStr == null) return null;
    return int.tryParse(portStr);
  }
  
  /// Returns all transport protocols present in this multiaddr
  List<String> get transports {
    final transports = <String>[];
    if (hasProtocol('tcp')) transports.add('tcp');
    if (hasProtocol('udp')) transports.add('udp');
    if (hasUdx) transports.add('udx');
    if (hasQuicV1) transports.add('quic-v1');
    if (hasWebtransport) transports.add('webtransport');
    return transports;
  }

}
