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

### Basic Setup (Always-On Relay)

For a dedicated relay server that's always publicly reachable:

```dart
final config = Config()
  ..enableRelay = true      // Enable relay service
  ..enableAutoNAT = false;  // Disable AutoNAT for always-on relay

final host = await BasicHost.create(
  network: network,
  config: config,
);

await host.start();
// ✅ Relay service automatically starts and advertises the hop protocol
// No manual event emission required!
```

**What happens automatically:**
1. `BasicHost` detects `enableRelay=true` and `enableAutoNAT=false`
2. Emits `EvtLocalReachabilityChanged(reachability: Reachability.public)` during startup
3. `RelayManager` receives the event and starts the relay service
4. Relay service registers the `/libp2p/circuit/relay/0.2.0/hop` protocol handler
5. Other peers can discover this node as a relay and make reservations

### Dynamic Relay (With AutoNAT)

For relays that should only operate when publicly reachable:

```dart
final config = Config()
  ..enableRelay = true   // Enable relay service
  ..enableAutoNAT = true; // Enable AutoNAT for dynamic detection

final host = await BasicHost.create(
  network: network,
  config: config,
);

await host.start();
// Relay service starts/stops automatically based on AutoNAT detection
```

The relay will:
- Start when AutoNAT determines you're publicly reachable
- Stop when you become privately reachable (e.g., network change)

---

## Using Circuit Relay (AutoRelay Client)

### Step 1: Create Host with AutoRelay Enabled

```dart
final config = Config()
  ..enableAutoRelay = true  // Enable AutoRelay client
  ..enableAutoNAT = false;  // Optional: disable if you know you're behind NAT

final host = await BasicHost.create(
  network: network,
  config: config,
);

await host.start();
```

### Step 2: Connect to Relay Server

**Critical:** You must connect to the relay server BEFORE triggering AutoRelay.

```dart
// Known relay server address
final relayAddr = MultiAddr('/ip4/1.2.3.4/tcp/4001/p2p/12D3Koo...');
final relayPeerId = PeerId.fromString('12D3Koo...');

// Connect to relay
await host.connect(AddrInfo(relayPeerId, [relayAddr]));
print('✅ Connected to relay server');
```

### Step 3: Trigger AutoRelay (If AutoNAT Disabled)

If you disabled AutoNAT, manually emit a reachability event:

```dart
// Emit private reachability to trigger AutoRelay
final emitter = await host.eventBus.emitter(EvtLocalReachabilityChanged);
await emitter.emit(EvtLocalReachabilityChanged(reachability: Reachability.private));
await emitter.close();
print('✅ AutoRelay triggered');
```

### Step 4: Wait for AutoRelay Initialization

AutoRelay needs time to discover relays and make reservations:

```dart
// Wait for AutoRelay to complete initialization
// bootDelay (5s) + discovery + reservation (~5-15s total)
print('⏰ Waiting for AutoRelay to make reservations...');
await Future.delayed(Duration(seconds: 12));
```

### Step 5: Verify Circuit Addresses

Check that circuit addresses are advertised:

```dart
final myAddrs = host.addrs;
print('My addresses:');
for (final addr in myAddrs) {
  print('  - $addr');
  if (addr.toString().contains('/p2p-circuit')) {
    print('    ✅ Circuit relay address!');
  }
}

// Circuit addresses look like:
// /ip4/1.2.3.4/tcp/4001/p2p/RELAY_PEER_ID/p2p-circuit/
```

---

## Dialing Through Circuit Relay

### Understanding Circuit Addresses

AutoRelay advertises **base circuit addresses**:
```
/ip4/1.2.3.4/tcp/4001/p2p/RELAY_PEER_ID/p2p-circuit/
```

To dial a peer through the relay, you need a **full dialable address**:
```
/ip4/1.2.3.4/tcp/4001/p2p/RELAY_PEER_ID/p2p-circuit/p2p/DEST_PEER_ID
```

### Constructing Dialable Circuit Addresses

```dart
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart';

// Get destination peer's base circuit addresses
final destPeerId = PeerId.fromString('12D3Koo...');
final destAddrs = await host.peerStore.addrBook.addrs(destPeerId);

// Filter to circuit addresses
final baseCircuitAddrs = destAddrs.where((addr) {
  final addrStr = addr.toString();
  return addrStr.contains('/p2p-circuit') && 
         addrStr.contains('RELAY_PEER_ID'); // Contains relay ID
}).toList();

// Construct full dialable addresses by appending destination peer ID
final dialableCircuitAddrs = baseCircuitAddrs.map((addr) {
  return addr.encapsulate(Protocols.p2p.name, destPeerId.toString());
}).toList();

print('Dialable circuit addresses:');
for (final addr in dialableCircuitAddrs) {
  print('  - $addr');
}
```

### Forcing Circuit Relay Usage

To ensure connections use circuit relay (not direct connection):

```dart
// Clear existing addresses to prevent direct dial
await host.peerStore.addrBook.clearAddrs(destPeerId);

// Add ONLY circuit addresses
await host.peerStore.addrBook.addAddrs(
  destPeerId,
  dialableCircuitAddrs,
  Duration(hours: 1),
);

// Now any connection will use circuit relay
await host.connect(AddrInfo(destPeerId, dialableCircuitAddrs));
```

### Using Circuit Connections

Once connected, use the connection normally:

```dart
// Ping through relay
final pingService = PingService(host);
final result = await pingService.ping(destPeerId).first;
print('✅ Ping RTT: ${result.rtt?.inMilliseconds}ms');

// Verify connection is relayed
final conns = host.network.connsToPeer(destPeerId);
final isRelayed = conns.first.remoteMultiaddr.toString().contains('/p2p-circuit');
print('Connection is relayed: $isRelayed');

// Use any protocol - it works transparently through the relay
final stream = await host.newStream(destPeerId, ['/my-protocol/1.0.0']);
```

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

See `test/p2p/host/autorelay_integration_test.dart` for a complete example:

```dart
test('Circuit relay with ping', () async {
  // 1. Create relay server
  final relayNode = await createLibp2pNode(enableRelay: true);
  
  // 2. Create clients with AutoRelay
  final peerA = await createLibp2pNode(enableAutoRelay: true);
  final peerB = await createLibp2pNode(enableAutoRelay: true);
  
  // 3. Connect to relay
  await peerA.host.connect(AddrInfo(relayNode.peerId, relayNode.host.addrs));
  await peerB.host.connect(AddrInfo(relayNode.peerId, relayNode.host.addrs));
  
  // 4. Trigger AutoRelay
  final emitter = await peerA.host.eventBus.emitter(EvtLocalReachabilityChanged);
  await emitter.emit(EvtLocalReachabilityChanged(reachability: Reachability.private));
  await emitter.close();
  
  // 5. Wait for reservations
  await Future.delayed(Duration(seconds: 12));
  
  // 6. Verify circuit addresses
  final circuitAddrs = peerA.host.addrs.where((a) => 
    a.toString().contains('/p2p-circuit')
  ).toList();
  expect(circuitAddrs, isNotEmpty);
  
  // 7. Dial via circuit
  final dialableAddr = circuitAddrs.first.encapsulate(
    Protocols.p2p.name, 
    peerB.peerId.toString()
  );
  await peerA.host.peerStore.addrBook.clearAddrs(peerB.peerId);
  await peerA.host.peerStore.addrBook.addAddrs(
    peerB.peerId, 
    [dialableAddr], 
    Duration(hours: 1)
  );
  
  // 8. Ping through relay
  final ping = PingService(peerA.host);
  final result = await ping.ping(peerB.peerId).first;
  expect(result.hasError, isFalse);
  
  // 9. Verify relayed connection
  final conn = peerA.host.network.connsToPeer(peerB.peerId).first;
  expect(conn.remoteMultiaddr.toString().contains('/p2p-circuit'), isTrue);
});
```

### Docker Integration Test

See `test/integration/holepunch_network/holepunch_network_integration_test.dart` for containerized testing with NAT simulation.

### Container Setup (peer_main.dart)

The integration test peer demonstrates production-ready setup:

```dart
// 1. Start host (auto-starts relay if enabled)
await host.start();

// 2. For relay servers: done! Service is active.
if (role == 'relay') {
  print('📡 Relay server ready');
  return;
}

// 3. For clients: connect to relay servers
await _connectToRelayServers();

// 4. Trigger AutoRelay (if AutoNAT disabled)
await _triggerAutoRelay();

// 5. Wait for initialization
await Future.delayed(Duration(seconds: 10));

// 6. Circuit addresses now available
print('📍 My addresses: ${host.addrs}');
```

---

## Troubleshooting

### Circuit Addresses Not Advertised

**Symptoms:**
- `host.addrs` doesn't contain `/p2p-circuit`
- AutoRelay doesn't discover relay

**Solutions:**
1. **Connect to relay BEFORE triggering AutoRelay:**
   ```dart
   await host.connect(AddrInfo(relayPeerId, [relayAddr]));
   // THEN emit reachability event
   ```

2. **Wait longer for AutoRelay:**
   ```dart
   // AutoRelay has bootDelay=5s by default
   await Future.delayed(Duration(seconds: 12));
   ```

3. **Check relay supports Circuit v2:**
   ```dart
   final protocols = await host.peerStore.protoBook.getProtocols(relayPeerId);
   print('Relay protocols: $protocols');
   // Should include '/libp2p/circuit/relay/0.2.0/hop'
   ```

4. **Verify reachability event was emitted:**
   ```dart
   // For clients behind NAT
   final emitter = await host.eventBus.emitter(EvtLocalReachabilityChanged);
   await emitter.emit(EvtLocalReachabilityChanged(reachability: Reachability.private));
   await emitter.close();
   ```

### Dial Fails with "No addresses"

**Symptoms:**
- Dial fails: "No addresses found for peer"
- Circuit address missing destination peer ID

**Solution:**
Use full dialable address with destination peer ID:

```dart
// ❌ WRONG: Base circuit address (missing destination)
final addr = '/ip4/1.2.3.4/tcp/4001/p2p/RELAY_ID/p2p-circuit/';

// ✅ CORRECT: Full dialable address (with destination)
final addr = '/ip4/1.2.3.4/tcp/4001/p2p/RELAY_ID/p2p-circuit/p2p/DEST_PEER_ID';

// Use encapsulate() to construct correctly
final dialableAddr = baseCircuitAddr.encapsulate(
  Protocols.p2p.name,
  destPeerId.toString()
);
```

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
  dialableCircuitAddrs, // Only circuit addresses
  Duration(hours: 1)
);
```

### Relay Reservation Fails

**Symptoms:**
- AutoRelay runs but no circuit addresses advertised
- Logs show reservation failures

**Solutions:**

1. **Check relay has resources available:**
   ```dart
   // Relay servers have limits on reservations
   // Default: 128 concurrent reservations
   ```

2. **Verify relay is publicly reachable:**
   ```dart
   // For relay servers
   config.enableRelay = true;
   config.enableAutoNAT = false; // Assumes public
   ```

3. **Check connection to relay is stable:**
   ```dart
   final connectedness = host.network.connectedness(relayPeerId);
   print('Relay connectedness: $connectedness');
   // Should be 'connected'
   ```

### Ping Through Relay Times Out

**Symptoms:**
- Circuit address constructed correctly
- Connection established but ping times out

**Solutions:**

1. **Verify both sides have upgraded connection:**
   ```dart
   // Check logs for "Going to try and upgrade to [[/noise]]"
   // Both source and destination must upgrade RelayedConn
   ```

2. **Check CircuitV2Client is registered as transport:**
   ```dart
   // Should happen automatically in BasicHost.start()
   // when enableRelay=true or enableAutoRelay=true
   ```

3. **Verify relay is forwarding data:**
   ```dart
   // Check relay logs for "Relaying data from source to destination"
   ```

---

## Best Practices

1. **Always connect to relay before triggering AutoRelay**
   - AutoRelay needs existing connections to discover relay candidates

2. **Use appropriate timeouts**
   - AutoRelay initialization: 10-15 seconds
   - Ping through relay: 10-15 seconds (higher latency than direct)

3. **Handle relay disconnections**
   - Subscribe to `EvtAutoRelayAddrsUpdated` to detect when relays change
   - Re-advertise circuit addresses when relay list updates

4. **Verify circuit usage in tests**
   - Always check connection addresses contain `/p2p-circuit`
   - Don't assume circuit usage - verify it!

5. **Production relay servers**
   - Use dedicated nodes with good network connectivity
   - Configure resource limits appropriately
   - Monitor relay usage and reservations

6. **Security considerations**
   - Circuit relay uses nested Noise security
   - Relay cannot decrypt application data
   - End-to-end encryption maintained between peers

---

## References

- **Implementation:** `lib/p2p/host/autorelay/`, `lib/p2p/protocol/circuitv2/`
- **Tests:** `test/p2p/host/autorelay_integration_test.dart`
- **Docker Tests:** `test/integration/holepunch_network/`
- **Container Example:** `test/integration/holepunch_network/containers/dart-peer/peer_main.dart`
- **Spec:** [Circuit Relay v2 Specification](https://github.com/libp2p/specs/blob/master/relay/circuit-v2.md)
