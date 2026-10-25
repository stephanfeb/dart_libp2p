import 'dart:io' show InternetAddress, InternetAddressType;

/// Represents a multiaddr protocol
class Protocol {
  final String name;
  final int code;
  final int size; // -1 for variable size
  final String? path; // true if protocol has a path component
  // final String? _value = null;

  const Protocol({
    required this.name,
    required this.code,
    required this.size,
    this.path,
  });

  /// Returns true if this protocol has a variable size value
  bool get isVariableSize => size == -1;

  /// Returns true if this protocol has a path component
  bool get hasPath => path != null;

  // set value(String? value) { _value = value;}
  //
  // String? get value => _value;

  /// Converts a protocol value to an InternetAddress if possible
  /// Throws ArgumentError if the protocol doesn't support conversion to InternetAddress
  InternetAddress toInternetAddress(String value) {
    switch (name) {
      case 'ip4':
        return InternetAddress(value, type: InternetAddressType.IPv4);
      case 'ip6':
        return InternetAddress(value, type: InternetAddressType.IPv6);
      default:
        throw ArgumentError('Protocol $name does not support conversion to InternetAddress');
    }
  }

  @override
  String toString() => '/$name';
}

/// Registry of supported multiaddr protocols
class Protocols {
  static const ip4 = Protocol(
    name: 'ip4',
    code: 0x04,
    size: 32,
  );

  static const tcp = Protocol(
    name: 'tcp',
    code: 0x06,
    size: 16,
  );

  static const udp = Protocol(
    name: 'udp',
    code: 0x0111,
    size: 16,
  );

  static const ip6 = Protocol(
    name: 'ip6',
    code: 0x29,
    size: 128,
  );

  static const dns = Protocol(
    name: 'dns',
    code: 0x35,
    size: -1,
  );

  static const dns4 = Protocol(
    name: 'dns4',
    code: 0x36,
    size: -1,
  );

  static const dns6 = Protocol(
    name: 'dns6',
    code: 0x37,
    size: -1,
  );

  static const dnsaddr = Protocol(
    name: 'dnsaddr',
    code: 0x38,
    size: -1,
  );

  static const p2p = Protocol(
    name: 'p2p',
    code: 0x01A5,
    size: -1,
  );

  static const unix = Protocol(
    name: 'unix',
    code: 0x0190,
    size: -1,
    path: '/',
  );

  static const quicV1 = Protocol(
    name: 'quic-v1',
    code: 0x01CD,
    size: 0,
  );

  static const webtransport = Protocol(
    name: 'webtransport',
    code: 0x01D1,
    size: 0,
  );

  static const certhash = Protocol(
    name: 'certhash',
    code: 0x01D2,
    size: -1,
  );

  static const sni = Protocol(
    name: 'sni',
    code: 0x01C1,
    size: -1,
  );

  // WebSocket addresses: /tcp/<port>/ws, /tcp/<port>/tls/ws (written /wss
  // by some peers), /tcp/<port>/tls/sni/<host>/ws. dart_libp2p has no
  // WebSocket transport, but a go-libp2p peer announces these in identify,
  // its signed peer record and relay reservations, and an unknown code makes
  // the whole address (and the whole signed record) unreadable.
  static const tls = Protocol(
    name: 'tls',
    code: 0x01C0,
    size: 0,
  );

  static const ws = Protocol(
    name: 'ws',
    code: 0x01DD,
    size: 0,
  );

  static const wss = Protocol(
    name: 'wss',
    code: 0x01DE,
    size: 0,
  );

  static const circuit = Protocol(
    name: 'p2p-circuit',
    code: 0x0122,
    size: 0,
  );

  static const webrtc = Protocol(
    name: 'webrtc',
    code: 0x0119,
    size: 0,
  );

  static const webrtcDirect = Protocol(
    name: 'webrtc-direct',
    code: 0x0118,
    size: 0,
  );

  static const udx = Protocol(
    name: 'udx',
    code: 0x0300, // Assigned a private use code for now
    size: 0,
  );

  // Bluetooth LE: /ble/<token>/p2p/<peer id>. The token names a nearby
  // device that the BLE transport (package dart_libp2p_ble) has discovered;
  // it has meaning only on the device that discovered it. The code is in the
  // multicodec private-use range (0x300000-0x3fffff). It is built in, so
  // that a peer without the BLE transport can still read a signed peer
  // record that lists a /ble address.
  static const ble = Protocol(
    name: 'ble',
    code: 0x300b1e,
    size: -1,
  );

  static final Map<String, Protocol> _protocols = {
    'ip4': ip4,
    'tcp': tcp,
    'udp': udp,
    'ip6': ip6,
    'dns': dns,
    'dns4': dns4,
    'dns6': dns6,
    'dnsaddr': dnsaddr,
    'p2p': p2p,
    'unix': unix,
    'quic-v1': quicV1,
    'webtransport': webtransport,
    'certhash': certhash,
    'sni': sni,
    'tls': tls,
    'ws': ws,
    'wss': wss,
    'p2p-circuit': circuit,
    'webrtc': webrtc,
    'webrtc-direct': webrtcDirect,
    'udx': udx,
    'ble': ble,
  };

  /// Adds [protocol] to the registry, so that [MultiAddr] can parse, print
  /// and encode addresses that use it.
  ///
  /// A transport in another package calls this for a protocol that
  /// dart_libp2p does not know. The protocol must have no value (size 0) or a
  /// variable-length string value (size -1); a fixed-size value needs a codec
  /// that only dart_libp2p can supply.
  ///
  /// Registering an equal protocol again does nothing. Throws [ArgumentError]
  /// if a different protocol already has the same name or code, or if the
  /// protocol has a fixed-size value.
  static void register(Protocol protocol) {
    if (protocol.size > 0) {
      throw ArgumentError('Cannot register ${protocol.name}: fixed-size values are not supported');
    }
    final byNameMatch = _protocols[protocol.name];
    if (byNameMatch != null) {
      if (byNameMatch.code == protocol.code &&
          byNameMatch.size == protocol.size &&
          byNameMatch.path == protocol.path) {
        return;
      }
      throw ArgumentError('Protocol name ${protocol.name} is already registered with code ${byNameMatch.code}');
    }
    final byCodeMatch = byCode(protocol.code);
    if (byCodeMatch != null) {
      throw ArgumentError('Protocol code ${protocol.code} is already registered as ${byCodeMatch.name}');
    }
    _protocols[protocol.name] = protocol;
  }

  /// Returns the protocol for the given name
  static Protocol? byName(String name) => _protocols[name];

  /// Returns the protocol for the given code, or null if no protocol has it
  static Protocol? byCode(int code) {
    for (final p in _protocols.values) {
      if (p.code == code) return p;
    }
    return null;
  }

  /// Returns true if the protocol is supported
  static bool isSupported(String name) => _protocols.containsKey(name);

  /// Returns a list of all supported protocols
  static List<Protocol> get all => _protocols.values.toList();
}
