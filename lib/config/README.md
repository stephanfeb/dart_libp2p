# Dart-libp2p Configuration System

This directory contains the configuration system for the Dart implementation of libp2p. It is modeled after the Go implementation's configuration system, but uses Dart's extension functions for a more idiomatic Dart API.

## Overview

The configuration system provides a flexible and extensible way to configure libp2p nodes. It uses a functional options pattern, which allows for flexible and readable configuration.

## Key Components

### Config Class

The `Config` class is the central component that holds all configuration options:

```dart
class Config {
  String? userAgent;
  String? protocolVersion;
  KeyPair? peerKey;
  List<Transport> transports = [];
  List<SecurityProtocol> securityProtocols = [];
  bool insecure = false;
  List<MultiAddr> listenAddrs = [];
  List<StreamMuxer> muxers = [];

  // ...
}
```

### Option Type

An `Option` is defined as a function that takes a Config and returns a FutureOr<void>:

```dart
typedef Option = FutureOr<void> Function(Config config);
```

### Extension Methods

The `ConfigOptions` extension provides methods for applying different options to a Config:

```dart
extension ConfigOptions on Config {
  Future<void> withListenAddrs(List<MultiAddr> addrs) async {
    listenAddrs.addAll(addrs);
  }

  Future<void> withSecurity(SecurityProtocol securityProtocol) async {
    if (insecure) {
      throw Exception('Cannot use security protocols with an insecure configuration');
    }
    securityProtocols.add(securityProtocol);
  }

  // ...
}
```

### Factory Functions

The `Libp2p` class provides factory functions for creating options:

```dart
class Libp2p {
  static Option listenAddrs(List<MultiAddr> addrs) {
    return (config) => config.withListenAddrs(addrs);
  }

  static Option security(SecurityProtocol securityProtocol) {
    return (config) => config.withSecurity(securityProtocol);
  }

  // ...
}
```

## Usage

There are two ways to use the configuration system:

### Method 1: Using the convenience method

```dart
import 'package:dart_libp2p/dart_libp2p.dart' hide Option;
import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';

final keyPair = await generateEd25519KeyPair();
final connManager = ConnectionManager();

final host = await Libp2p.new_([
  // Set the identity (private key)
  Libp2p.identity(keyPair),

  // Share one connection manager between the host and its transports
  Libp2p.connManager(connManager),

  // Set the transport (the only option without a default)
  Libp2p.transport(TCPTransport(connManager: connManager)),

  // Set the listen addresses
  Libp2p.listenAddrs([MultiAddr('/ip4/0.0.0.0/tcp/9000')]),

  // Set the user agent
  Libp2p.userAgent('my-libp2p-node/1.0.0'),

  // Noise security and the Yamux multiplexer are added by default.
]);

// Start the host: Libp2p.new_ does not listen
await host.start();
```

The barrel `dart_libp2p.dart` also exports a routing `Option` type; hide it, or import `config.dart` with a prefix.

### Method 2: Creating a Config and applying options

This method follows the pattern used in the Go implementation:

```dart
import 'package:dart_libp2p/config/defaults.dart'; // applyDefaults

// Step 1: Create a new Config
final config = Libp2p.newConfig();

// Step 2: Apply configuration options to the Config
await config.apply([
  Libp2p.identity(keyPair),
  Libp2p.connManager(connManager),
  Libp2p.transport(TCPTransport(connManager: connManager)),
  Libp2p.listenAddrs([MultiAddr('/ip4/0.0.0.0/tcp/9000')]),
  Libp2p.userAgent('my-libp2p-node/1.0.0'),
]);

// Apply defaults for any options that weren't specified
await applyDefaults(config);

// Step 3: Create a new Host from the Config (this consumes the Config)
final host = await config.newNode();

// Start the host
await host.start();
```

## Default Options

The configuration system includes default options that are applied if the user doesn't specify certain options. These defaults are defined in the `defaults.dart` file.

## Extending the Configuration System

To add new configuration options:

1. Add a new field to the `Config` class
2. Add a new extension method to the `ConfigOptions` extension
3. Add a new factory function to the `Libp2p` class
4. Update the `_validate` method in the `Config` class if necessary
5. Update the `applyDefaults` function in the `defaults.dart` file if necessary
