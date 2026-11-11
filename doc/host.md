# The Host

The `Host` is the central component in a libp2p application. It represents a single node in the peer-to-peer network and serves as the main entry point for all libp2p interactions. It bundles together all the other major components, such as the `Network`, `Peerstore`, and `ProtocolSwitch` (Mux), providing a unified API.

A `Host` can be thought of as both a client and a server. It can initiate connections and protocols with other peers (acting as a client) and also listen for and respond to incoming connections and protocols (acting as a server).

## Key Responsibilities

- **Identity**: Every host has a unique `PeerId` that identifies it on the network.
- **Networking**: Manages underlying network connections through the `Network` interface.
- **Peer & Address Management**: Keeps track of other peers, their addresses, and public keys using the `Peerstore`.
- **Protocol Handling**: Dispatches incoming streams to the correct protocol handlers using the `ProtocolSwitch`.
- **Stream Creation**: Opens new communication streams to other peers for specific protocols.
- **Lifecycle Management**: Handles the startup and shutdown of the node and its services.

## The `Host` Interface

The core `Host` interface is defined in `lib/core/host/host.dart`. Here are its key methods and properties:

### Properties

- **`id`**: `PeerId`
  - The unique identifier for this host.

- **`peerStore`**: `Peerstore`
  - The host's repository for information about other peers, including their addresses and public keys.

- **`addrs`**: `List<MultiAddr>`
  - The addresses this host advertises to other peers: its listen addresses (with `0.0.0.0` and `::` replaced by the interface addresses), observed and relay addresses, passed through the `AddrsFactory`. The default factory leaves out loopback and unspecified addresses. The addresses the host is bound to are `network.listenAddresses`.

- **`network`**: `Network`
  - The underlying network interface that manages connections.

- **`mux`**: `ProtocolSwitch`
  - The protocol multiplexer that directs incoming streams to their registered handlers.

- **`connManager`**: `ConnManager`
  - The connection manager responsible for managing the lifecycle of connections.

- **`eventBus`**: `EventBus`
  - The event bus for emitting and listening to libp2p-related events.

### Methods

- **`Future<void> connect(AddrInfo pi, {Context? context})`**
  - Establishes a connection to the peer specified in the `AddrInfo` object (`id` and `addrs`). If a connection already exists, this method returns at once. Otherwise, it stores the addresses in the peerstore, dials the peer and returns after the `Identify` exchange.

- **`void setStreamHandler(ProtocolID pid, StreamHandler handler)`**
  - Registers a handler function for a specific protocol ID. When another peer opens a stream to this host with the given protocol ID, the `handler` function will be invoked to process the stream.

- **`void setStreamHandlerMatch(ProtocolID pid, bool Function(ProtocolID) match, StreamHandler handler)`**
  - Like `setStreamHandler`, but the handler also takes every protocol ID for which `match` returns true (for example, other versions of the protocol).

- **`void removeStreamHandler(ProtocolID pid)`**
  - Removes a previously registered protocol handler.

- **`Future<P2PStream> newStream(PeerId p, List<ProtocolID> pids, Context context)`**
  - Opens a new outgoing stream to a remote peer `p` for one of the specified protocol IDs `pids`. Libp2p will negotiate with the remote peer to select a mutually supported protocol from the list. If the host is not connected to `p`, it dials the addresses in the peerstore first. Pass `Context()` for the defaults; `Context().withDialPeerTimeout(...)` bounds the dial. The `Context(timeout: ...)` constructor does not bound `newStream`, so wrap the call in `Future.timeout` to limit the whole call.

- **`Future<void> start()`**
  - Starts the host, which includes initiating listening on the configured addresses and starting any configured services (like Identify, Ping, etc.). A host made with `Libp2p.new_` does not listen until you call it.

- **`Future<void> close()`**
  - Shuts down the host, gracefully closing all active connections, streams, and services. A closed host cannot be started again.

## Example: Basic Host Usage

```dart
import 'dart:convert';

import 'package:dart_libp2p/dart_libp2p.dart';

// Create and start a host (see Getting Started for full setup)
final Host myHost = await createHost();
print('Host listening on: ${myHost.network.listenAddresses}');

// Set a handler for a custom protocol
myHost.setStreamHandler('/my-protocol/1.0.0', (stream, remotePeer) async {
  print('Received a new stream from $remotePeer');
  final request = await stream.read(); // empty when the remote closed its side
  await stream.write(request);         // echo it back
  await stream.close();
});

// Connect to another peer (otherPeerInfo is an AddrInfo: peer ID and addresses)
await myHost.connect(otherPeerInfo);

// Open a stream to the other peer for our custom protocol
final P2PStream myStream = await myHost.newStream(
  otherPeerInfo.id,
  ['/my-protocol/1.0.0'],
  Context(),
);

// ... send and receive data
await myStream.write(utf8.encode('hello'));
await myStream.closeWrite();
print(utf8.decode(await myStream.read()));
await myStream.close();

// Shutdown the host
await myHost.close();
```

Register stream handlers before `start()` where you can: the first `Identify` exchange then already lists their protocols. A handler registered later reaches connected peers through an `Identify` push.
