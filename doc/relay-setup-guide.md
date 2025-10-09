# Circuit Relay v2 Setup Guide

## Running a Relay Server

To set up a Circuit Relay v2 server in dart-libp2p, simply configure your node with relay enabled and AutoNAT disabled:

```dart
final config = Config()
  ..enableRelay = true      // Enable relay service
  ..enableAutoNAT = false;  // Disable AutoNAT for always-on relay

final host = await BasicHost.create(
  network: network,
  config: config,
);

await host.start();
// Relay service automatically starts and advertises the hop protocol
```

### How It Works

When `enableRelay = true` AND `enableAutoNAT = false`:
- `BasicHost` automatically emits `Reachability.public` event during startup
- `RelayManager` receives this event and starts the relay service
- The relay service registers the Circuit Relay v2 Hop protocol handler
- Other peers can discover this node as a relay and make reservations

**No manual event emission or internal API calls required!**

### With AutoNAT Enabled

For dynamic relay behavior (relay only when publicly reachable):

```dart
final config = Config()
  ..enableRelay = true   // Enable relay service
  ..enableAutoNAT = true; // Enable AutoNAT for dynamic detection

final host = await BasicHost.create(
  network: network,
  config: config,
);

await host.start();
// Relay service starts automatically when AutoNAT determines you're publicly reachable
// Stops automatically when you become privately reachable
```

## Using a Relay (AutoRelay Client)

To use relays as a client behind NAT:

```dart
final config = Config()
  ..enableAutoRelay = true  // Enable AutoRelay client
  ..enableAutoNAT = false;  // Optional: disable if you know you're behind NAT

final host = await BasicHost.create(
  network: network,
  config: config,
);

await host.start();

// Connect to a known relay server
final relayAddr = MultiAddr('/ip4/1.2.3.4/tcp/4001/p2p/12D3Koo...');
await host.connect(AddrInfo(relayPeerId, [relayAddr]));

// AutoRelay will:
// 1. Discover the relay supports Circuit v2 Hop
// 2. Make a reservation with the relay
// 3. Advertise circuit addresses: /ip4/1.2.3.4/tcp/4001/p2p/12D3Koo.../p2p-circuit
```

## Architecture

```
┌─────────────────┐
│  Relay Server   │  enableRelay=true, enableAutoNAT=false
│                 │  → Advertises /libp2p/circuit/relay/0.2.0/hop
└────────┬────────┘
         │
    ┌────┴────┐
    │         │
┌───▼───┐ ┌──▼────┐
│Peer A │ │Peer B │  enableAutoRelay=true
│(NAT)  │ │(NAT)  │  → Discovers relay, makes reservation
└───────┘ └───────┘  → Advertises: .../p2p/RelayID/p2p-circuit
```

## Implementation Details

The auto-start behavior for relay servers is implemented in `BasicHost.start()`:

```dart:285:303:lib/p2p/host/basic/basic_host.dart
// Initialize RelayManager if enabled
if (_config.enableRelay) {
  _relayManager = await RelayManager.create(this);
  
  // If AutoNAT is disabled, assume public reachability and start the relay service immediately.
  // This provides a simple API for developers running dedicated relay servers:
  // just set enableRelay=true and disable AutoNAT, without manual event emission.
  if (!_config.enableAutoNAT) {
    _log.fine('[BasicHost start] AutoNAT disabled with relay enabled - assuming public reachability, starting relay service');
    final reachabilityEmitter = await _eventBus.emitter(EvtLocalReachabilityChanged);
    await reachabilityEmitter.emit(EvtLocalReachabilityChanged(reachability: Reachability.public));
    await reachabilityEmitter.close();
    _log.fine('[BasicHost start] Relay service should now be active');
  }
  
  _log.fine('RelayManager created and service monitoring started.');
}
```

This design provides:
- ✅ Simple, intuitive API
- ✅ No manual event emission needed
- ✅ Works for both always-on and dynamic relay scenarios
- ✅ Follows principle of least surprise

## Testing

Integration tests in `test/integration/holepunch_network/` demonstrate:
- Relay service auto-start without manual setup
- AutoRelay client discovery and reservation
- Circuit address advertisement
- End-to-end relay connectivity

