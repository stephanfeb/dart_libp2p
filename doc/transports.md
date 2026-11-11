# Transports

Transports are the foundation of the libp2p network stack, providing the mechanism for sending and receiving data over the actual network. They are responsible for establishing connections between peers. Libp2p is transport-agnostic, meaning it can run over any number of underlying transport protocols.

## The `Transport` Interface

All transport implementations in dart-libp2p adhere to the `Transport` interface defined in `lib/p2p/transport/transport.dart`. This ensures that the host can interact with any transport in a consistent way.

### Key Methods

- **`Future<Conn> dial(MultiAddr addr, {Duration? timeout, bool simultaneousConnect = false})`**
  - Attempts to establish an outgoing connection to a peer at the given `MultiAddr`. If successful, it returns a `Conn` object representing the raw, un-upgraded connection.

- **`Future<Listener> listen(MultiAddr addr)`**
  - Binds to the given `MultiAddr` and starts listening for incoming connections. It returns a `Listener` object that can be used to accept these connections.

- **`bool canDial(MultiAddr addr)`** and **`bool canListen(MultiAddr addr)`**
  - Return `true` if the transport can handle the protocols specified in the given `MultiAddr` for dialing or for listening.

- **`List<String> get protocols`**
  - Returns a list of protocol strings that this transport supports (e.g., `/ip4/tcp`).

## Connection Upgrading

When a transport establishes a connection (either through `dial` or `listen`), it returns a raw `TransportConn`. This connection is not yet secure or capable of handling multiple streams. The libp2p `Swarm` then uses an `Upgrader` to layer on security and stream multiplexing.

The upgrade process is as follows:
1.  A raw connection is established by the transport.
2.  A security protocol (like Noise) is negotiated to create a secure channel.
3.  A stream multiplexer (like Yamux) is negotiated over the secure channel.

The final result is a fully upgraded, secure, and multiplexed `Conn` that the `Host` can use to open streams.

### Transports that upgrade their own connections

Some transports secure and multiplex connections themselves: a WebRTC connection is encrypted by DTLS and carries its streams as data channels. Such a transport returns an `UpgradedTransportConn` (`lib/core/network/transport_conn.dart`, like go-libp2p's `CapableConn`), which implements both `TransportConn` and `MuxedConn`. The swarm uses it as it is, on dial and on accept, without the upgrader; its `remotePeer` must already be authenticated by the transport.

Streams of such connections can implement `PushbackStream` (`lib/core/network/mux.dart`), so multistream-select can return bytes it read past its negotiation to the stream.

## Available Transports

This library provides two transport implementations. Two more are separate packages: the libp2p WebRTC transport (`/p2p-circuit/webrtc`) is [dart_libp2p_webrtc](https://github.com/stephanfeb/dart-libp2p-webrtc), and the Bluetooth LE transport (`/ble`) is [dart_libp2p_ble](https://github.com/stephanfeb/dart-libp2p-ble):

### TCP Transport

-   **Class**: `TCPTransport`
-   **Protocols**: `/ip4/tcp`, `/ip6/tcp`
-   **Description**: The standard TCP transport. It's reliable, widely available, and a good default choice for most applications, especially in data centers or between servers with public IP addresses.

**Usage:**

```dart
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';

final connManager = ConnectionManager();

// Add TCP transport to your configuration
final config = [
  Libp2p.connManager(connManager),
  Libp2p.transport(TCPTransport(connManager: connManager)),
  Libp2p.listenAddrs([MultiAddr('/ip4/0.0.0.0/tcp/4001')]),
  // ... other options
];
```

Make the `TCPTransport` without a `resourceManager`: the host then gives it its own (see [Resource Manager](resource-manager.md#transports)).

### UDX Transport

-   **Class**: `UDXTransport`
-   **Protocols**: `/ip4/udp/udx`, `/ip6/udp/udx`
-   **Description**: A custom transport protocol built on top of UDP ([dart_udx](https://pub.dev/packages/dart_udx)). UDX provides reliable, ordered, congestion-controlled streams over UDP. Like a TCP connection, a UDX connection is secured with Noise and multiplexed with Yamux. UDX is particularly effective for hole punching, making it excellent for peer-to-peer connections where nodes are behind NATs or firewalls.

**Usage:**

```dart
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';

final connManager = ConnectionManager();

// Add UDX transport to your configuration
final config = [
  Libp2p.connManager(connManager),
  Libp2p.transport(UDXTransport(connManager: connManager)), // connManager is required
  Libp2p.listenAddrs([MultiAddr('/ip4/0.0.0.0/udp/4001/udx')]),
  // ... other options
];
```

Pass the same `ConnectionManager` to `Libp2p.connManager` and to every transport.

### Bluetooth LE Transport (separate package)

-   **Class**: `BleTransport`, in [dart_libp2p_ble](https://github.com/stephanfeb/dart-libp2p-ble)
-   **Protocols**: `/ble/<token>`
-   **Description**: Connects phones and Macs near each other without a network (Android, iOS, macOS). Each connection is one GATT link that the upgrader secures with Noise and multiplexes with yamux, as on TCP. `BleDiscovery` connects the nodes in range, and gossipsub relays across the partial mesh.

**Usage:**

```dart
import 'package:dart_libp2p_ble/dart_libp2p_ble.dart';

final ble = BleTransport(radio: BluetoothLowEnergyRadio(), localPeer: peerId);
final config = [
  Libp2p.transport(ble),
  Libp2p.listenAddrs([ble.listenAddr]), // /ble/<token>
  // ... other options
];
```

The transport uses the `/ble` multiaddr protocol (code `0x300b1e`, private-use range), which this library registers since 4.10.0. Another package can register its own protocol with `Protocols.register`.

You can configure your host to use multiple transports simultaneously. Libp2p will automatically choose the best available transport when connecting to a peer based on the addresses stored in the `Peerstore`.

### Addresses the transports dial

The TCP and UDX transports dial `/ip4` and `/ip6` addresses only; they do not resolve `/dns4`, `/dns6` or `/dnsaddr` names, so a peer listed only by a DNS address is not dialled. Resolve the name yourself (for example with `InternetAddress.lookup` from `dart:io`) and build an `/ip4` or `/ip6` address. There is no WebSocket, QUIC or WebTransport transport in this library.
