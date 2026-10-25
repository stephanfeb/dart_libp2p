# Connection Security

In a peer-to-peer network, ensuring that communication is private and authentic is critical. Libp2p provides a modular security layer that allows peers to establish secure channels over raw network connections.

This library provides an implementation of the **Noise Protocol Framework**, which is the default security protocol for libp2p.

## The `SecurityProtocol` Interface

All security protocols implement the `SecurityProtocol` interface, which has two main responsibilities:

-   **`Future<SecuredConnection> secureOutbound(TransportConn connection)`**: Secures an outgoing connection.
-   **`Future<SecuredConnection> secureInbound(TransportConn connection)`**: Secures an incoming connection.

Both methods take a raw `TransportConn` and, after a successful handshake, return a `SecuredConnection`. This `SecuredConnection` wraps the raw connection, transparently encrypting all data written to it and decrypting all data read from it.

## The Noise Protocol

-   **Protocol ID**: `/noise`
-   **Implementation**: `NoiseSecurity`

Noise is a modern, lightweight, and formally verified cryptographic framework. Libp2p uses the `XX` handshake pattern from Noise, which provides mutual authentication.

### The `XX` Handshake

The `XX` handshake is a three-part process where both peers exchange ephemeral public keys and prove ownership of their long-term identity keys.

Here's a simplified overview of the process:

1.  **Handshake Messages**: The client and server exchange three handshake messages. During this exchange, they generate and trade ephemeral keys.
2.  **Session Keys**: After the three messages, both peers can derive two shared secret keys: one for sending data (client-to-server) and one for receiving data (server-to-client).
3.  **Identity Exchange**: After establishing the encrypted channel, the peers exchange their libp2p identity public keys and signatures over the encrypted channel. This proves to each peer that they are talking to the `PeerId` they expect.

The result of a successful Noise handshake is a `SecuredConnection` where:
-   All traffic is encrypted with strong symmetric ciphers (ChaChaPoly).
-   The identity of the remote peer has been cryptographically verified.

### Usage

The `NoiseSecurity` protocol is enabled by default when you use the `Libp2p.new_` constructor. You can also configure it manually.

```dart
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/core/crypto/keys.dart';

// You need an identity key pair for your host
KeyPair myKeyPair = await generateKeyPair();

// Add the Noise protocol to your configuration
final config = [
  Libp2p.identity(myKeyPair),
  Libp2p.security(await NoiseSecurity.create(myKeyPair)),
  // ... other options
];
```

Because it's the default, you often don't need to specify it at all. The library will create and configure it for you as long as an identity is provided.

## Connection Gating

A connection gater decides which peers and addresses the host connects to. It works as in go-libp2p. Give one to the host with `Libp2p.connectionGater`:

```dart
import 'package:dart_libp2p/p2p/network/conn_gater.dart';

final gater = BasicConnGater()
  ..blockPeer(badPeerId)                       // a peer
  ..blockAddr(MultiAddr('/ip4/203.0.113.7'))   // all ports of an IP
  ..blockSubnet('198.51.100.0/24');            // a subnet

final host = await Libp2p.new_([
  // ... other options
  Libp2p.connectionGater(gater),
]);
```

You can change the blocks while the host runs. A block applies to the next dial or connection; it does not close existing connections.

The host asks the gater at five points. If the gater says no, the host does not make the connection or closes it:

| Method | When | Known at that point |
|---|---|---|
| `interceptPeerDial` | Before a dial to a peer | Peer ID |
| `interceptAddrDial` | For each address of the dial | Peer ID, address |
| `interceptAccept` | When an inbound connection arrives | Addresses only (the peer is not known yet) |
| `interceptSecured` | After the security handshake, both directions | Authenticated peer ID |
| `interceptUpgraded` | Before the swarm adds the connection | Full connection |

A dial that the gater rejects throws `GaterDisallowedConnectionException`. An address that `interceptAddrDial` rejects is left out of the dial; when no address is left, the dial fails. `host.connect` to a peer that is already connected returns at once, as in go-libp2p; it does not ask the gater again.

To write a different policy, implement `ConnGater` (`package:dart_libp2p/core/connmgr/conn_gater.dart`). For connection limits, use the resource manager (see [resource-manager.md](resource-manager.md)), not a gater.
