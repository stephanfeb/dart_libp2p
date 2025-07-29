# Dart Libp2p

[![Dart](https://img.shields.io/badge/Dart-3.5+-blue.svg)](https://dart.dev/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A comprehensive Dart implementation of the [libp2p](https://libp2p.io/) networking stack, providing a modular and extensible foundation for building peer-to-peer applications.

## 🚀 Features

- **Modular Architecture**: Pluggable transports, security protocols, and stream multiplexers
- **Multiple Transports**: TCP and custom UDX (UDP-based) transport support
- **Security**: Noise protocol for encrypted and authenticated connections
- **Stream Multiplexing**: Yamux for efficient multi-stream communication
- **Peer Discovery**: mDNS and routing-based peer discovery mechanisms
- **Protocol Support**: Built-in support for Ping, Identify, and other core libp2p protocols
- **Resource Management**: Built-in protection against resource exhaustion
- **Event System**: Comprehensive event bus for monitoring network activity
- **NAT Traversal**: Hole punching and relay support for NAT traversal

## 📦 Installation

Add `dart_libp2p` to your `pubspec.yaml`:

```yaml
dependencies:
  dart_libp2p: ^0.5.2
```

Then run:

```bash
dart pub get
```

## 🏃‍♂️ Quick Start

Here's a simple example of creating two libp2p nodes and connecting them:

```dart
import 'package:dart_libp2p/dart_libp2p.dart';
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';

Future<Host> createHost() async {
  final keyPair = await generateKeyPair();
  
  return await Libp2p.new_([
    Libp2p.identity(keyPair),
    Libp2p.listenAddrs([
      await Multiaddr.fromString('/ip4/127.0.0.1/tcp/0'),
    ]),
    Libp2p.transport(TcpTransport()),
    Libp2p.security(NoiseSecurityProtocol()),
    Libp2p.muxer('/yamux/1.0.0', (conn, isClient) => YamuxSession(conn, MultiplexerConfig(), isClient)),
  ]);
}

void main() async {
  final host1 = await createHost();
  final host2 = await createHost();

  print('Host 1: ${host1.peerId}');
  print('Host 2: ${host2.peerId}');

  // Connect host1 to host2
  await host1.connect(AddrInfo(host2.peerId, host2.addrs));
  print('Connected successfully!');

  // Clean up
  await host1.close();
  await host2.close();
}
```

## 🏗️ Architecture

Dart Libp2p follows a layered architecture where each component provides services to the layer above it:

```
┌─────────────────────────────────────┐
│           Application               │
│        (Your Custom Protocols)      │
├─────────────────────────────────────┤
│              Host                   │
├─────────────────────────────────────┤
│           Network/Swarm             │
├─────────────────────────────────────┤
│            Upgrader                 │
├─────────────────────────────────────┤
│  Multiplexer (Yamux) │ Security     │
│                      │ (Noise)      │
├─────────────────────────────────────┤
│           Transport                 │
│        (TCP, UDX)                   │
└─────────────────────────────────────┘
```

### Core Components

- **Host**: Central entry point that ties all components together
- **Network/Swarm**: Manages connections, peers, and upgrade lifecycle
- **Upgrader**: Handles security and multiplexing negotiation
- **Transport**: Establishes raw connections (TCP, UDX)
- **Security**: Encrypts and authenticates connections (Noise)
- **Multiplexer**: Enables multiple streams over single connections (Yamux)

## 🚛 Transports

### TCP Transport
- **Protocols**: `/ip4/tcp`, `/ip6/tcp`
- **Use Case**: Reliable, widely available transport for most applications
- **Best For**: Data centers, servers with public IPs

### UDX Transport
- **Protocols**: `/ip4/udp/udx`, `/ip6/udp/udx`
- **Use Case**: Custom UDP-based transport with built-in reliability
- **Best For**: NAT traversal, hole punching, peer-to-peer connections

> **Note**: This implementation does not support QUIC. Instead, we've opted for a custom `dart-udx` implementation that provides similar benefits for peer-to-peer networking.

## 🔐 Security

Dart Libp2p uses the Noise protocol for securing connections:

- **Encryption**: All communication is encrypted
- **Authentication**: Remote peer identity is verified
- **Perfect Forward Secrecy**: Session keys are ephemeral
- **Handshake**: Efficient key exchange and authentication

## 📚 Documentation

For detailed documentation, visit the [docs](./doc/) directory:

- **[Getting Started](./doc/getting-started.md)**: Step-by-step setup guide
- **[Architecture](./doc/architecture.md)**: Detailed architecture overview
- **[Configuration](./doc/configuration.md)**: Configuration options
- **[Host](./doc/host.md)**: Host component documentation
- **[Transports](./doc/transports.md)**: Transport layer details
- **[Security](./doc/security.md)**: Security protocol information
- **[Multiplexing](./doc/multiplexing.md)**: Stream multiplexing
- **[Protocols](./doc/protocols.md)**: Built-in protocol documentation
- **[Peerstore](./doc/peerstore.md)**: Peer information management
- **[Event Bus](./doc/event-bus.md)**: Event system documentation
- **[Resource Manager](./doc/resource-manager.md)**: Resource protection
- **[Cookbook](./doc/cookbook.md)**: Practical examples and recipes

## 🧪 Examples

Check out the [examples](./bin/) directory for working examples:

- **Ping App**: Basic ping/pong communication between nodes
- **Chat Application**: Simple peer-to-peer chat implementation

## 🧪 Testing

Run the test suite:

```bash
dart test
```

## 🤝 Contributing

We welcome contributions! Please see our contributing guidelines and code of conduct.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- [libp2p](https://libp2p.io/) - The original protocol specification
- [dart-udx](https://pub.dev/packages/dart_udx) - Custom UDP transport implementation
- The libp2p community for inspiration and guidance

## 🔗 Links

- [libp2p.io](https://libp2p.io/) - Official libp2p documentation
- [Dart](https://dart.dev/) - Dart programming language
- [pub.dev](https://pub.dev/packages/dart_libp2p) - Package on pub.dev 
