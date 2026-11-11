# Command-line tools

This directory contains small programs built on dart-libp2p: a ping application and the Dart side of the Go↔Dart interop tests. All of them use the UDX transport with Noise and Yamux. Run them from the repository root with `dart run`.

For examples to learn from, see [`example/`](../example/) (`echo_basic`, `chat_mdns`) and the [documentation](../doc/).

## Ping Application (`ping_app.dart`)

Two instances ping each other over UDX with their own protocol, `/dart-libp2p/example-ping/udx/1.0.0`.

Options:
- `-l, --listen <multiaddr>`: address to listen on, for example `/ip4/0.0.0.0/udp/0/udx`
- `-t, --target <multiaddr>`: peer to ping, a full address with `/p2p/<peer ID>`
- `-i, --interval <seconds>`: seconds between pings (default 1)
- `-h, --help`: show the options

Start a listener; it prints its full addresses (`host.addrs`, which leaves out loopback addresses, so listen on `0.0.0.0` rather than `127.0.0.1`):
```bash
dart run bin/ping_app.dart -l /ip4/0.0.0.0/udp/0/udx
```

Ping it from another terminal, with one of the printed addresses:
```bash
dart run bin/ping_app.dart -l /ip4/0.0.0.0/udp/0/udx -t /ip4/<IP>/udp/<port>/udx/p2p/<peer ID>
```

## Interop Tools

These programs talk to a go-libp2p peer over UDX (see [`interop/`](../interop/README.md) for the Go side). Each exits 0 on success.

| Program | Usage | What it does |
|---|---|---|
| `interop_echo_server.dart` | `dart run bin/interop_echo_server.dart [listen multiaddr]` | Listens (default `/ip4/127.0.0.1/udp/0/udx`) and echoes the bytes of each `/echo/1.0.0` stream. Prints `READY <port> <peer ID>` to stderr when ready. |
| `interop_echo_client.dart` | `dart run bin/interop_echo_client.dart <multiaddr/p2p/peer ID>` | Connects, sends `hello interop` on `/echo/1.0.0` and checks the echo. |
| `interop_reqresp_client.dart` | `dart run bin/interop_reqresp_client.dart <multiaddr/p2p/peer ID> [count]` | Sends length-prefixed requests on `/interop/reqresp/1.0.0`, the first ones at the same time before a connection exists, and checks each response. |
| `interop_netem_test.dart` | `dart run bin/interop_netem_test.dart <multiaddr/p2p/peer ID> [keep_alive_secs]` | Runs five phases against an echo server, for use under network emulation: connect and Identify, a 32-byte echo, a 64 KB echo, an echo after an idle keep-alive period, and five echo streams in a row. |
