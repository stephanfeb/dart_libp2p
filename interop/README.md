# Go-libp2p Interop Tests

End-to-end interoperability tests between **dart-libp2p** and **go-libp2p**.

## Prerequisites

- **Go** 1.25.7+ (`go version`; `interop/go-peer/go.mod` requires it)
- **Dart** 3.5+ (`dart --version`)
- Checkouts of [go-udx](https://github.com/stephanfeb/go-udx) and [go-libp2p-udx-transport](https://github.com/stephanfeb/go-libp2p-udx-transport) next to this repository (`../go-udx`, `../go-libp2p-udx-transport`): `go.mod` replaces both modules with these local paths. They give the Go peer its UDX transport.

The Go peer binary is built automatically on first test run. To build it manually:

```bash
cd interop/go-peer
go build -o go-peer .
```

## Running the tests

From the project root:

```bash
# All interop tests
dart test test/interop/

# Host-level tests (identify, echo, ping, identify-push)
dart test test/interop/go_interop_host_test.dart

# Circuit Relay v2 tests
dart test test/interop/go_interop_relay_test.dart

# Host-level tests over UDX, and UDX keep-alive stability
dart test test/interop/go_interop_udx_host_test.dart
dart test test/interop/go_interop_udx_stability_test.dart

# Relayed Identify and DCUtR through a Go relay
dart test test/interop/go_interop_relayed_identify_dcutr_test.dart

# AutoNAT v2 client and server
dart test test/interop/go_interop_autonatv2_test.dart

# Low-level transport tests (Noise, Yamux, multistream)
dart test test/interop/go_interop_test.dart

# Single test by name
dart test test/interop/ --name="Dart BasicHost echoes via newStream"
```

## Test overview

### `go_interop_host_test.dart` (5 tests)

Full-stack BasicHost tests exercising the identify protocol, peerstore, and stream handling.

| Test | Direction | What it verifies |
|------|-----------|-----------------|
| Connect + identify | Dart -> Go | TCP dial, Noise, Yamux, identify exchange populates peerstore |
| Echo via newStream | Dart -> Go | `host.newStream()` path: connection lookup, identify wait, multistream-select |
| Echo handler | Go -> Dart | `host.setStreamHandler()`, inbound connection upgrade, echo round-trip |
| Ping | Go -> Dart | Built-in PingService handles Go's `/ipfs/ping/1.0.0` |
| Identify push | Go -> Dart | Go registers new protocol, triggers identify push, Dart peerstore updates |

### `go_interop_relay_test.dart` (2 tests)

Circuit Relay v2 tests using a 3-node topology (Go relay + two peers).

| Test | Topology | What it verifies |
|------|----------|-----------------|
| Dart dials through relay | Go relay <- Go echo-server; Dart client dials via circuit | Relay reservation, HOP CONNECT, Noise+Yamux over relay, echo round-trip |
| Go dials through relay | Go relay <- Dart echo-handler; Go client dials via circuit | Dart `CircuitV2Client.reserve()`, inbound STOP handling, echo round-trip |

### `go_interop_udx_host_test.dart` (4 tests) and `go_interop_udx_stability_test.dart` (6 tests)

The host-level tests over UDX instead of TCP (connect and identify, echo both ways, ping), and Yamux keep-alive over idle and busy UDX connections in both directions.

### `go_interop_relayed_identify_dcutr_test.dart` (2 tests)

A Dart host connects to a Go gateway through a Go relay. Identify completes over the relayed connection and the gateway starts DCUtR (`/libp2p/dcutr`); the second test repeats this 50 times.

### `go_interop_autonatv2_test.dart` (3 tests)

AutoNAT v2 in both directions: a Go server checks a Dart address (with and without dial data), and a Dart server checks a Go address.

### Kademlia DHT and GossipSub

The Kademlia DHT interop tests (`test/interop/go_dht_interop_test.dart`) live in [dart_libp2p_kad_dht](https://github.com/stephanfeb/dart_libp2p_kad_dht), and the GossipSub ones in [dart_libp2p_pubsub](https://github.com/stephanfeb/dart_libp2p_pubsub). They use the `dht-*` and `pubsub-*` modes of the Go peer below.

### `go_interop_test.dart`

Lower-level transport tests that directly exercise the upgrader pipeline (TCP -> Noise -> Yamux) without the full BasicHost stack.

## Go peer modes

The Go peer binary (`interop/go-peer/go-peer`) supports multiple modes:

| Mode | Description |
|------|-------------|
| `server` | Listen with echo + identify handlers (long-running) |
| `client` | Connect to target peer and exit |
| `ping` | Connect and ping via `/ipfs/ping/1.0.0` |
| `echo-server` | Listen with echo handler only |
| `echo-client` | Connect, send message via `/echo/1.0.0`, verify echo |
| `push-test` | Connect, register new protocol to trigger identify push |
| `relay` | Run a Circuit Relay v2 service |
| `relay-echo-server` | Reserve slot on relay, handle echo streams |
| `relay-echo-client` | Dial peer through relay, send echo message |
| `dht-server` | Run a Kademlia DHT server (long-running) |
| `dht-relay-server` | Run a Kademlia DHT server that is also a Circuit Relay v2 relay |
| `dht-put-value` | Connect to DHT peer and store a key-value pair |
| `dht-get-value` | Connect to DHT peer and retrieve a value by key |
| `dht-provide` | Connect to DHT peer and announce as content provider |
| `dht-find-providers` | Connect to DHT peer and find providers for a CID |
| `pubsub-server` | Join a GossipSub topic and wait for messages |
| `pubsub-client` | Connect, join the topic and publish a message |
| `autonat-server` | Run an AutoNAT v2 server |
| `autonat-client` | Connect and ask the target for an AutoNAT v2 check |

Usage: `./go-peer --mode=<mode> [--port=N] [--transport=tcp|udx] [--target=<multiaddr>] [--relay=<multiaddr>] [--message=<text>] [--key=<key>] [--value=<value>] [--cid=<cid>] [--pk-self] [--pk-peer=<peer ID>] [--topic=<topic>] [--config=<file.yaml>]`

## Architecture

```
test/interop/
  go_interop_*_test.dart    Dart test files
  helpers/
    go_process_manager.dart  Manages Go peer process lifecycle

interop/go-peer/
  main.go                    Go peer with all test modes
  go.mod / go.sum            Go module dependencies
```

`GoProcessManager` handles building, starting, and stopping Go peer processes.
It parses stdout for `PeerID:`, `Listening:`, `CircuitAddr:`, and `Ready` markers
to extract connection details for the Dart tests.
