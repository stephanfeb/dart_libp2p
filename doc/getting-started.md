# Getting Started with Dart Libp2p

This guide will walk you through the process of setting up two libp2p nodes, connecting them, and sending a message using the Ping protocol.

## 1. Project Setup

First, ensure you have a Dart project set up (Dart SDK 3.5 or later). Add `dart_libp2p` to your `pubspec.yaml`:

```yaml
dependencies:
  dart_libp2p: ^4.12.2
```

## 2. Creating a Libp2p Host

A `Host` is the central object in libp2p, representing a single peer in the network. Here's how to create one. We'll use the `Libp2p.new_` convenience method, which simplifies the configuration process.

```dart
import 'package:dart_libp2p/dart_libp2p.dart' hide Option;
import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/p2p/protocol/ping/ping.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';

Future<Host> createHost() async {
  // Generate an Ed25519 key pair for this node. Its public key gives the peer ID.
  final keyPair = await generateEd25519KeyPair();

  // The transports and the host share one connection manager.
  final connManager = ConnectionManager();

  // Create a new libp2p host.
  final host = await Libp2p.new_([
    // Set the identity (private key)
    Libp2p.identity(keyPair),

    // Share the connection manager with the transport
    Libp2p.connManager(connManager),

    // Set the transport
    Libp2p.transport(TCPTransport(connManager: connManager)),

    // Set the listen addresses (port 0 picks a free port)
    Libp2p.listenAddrs([MultiAddr('/ip4/127.0.0.1/tcp/0')]),

    // Set the security protocol (Noise is also the default)
    Libp2p.security(await NoiseSecurity.create(keyPair)),

    // Set the stream multiplexer (Yamux is also the default)
    Libp2p.muxer(
      '/yamux/1.0.0',
      (conn, isClient) =>
          YamuxSession(conn as TransportConn, const MultiplexerConfig(), isClient),
    ),
  ]);

  // Libp2p.new_ does not listen yet: start() binds the listen addresses
  // and starts the host's services (Identify, Ping, ...).
  await host.start();

  return host;
}
```

The barrel `package:dart_libp2p/dart_libp2p.dart` also exports a routing `Option` type, which clashes with the configuration `Option` from `config/config.dart`. Hide it, as above, or import one of the two libraries with a prefix.

The security and multiplexer options are shown for completeness: without them, the host uses Noise and Yamux anyway. You must give at least one transport.

## 3. Connecting Two Nodes

Now, let's create two hosts and have one connect to the other.

```dart
void main() async {
  // Create two hosts.
  final host1 = await createHost();
  final host2 = await createHost();

  print('Host 1 Peer ID: ${host1.id}');
  print('Host 1 Listen Addrs: ${host1.network.listenAddresses}');
  print('Host 2 Peer ID: ${host2.id}');
  print('Host 2 Listen Addrs: ${host2.network.listenAddresses}');

  // To connect, host1 needs host2's peer ID and listen addresses.
  final serverAddrInfo = AddrInfo(host2.id, host2.network.listenAddresses);

  // Connect host1 to host2
  await host1.connect(serverAddrInfo);
  print('Host 1 connected to Host 2 successfully!');

  // ... now you can open streams and exchange data (see section 4).

  // Clean up. The program exits once both hosts are closed.
  await host1.close();
  await host2.close();
}
```

The example uses `host.network.listenAddresses`, the addresses the host is bound to. `host.addrs`, the addresses a host advertises to other peers, leaves out loopback (`127.0.0.1`, `::1`) and unspecified (`0.0.0.0`, `::`) addresses, so for these two hosts it is empty. Between machines, listen on `0.0.0.0` and hand out `host.addrs`.

## 4. Sending Data with the Ping Protocol

Libp2p uses protocols to define how peers communicate. The Ping protocol is a simple way to check connectivity and measure latency.

The `BasicHost` answers pings by default. To send one, make a `PingService` for the host (a `BasicHost` also has one as `pingService`) and replace the `// ...` line in `main` with:

```dart
  // ping() returns a stream of results; take the first one.
  final result = await PingService(host1).ping(host2.id).first;

  if (result.hasError) {
    print('Ping failed: ${result.error}');
  } else {
    print('Ping successful! RTT: ${result.rtt}');
  }
```

Run the program with `dart run`. It prints the two peer IDs and addresses, the connection, the round-trip time, and exits.

This example demonstrates the fundamental workflow of creating nodes, connecting them, and using a protocol to communicate. From here, you can explore more complex protocols and build sophisticated peer-to-peer applications.
