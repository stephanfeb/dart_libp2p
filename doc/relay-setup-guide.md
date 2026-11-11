# Circuit Relay v2 Setup Guide

This guide explains how to set up Circuit Relay v2 in dart-libp2p, based on the go-libp2p implementation with nested security and multiplexing.

## Table of Contents

1. [Running a Relay Server](#running-a-relay-server)
2. [Using Circuit Relay (AutoRelay Client)](#using-circuit-relay-autorelay-client)
3. [Dialing Through Circuit Relay](#dialing-through-circuit-relay)
4. [Architecture and Data Flow](#architecture-and-data-flow)
5. [Testing and Verification](#testing-and-verification)
6. [Troubleshooting](#troubleshooting)

---

## Running a Relay Server

The examples use these imports. The barrel also exports a routing `Option` type, so it is imported with `hide Option`:

```dart
import 'package:dart_libp2p/dart_libp2p.dart' hide Option;
import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
```

### Basic Setup (Always-On Relay)

For a dedicated relay server that's always publicly reachable:

```dart
// The relay's peer ID is part of every address that points at it, so keep its key.
final keyPair = await loadRelayKey();
final cm = ConnectionManager();

final relay = await Libp2p.new_([
  Libp2p.identity(keyPair),
  Libp2p.connManager(cm),
  Libp2p.transport(UDXTransport(connManager: cm)),
  Libp2p.transport(TCPTransport(connManager: cm)),
  Libp2p.listenAddrs([
    MultiAddr('/ip4/0.0.0.0/udp/4001/udx'),
    MultiAddr('/ip4/0.0.0.0/tcp/4001'),
  ]),
  Libp2p.relay(true),                            // Enable the relay service
  Libp2p.forceReachability(Reachability.public), // Declare it public (skips ambient probing)
  // Libp2p.autoNATv2AllowPrivateAddrs(),        // Only on a local test network
]);

await relay.start();
// The relay service starts and registers the hop protocol.
// The AutoNAT v2 server (on by default) answers reachability checks for other peers.
for (final addr in relay.addrs) {
  print('$addr/p2p/${relay.id.toBase58()}'); // hand these to the peers
}
```

`loadRelayKey` stands for your own code that loads the relay's saved key pair (`Ed25519PrivateKey.unmarshal` of the bytes from `privateKey.marshal()`). If the machine cannot see its public address on an interface (a cloud VM behind a 1:1 NAT), add `Libp2p.addrsFactory(...)` to announce `/ip4/<public IP>/udp/4001/udx` and `/ip4/<public IP>/tcp/4001`. Open UDP and TCP port 4001 in the firewall.

**What happens automatically:**
1. `BasicHost` sees `forceReachability` set to `Reachability.public`
2. Emits `EvtLocalReachabilityChanged(reachability: Reachability.public)` during startup
3. `RelayManager` receives the event and starts the relay service
4. Relay service registers the `/libp2p/circuit/relay/0.2.0/hop` protocol handler
5. AutoNAT v2 server starts and advertises `/libp2p/autonat/2/*` protocols
6. AmbientAutoNATv2 client is **skipped** (to avoid contradicting forced status)
7. Other peers can discover this node as a relay and use it for reachability checks

`Libp2p.relay(true)` alone does nothing until the host is public. Turning AutoNAT off does not make it public; use `forceReachability` on a dedicated relay.

#### Relay limits

A dart-libp2p relay accepts up to 128 reservations and 128 relayed connections. Each reservation lasts 1 hour, and each relayed connection may carry 1 MiB of data for at most 1 hour; each peer may make 10 HOP requests per minute. These limits are fixed: no `Libp2p` option changes them. (A go-libp2p relay allows 128 KiB and 2 minutes per relayed connection.) Use relayed connections for coordination and small messages, and move bulk data to a direct connection (see hole punching) once there is one.

### Dynamic Relay (With AutoNAT Detection)

For relays that should only operate when publicly reachable (e.g., mobile nodes):

```dart
import 'package:dart_libp2p/p2p/host/autonat/ambient_config.dart';

final cm = ConnectionManager();
final host = await Libp2p.new_([
  Libp2p.connManager(cm),
  Libp2p.transport(UDXTransport(connManager: cm)),
  Libp2p.listenAddrs([MultiAddr('/ip4/0.0.0.0/udp/0/udx')]),
  Libp2p.relay(true), // Enable the relay service; AutoNAT is on by default
  Libp2p.ambientAutoNATv2Config(const AmbientAutoNATv2Config(
    bootDelay: Duration(seconds: 5),       // Wait before first probe
    retryInterval: Duration(seconds: 30),  // Retry on failure
    refreshInterval: Duration(minutes: 5), // Refresh when stable
  )),
]);

await host.start();
// The relay service starts and stops with the reachability AmbientAutoNATv2 finds
```

**AmbientAutoNATv2** will:
- Ask connected AutoNAT v2 servers to dial this host's public, direct addresses
- Build confidence through multiple successful probes (confidence levels 0-3)
- Emit `EvtLocalReachabilityChanged` when status changes
- Start relay service when you become publicly reachable
- Stop relay service when you become privately reachable (e.g., network change)

**No manual event emission needed** - it's all automatic!

---

## Using Circuit Relay (AutoRelay Client)

### Recommended Setup

Give the host the relays it should use. AutoRelay starts as soon as the host starts, while reachability is still unknown, and makes a reservation on each connected relay. It stops only if AutoNAT finds the host publicly reachable.

```dart
import 'package:dart_libp2p/p2p/host/autorelay/autorelay.dart'; // EvtAutoRelayAddrsUpdated

final cm = ConnectionManager();
final host = await Libp2p.new_([
  Libp2p.connManager(cm),
  Libp2p.transport(UDXTransport(connManager: cm)),
  Libp2p.transport(TCPTransport(connManager: cm)),
  Libp2p.listenAddrs([
    MultiAddr('/ip4/0.0.0.0/udp/0/udx'),
    MultiAddr('/ip4/0.0.0.0/tcp/0'),
  ]),
  Libp2p.autoRelay(true), // Enable the AutoRelay client
  Libp2p.relayServers([   // Dialled during start(); /p2p/<relay peer ID> is required
    '/ip4/203.0.113.7/udp/4001/udx/p2p/12D3KooW...',
    '/ip4/198.51.100.20/tcp/4001/p2p/12D3KooW...',
  ]),
  Libp2p.observedAddrActivationThreshold(1), // Trust the relay's view of our public address
]);

// Print the circuit addresses as AutoRelay finds them
final sub = host.eventBus.subscribe(EvtAutoRelayAddrsUpdated);
sub.stream.listen((dynamic e) {
  if (e is! EvtAutoRelayAddrsUpdated) return;
  for (final addr in e.advertisableAddrs.where((a) => a.hasProtocol('p2p-circuit'))) {
    print('Reachable at $addr'); // .../p2p/<relay>/p2p-circuit/p2p/<self>
  }
});

await host.start();
```

Relay addresses must use `/ip4` or `/ip6`: the TCP and UDX transports do not resolve DNS names (`/dns4/...`), so resolve a relay's host name yourself before you build its address.

**What happens automatically:**
1. During `host.start()`, the host connects to each configured relay server (10 seconds each; a failed connection is logged and skipped)
2. AutoRelay starts at once, because reachability is still unknown
3. It makes a reservation on each connected peer that speaks the hop protocol, and refreshes it before it expires
4. It advertises the circuit addresses: they appear in `host.addrs`, in Identify and in the signed peer record, and `EvtAutoRelayAddrsUpdated` carries them
5. AmbientAutoNATv2 checks the host's public, direct addresses with the relays' AutoNAT v2 servers; if the host turns out to be public, AutoRelay stops

`observedAddrActivationThreshold(1)` lets the host take its public address from the address one peer (the relay) observes; by default 4 peers must agree. Without a public address, hole punching has nothing to offer the other peer.

### Connecting to a Relay Yourself

Instead of `relayServers`, you can connect to a relay after `start()`; AutoRelay makes a reservation as soon as the connection is up. AutoRelay books again when a relay connection comes back, but it does not dial a relay that went away: reconnect it yourself.

```dart
final relayInfo = AddrInfo.fromMultiaddr(
    MultiAddr('/ip4/203.0.113.7/udp/4001/udx/p2p/12D3KooW...'));
await host.connect(relayInfo);
```

AutoRelay also works with `Libp2p.autoNAT(false)`: reachability then stays unknown, and AutoRelay keeps its reservations. You do not need to emit `EvtLocalReachabilityChanged` yourself.

---

## Dialing Through Circuit Relay

The dialling host needs `Libp2p.relay(true)` or `Libp2p.autoRelay(true)`: either one registers the circuit transport (`CircuitV2Client`). The destination must hold a reservation on the relay, or the dial fails with `NO_RESERVATION`.

### Understanding Circuit Addresses

AutoRelay advertises **full circuit addresses**, which already end in the destination's peer ID:
```
/ip4/203.0.113.7/udp/4001/udx/p2p/RELAY_PEER_ID/p2p-circuit/p2p/DEST_PEER_ID
```

Dial them as they are; do not append another `/p2p/DEST_PEER_ID`. If you know only the relay's address, build the circuit address from it:

```dart
// The destination's circuit addresses, for example learnt from Identify or the DHT
final destAddrs = await host.peerStore.addrBook.addrs(destPeerId);
final circuitAddrs = destAddrs.where((a) => a.hasProtocol('p2p-circuit')).toList();

// Or build them from relay addresses: <relay addr>/p2p/<relay>/p2p-circuit/p2p/<dest>
final viaRelay = [
  for (final r in relayAddrs) MultiAddr('$r/p2p-circuit/p2p/${destPeerId.toBase58()}'),
];

await host.connect(AddrInfo(destPeerId, [...circuitAddrs, ...viaRelay]));
```

### Forcing Circuit Relay Usage

When a peer has both direct and relay addresses, the host tries the direct ones first. To ensure connections use circuit relay (not direct connection):

```dart
// Clear existing addresses to prevent direct dial
await host.peerStore.addrBook.clearAddrs(destPeerId);

// Add ONLY circuit addresses
await host.peerStore.addrBook.addAddrs(
  destPeerId,
  viaRelay,
  const Duration(hours: 1),
);

// Now a new connection will use circuit relay
await host.connect(AddrInfo(destPeerId, viaRelay));
```

### Using Circuit Connections

Once connected, use the connection normally:

```dart
// Ping through relay
final result = await PingService(host).ping(destPeerId).first;
print('Ping RTT: ${result.rtt?.inMilliseconds}ms');

// Verify connection is relayed
final conns = host.network.connsToPeer(destPeerId);
final isRelayed = conns.any((c) => c.remoteMultiaddr.hasProtocol('p2p-circuit'));
print('Connection is relayed: $isRelayed');

// Use any protocol - it works transparently through the relay
final stream = await host.newStream(destPeerId, ['/my-protocol/1.0.0'], Context());
```

`PingService` is in `package:dart_libp2p/p2p/protocol/ping/ping.dart`. A relayed connection is limited (see [Relay limits](#relay-limits)). When the destination accepts a relayed connection, it starts DCUtR hole punching over UDX; on success, new streams use the direct connection.

---

## Architecture and Data Flow

### Nested Security and Multiplexing

Circuit relay in dart-libp2p follows the go-libp2p model with nested security/multiplexing layers:

```
Application Data (e.g., Ping, Custom Protocol)
    ↓
Yamux (inner)       ← Multiplexing for relayed connection
    ↓  
Noise (inner)       ← Security for relayed connection
    ↓
ONE Relay Stream    ← Single stream from HOP CONNECT
    ↓
Yamux (outer)       ← Multiplexing to relay server
    ↓
Noise (outer)       ← Security to relay server
    ↓
Transport (UDX/TCP) ← Physical connection
```

**Key Insight:** The `RelayedConn` (single stream through relay) is itself upgraded with Noise + Yamux, creating a nested structure. This allows multiple application streams over one relay connection.

### Connection Upgrade Flow

1. **Dial**: `CircuitV2Client.dial()` returns `RelayedConn` (raw connection wrapping relay stream)
2. **Check State**: `RelayedConn.state` reports empty `security` and `streamMultiplexer`
3. **Upgrade**: Swarm calls `upgrader.upgradeOutbound()` on `RelayedConn`
4. **Noise**: Upgrader negotiates Noise security on the relay stream
5. **Yamux**: Upgrader negotiates Yamux multiplexing on the secured stream
6. **Result**: Returns `UpgradedConnectionImpl` with full security/multiplexing stack

### Circuit Relay Protocol Messages

**HOP CONNECT (Source → Relay):**
```protobuf
HopMessage {
  type: CONNECT
  peer: { id: destination_peer_id, addrs: [...] }
}
```

**STOP (Relay → Destination):**
```protobuf
StopMessage {
  type: CONNECT
  peer: { id: source_peer_id, addrs: [...] }
}
```

**STOP Response (Destination → Relay):**
```protobuf
StopMessage {
  type: STATUS
  status: OK
}
```

**HOP Response (Relay → Source):**
```protobuf
HopMessage {
  type: STATUS
  status: OK
}
```

After successful handshake, the relay forwards data bidirectionally between source and destination streams.

---

## Testing and Verification

### In-Process Integration Test

See `test/p2p/host/autorelay_integration_test.dart` (for example, *Peers advertise circuit relay addresses and can ping through relay*). It runs three hosts in one process:

1. A relay with `enableRelay`, `forceReachability: Reachability.public` and AutoNAT v2 `allowPrivateAddrs()`, because all the hosts are on loopback
2. Two peers with `enableAutoRelay` and a fast `AmbientAutoNATv2Config`, which connect to the relay
3. A wait until both peers advertise `/p2p-circuit` addresses
4. Peer A's peerstore entry for peer B replaced with B's circuit addresses only
5. A ping from A to B, and a check that the connection's `remoteMultiaddr` contains `/p2p-circuit`

### Docker Integration Test

See `test/integration/holepunch_network/holepunch_network_integration_test.dart` for containerized testing with NAT simulation.

### Container Setup (peer_main.dart)

`test/integration/holepunch_network/containers/dart-peer/peer_main.dart` is the peer that runs in each container. The relay role sets `enableRelay` and `forceReachability = Reachability.public`; the other peers set `enableAutoRelay`, connect to the relay and wait for their circuit addresses. It builds its `BasicHost` from a `Config` directly; an application uses the `Libp2p` options shown above.

---

## Troubleshooting

### Circuit Addresses Not Advertised

**Symptoms:**
- `host.addrs` doesn't contain `/p2p-circuit`
- No `EvtAutoRelayAddrsUpdated` event with circuit addresses

**Solutions:**

1. **Verify AutoRelay is enabled** with `Libp2p.autoRelay(true)`.

2. **Connect to a relay server that runs the relay service:**
   ```dart
   await host.connect(AddrInfo(relayPeerId, [relayAddr]));

   // Check relay supports both Circuit v2 AND AutoNAT v2
   final protocols = await host.peerStore.protoBook.getProtocols(relayPeerId);
   print('Relay protocols: $protocols');
   // Should include:
   // - '/libp2p/circuit/relay/0.2.0/hop'
   // - '/libp2p/autonat/2/dial-request'
   ```
   Without the hop protocol, the relay service is not running: give the relay `Libp2p.forceReachability(Reachability.public)`.

3. **Check whether AutoNAT found the host public.** AutoRelay stops when reachability becomes public:
   ```dart
   host.eventBus.subscribe(EvtLocalReachabilityChanged).stream.listen((dynamic e) {
     if (e is EvtLocalReachabilityChanged) print('Reachability: ${e.reachability}');
   });
   ```

4. **Check the logs:**
   ```dart
   Logger.root.level = Level.FINE;
   Logger.root.onRecord.listen((record) {
     if (record.loggerName == 'ambient_autonat_v2' ||
         record.loggerName == 'AutoRelay' ||
         record.loggerName == 'RelayFinder') {
       print('${record.loggerName} ${record.level.name}: ${record.message}');
     }
   });
   ```
   (`Logger` and `Level` come from `package:logging/logging.dart`.)

### Dial Fails with "NO_RESERVATION" or No Usable Address

**Symptoms:**
- The relay answers `NO_RESERVATION`
- The dial fails before it reaches the relay

**Solutions:**
- The destination must hold a reservation on that relay: check that its `EvtAutoRelayAddrsUpdated` lists the relay.
- Use the address the destination advertises, which ends in `/p2p-circuit/p2p/DEST_PEER_ID`, or build `<relay addr>/p2p/RELAY_PEER_ID/p2p-circuit/p2p/DEST_PEER_ID`. Do not append the destination's peer ID to an address that already ends in it.
- The relay address must be an `/ip4` or `/ip6` address; `/dns4` addresses are not dialled.
- The dialling host needs `Libp2p.relay(true)` or `Libp2p.autoRelay(true)` for the circuit transport.

### Connection Succeeds But Not Using Relay

**Symptoms:**
- Ping works but connection doesn't contain `/p2p-circuit`
- Direct connection established instead

**Solution:**
Clear existing addresses before adding circuit addresses:

```dart
// Force circuit relay usage
await host.peerStore.addrBook.clearAddrs(destPeerId); // Clear direct addresses
await host.peerStore.addrBook.addAddrs(
  destPeerId,
  viaRelay, // Only circuit addresses
  Duration(hours: 1)
);
```

An open direct connection is reused, and new streams prefer a direct connection to a relayed one; close it first with `host.network.closePeer(destPeerId)`. Hole punching (DCUtR) may also add a direct connection after the relayed one is up; that is the intended upgrade, not a failure.

### Relay Reservation Fails

**Symptoms:**
- AutoRelay runs but no circuit addresses advertised
- Logs show reservation failures

**Solutions:**

1. **Check relay has resources available:**
   A dart-libp2p relay accepts at most 128 reservations, and a peer may make 10 HOP requests per minute.

2. **Verify relay is publicly reachable:**
   ```dart
   // For relay servers
   final relayOptions = [
     Libp2p.relay(true),
     // The relay service starts only once the host knows it is publicly
     // reachable. Turning AutoNAT off does not tell it so; declare it:
     Libp2p.forceReachability(Reachability.public),
   ];
   ```

3. **Check connection to relay is stable:**
   ```dart
   final connectedness = host.network.connectedness(relayPeerId);
   print('Relay connectedness: $connectedness');
   // Should be Connectedness.connected
   ```

### Ping Through Relay Times Out

**Symptoms:**
- Circuit address constructed correctly
- Connection established but ping times out

**Solutions:**

1. **Check the relay's limits:** a relayed connection ends after 1 MiB or 1 hour on a dart-libp2p relay (128 KiB or 2 minutes on a go-libp2p relay).

2. **Check the circuit transport is registered:** it is registered in `BasicHost.start()` when `Libp2p.relay(true)` or `Libp2p.autoRelay(true)` is set, on both the dialler and the destination.

3. **Check go-libp2p peers:** a go-libp2p service does not open streams on a limited (relayed) connection unless its code allows it (`network.WithAllowLimitedConn`); expect it to answer only after hole punching made a direct connection.

---

## Understanding AmbientAutoNATv2

### How It Works

**AmbientAutoNATv2** is an orchestrator that wraps the AutoNAT v2 protocol to provide automatic, continuous reachability detection:

1. **Boot Delay**: Waits `bootDelay` after start (default 15s, configurable to 500ms for testing)
2. **Peer Discovery**: Monitors connected peers for AutoNAT v2 support (`/libp2p/autonat/2/dial-request`)
3. **Probing**: Asks an AutoNAT v2 server to dial this host's public, direct addresses (relay addresses are never checked). A host that knows no public address of its own has nothing to check, and its reachability stays unknown
4. **Response Handling**:
   - `E_DIAL_REFUSED`: Interpreted as **private** reachability (expected for NAT)
   - `OK` + dial-back success: Interpreted as **public** reachability
   - Errors: Treated as **unknown** reachability
5. **Confidence Tracking**: Builds confidence (0-3) through multiple successful probes
6. **Event Emission**: Emits `EvtLocalReachabilityChanged` when status changes
7. **Continuous Monitoring**: Reschedules probes based on current status

### Reachability and AutoRelay

AutoRelay runs while reachability is unknown or private, and stops when it becomes public. A host behind NAT therefore gets its reservations straight away, before the first probe, and keeps them whatever the probes say unless they find it public. A server refuses to check a private address (unless it allows private addresses, as on a local test network); the client checks only public addresses, and records a refused check (`E_DIAL_REFUSED`) as private.

### Configuration Options

```dart
import 'package:dart_libp2p/p2p/host/autonat/ambient_config.dart';

final autoNATOption = Libp2p.ambientAutoNATv2Config(const AmbientAutoNATv2Config(
  bootDelay: Duration(seconds: 15),       // Wait before first probe (default: 15s)
  retryInterval: Duration(minutes: 1),    // Retry after failures (default: 1 min)
  refreshInterval: Duration(minutes: 15), // Refresh when stable (default: 15 min)
  addressFunc: null,                      // Addresses to check (default: host.addrs)
  ipv4Only: false,                        // Check IPv4 addresses only
));
```

**For production:**
- Use default intervals for stable, low-overhead probing
- Let `bootDelay` be 15s to allow network to stabilize

**For testing:**
- Use fast intervals (500ms boot, 1s retry) for quick feedback
- Configure relay with `Libp2p.autoNATv2AllowPrivateAddrs()` for local testing
- On phones, turn off answering other peers' checks with `Libp2p.autoNATv2Server(false)`

## Best Practices

1. **Let AutoNAT and AutoRelay run on their own**
   - No manual event emission needed
   - Continuous monitoring and confidence tracking
   - Handles network changes automatically

2. **Give the relays to the host up front**
   - Use `Libp2p.relayServers([...])`, so the relays are connected during `host.start()`
   - AutoRelay and AmbientAutoNATv2 both use the connected relays

3. **Wait for events, not for fixed delays**
   - Wait for `EvtAutoRelayAddrsUpdated` with circuit addresses rather than a fixed sleep
   - Relayed dials time out after `Libp2p.relayDialTimeout` (30 s by default); allow for the extra round trips

4. **Handle relay disconnections**
   - Subscribe to `EvtAutoRelayAddrsUpdated` to detect when relays change; the host advertises the new addresses itself
   - Reconnect to a relay that went away; AutoRelay books again when the connection is back

5. **Verify circuit usage in tests**
   - Always check connection addresses contain `/p2p-circuit`
   - Don't assume circuit usage - verify it!

6. **Production relay servers**
   - Use `Libp2p.forceReachability(Reachability.public)` to skip probing
   - Keep the AutoNAT v2 server on (the default) so clients can check their reachability
   - Persist the relay's key: clients dial it by `/p2p/<relay peer ID>`
   - Use dedicated nodes with good network connectivity
   - Configure the host's resource limits appropriately (the relay's own limits are fixed, see [Relay limits](#relay-limits))
   - Monitor relay usage and reservations

7. **Security considerations**
   - Circuit relay uses nested Noise security
   - Relay cannot decrypt application data
   - End-to-end encryption maintained between peers
   - AutoNAT v2 dial-backs are authenticated

---

## What's New

### AmbientAutoNATv2 Implementation

- **Automatic Reachability Detection**: No manual event emission required
- **Confidence Tracking**: 0-3 confidence levels with gradual status changes
- **E_DIAL_REFUSED Handling**: Correctly interprets as private reachability
- **Event Emission**: Automatic `EvtLocalReachabilityChanged` events
- **Configurable Intervals**: Fast boot for testing, stable intervals for production

### Circuit Relay v2 Improvements

- **Nested Security/Multiplexing**: Follows go-libp2p architecture
- **Direct Address Filtering**: Prevents circular HOP dialing
- **Double `/p2p-circuit` Fix**: Skips addresses already containing circuit component
- **Relay Service Lifecycle**: Separate AutoNAT server (always on) from ambient client (conditional)

### New Configuration Options

- `Libp2p.forceReachability`: Force specific reachability status (for relay servers)
- `Libp2p.ambientAutoNATv2Config`: Configure boot delay, retry, and refresh intervals
- `Libp2p.autoNATv2Options`, `Libp2p.autoNATv2AllowPrivateAddrs`: Configure AutoNAT v2 server behaviour
- `Libp2p.relayServers`: Relays to connect to during `host.start()`

## References

- **AmbientAutoNATv2:** `lib/p2p/host/autonat/ambient_autonat_v2.dart`
- **AutoNAT v2:** `lib/p2p/protocol/autonatv2/`
- **Circuit Relay v2:** `lib/p2p/host/autorelay/`, `lib/p2p/protocol/circuitv2/`
- **Configuration:** `lib/config/config.dart`, `lib/p2p/host/autonat/ambient_config.dart`
- **Tests:** `test/p2p/host/autorelay_integration_test.dart`, `test/p2p/host/autonat/ambient_autonat_v2_test.dart`
- **Docker Tests:** `test/integration/holepunch_network/`
- **Container Example:** `test/integration/holepunch_network/containers/dart-peer/peer_main.dart`
- **Spec:** [Circuit Relay v2 Specification](https://github.com/libp2p/specs/blob/master/relay/circuit-v2.md)
