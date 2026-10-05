# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [4.1.9] - 2026-10-05

### Fixed

- **An AutoNAT v2 dial-back over UDX left from the listen socket.** Since 4.1.1, an ordinary UDX dial to a remote peer leaves from the listen socket, so that the peer observes our listen address. The AutoNAT v2 server's dial-back host borrows the same transport, so its dial-backs also left from the listen socket. A dial-back from there can pass through a NAT mapping that the client already has open, and so report an address as reachable when it is not. Its packets also went to the client's listen port from our punch socket before any hole punch, and a DCUtR hole punch between the two peers that followed then failed. A UDX dial-back now leaves from a fresh socket, as from go-libp2p's separate dialer host.

### Tests

- The hole-punch Docker harness NAT gateways now drop unsolicited packets to the gateway itself on the WAN side, as a home router does. Before, such a packet (for example, from a direct dial that lost to a relay address) made a conntrack entry for its address pair, and the gateway then sent the hole punch for the same pair from another port. With this and the dial-back fix, `run_dcutr_scenario.sh` passes again (3/3).

## [4.1.8] - 2026-10-05

### Fixed

- **A hole punch sent and dialed private addresses.** When a peer had no public address, both sides of a DCUtR hole punch fell back to their private listen addresses (for example, `10.0.2.15` inside an Android emulator). A peer on another network cannot reach these addresses, so each such hole punch held a dial for the full timeout and then failed. As in go-libp2p, a hole punch now uses public addresses only. A peer with no public address does not start a hole punch and refuses a request for one, and private addresses that the other peer sends are not dialed. Peers on the same network do not need a hole punch: they connect over their direct addresses.
- **A hole-punch dial waited 15 s, not 5 s.** The 5-s hole-punch `dialTimeout` was not used, so each attempt waited for the normal dial timeout. The swarm now applies `Context.withDialPeerTimeout` when it is shorter than the configured dial timeout, and the hole punch sets it to 5 s, as in go-libp2p.
- **A failed hole punch was logged as an error.** A hole punch often fails behind NAT, and the relayed connection stays in use. The swarm and `BasicHost` logged each failure at SEVERE with a stack trace. Failed direct dials (`forceDirectDial`) are now logged at FINE. Other dial failures are logged as before.
- Concurrent dials join one dial only when they have the same `simultaneousConnect` option too, so a hole-punch dial does not join an uncoordinated direct dial.

## [4.1.7] - 2026-10-05

### Fixed

- **AutoNAT v2 probed a relay address and retried forever.** A host behind NAT often has only one public address: its relay address. The ambient AutoNAT v2 client sent that address to the AutoNAT server. When the relay was also the only AutoNAT server, the client removed the address again and the probe failed with `No valid addresses to check`. The client then tried again at `retryInterval`, with no end, and logged two warnings each time. A relay address tells nothing about the reachability of the host, so the client now probes only direct addresses, as in go-libp2p. This also applies to addresses from `addressFunc`. When no address is left to probe, the client records the reachability as unknown and waits for the next address change or AutoNAT server. It does not try again on a timer.

## [4.1.6] - 2026-10-05

### Fixed

- **A UDX connection died 30 s after it opened when two dials to the same peer started at once.** For example, two services that start together each call `connect()`. The two dials shared one UDX socket. The second dial waited on a socket that the first dial had already set up, timed out after 15 s, and its cleanup closed the shared socket. The connection that the first dial made then stopped 30 s after it opened, although the peer did not close it. Two changes fix this:
  - Concurrent `dialPeer` calls to the same peer now join one dial, as in go-libp2p. A dial with `forceDirectDial` or `forceFreshDial` joins only a dial with the same options.
  - Each UDX dial is now its own UDX connection (dart_udx 4.1.0, `createSocket(shared: false)`), so closing one dial cannot close another.

### Changed

- Requires `dart_udx` ^4.1.0.

## [4.1.5] - 2026-10-05

### Fixed

- **A dead UDX connection stayed in the swarm for about 30 s.** When a UDX session closed under the connection (for example, when its UDP socket closed), a read that waited for data was not stopped. Yamux's read loop waited forever, and the swarm kept the connection until a write or a keepalive ping failed. In that time, new streams to the peer failed with `Session is closing or closed`, and messages that the peer pushed were lost. A closed stream now ends a waiting read with EOF, and a session closes when its UDP socket closes. The swarm now drops the connection at once, and the next stream to the peer dials again.
- **One unreachable UDX address held a dial for minutes.** The handshake was tried 4 times in each of 4 dial attempts, and each try waited for the full dial timeout. The stream setup and the handshake now run once and share one dial timeout. The swarm decides whether to try again or to use another address.
- **A multistream read was tried again after a timeout.** The read that timed out continued to wait on the stream. The next try then competed with it for the same bytes, and a message that was partly read could be split between the two. A read timeout now fails the negotiation, as in go-libp2p. `MultistreamConfig.maxRetries` and `retryDelay` are no longer used; they stay so that existing code compiles.

## [4.1.4] - 2026-10-05

The test suite passes again, apart from the hole-punching tests that need a Docker NAT network. Fixing the 34 failures found these library bugs:

### Fixed

- **A UDX dial could leave from a socket that cannot reach the target.** Since 4.1.0, a dial reuses a listener's socket. It took any listener of the address family, so with a listener bound to `127.0.0.1` a dial to another host failed with `Can't assign requested address`. A listener bound to loopback is now used only for loopback targets; a listener on all interfaces is preferred.
- **The resource manager counted one stream or connection several times.** Changes passed up through each parent scope in turn, so the system scope counted a stream once per path to it (through the peer, the transient and the protocol scope). With the default limits this made "resource limit exceeded" errors come early. Each scope above a resource now counts it once, as in go-libp2p, and `setPeer`, `setProtocol` and `setService` move a resource only between the scopes that change.
- **A closed stream stayed in its connection's stream list** until the connection closed, so a long-lived connection kept every stream it had used. `SwarmStream.close()` removes the stream again; `SwarmConn.close()` no longer holds its lock while it closes the streams, which was why that removal had been taken out.
- **A host built by hand did not answer identify.** A `Swarm` hands incoming streams to its host, and only `Libp2p.new_` linked the two. `BasicHost.create` now links them if the swarm has no host, so a peer's `connect()` no longer waits for the identify timeout.
- **Multistream wrapped its own errors.** `MessageTooLargeException` and `IncorrectVersionException` reached callers as a generic `FormatException` and were logged at SEVERE. Both now extend `FormatException` and arrive with their own type; code that catches `FormatException` still catches them. A write to a closed stream now fails like a read does, with a `FormatException`.
- **An error on the relay service's reachability events was raised as an uncaught error.** `RelayManager` now logs it and keeps listening.
- `pingStream` logged every ping at WARNING; it logs at FINE.

### Tests

Out-of-date tests were brought up to the current behaviour: the 15 s and 30 s dial timeouts, the 2-byte Noise frame length, Noise keys that exist only after the handshake, circuit addresses that end with the host's own peer ID, AutoRelay advertising addresses after a reachability change, and the identify-timeout test's handler order. Mock streams whose `close()` never completed, and expectations that were not awaited, were fixed. The ping test now uses two real hosts.

## [4.1.3] - 2026-10-05

### Fixed

- **A saved Ed25519 identity could not be loaded again.** `Ed25519PrivateKey.marshal()` wrote 32 zero bytes where the private key belongs, followed by the public key, so the private key was lost. `Ed25519PrivateKey.unmarshal()` threw for every input, including keys from go-libp2p. `marshal()` now writes the seed followed by the public key (64 bytes), byte for byte what go-libp2p's `crypto.MarshalPrivateKey` writes, and `unmarshal()` reads it and go-libp2p's keys. The tests check both against go-libp2p v0.49.
- **`Ed25519PrivateKey.fromRawBytes()` with 64 bytes returned a different key.** It made a new random key pair and attached the given public key, so the result signed with a key that did not match its public key. It now derives the key from the seed and throws a `FormatException` if the public key in the bytes does not belong to it. It also accepts go-libp2p's legacy 96-byte form.
- **`Ed25519PrivateKey.raw` threw for generated keys.** Every key now keeps its 32-byte seed, which `raw` returns. (go-libp2p's `Raw()` returns the seed followed by the public key; `fromRawBytes()` accepts both.)

A key that an earlier version marshalled cannot be recovered: its private key was never written. `unmarshal()` rejects it with a `FormatException` that says so. Generate a new identity, or keep the seed (`raw`) as the internet chat demo does.

## [4.1.2] - 2026-10-05

### Fixed

- **A program that closed its hosts did not exit.** `Host.close()` left timers running, and a live timer keeps the Dart process alive. The README Quick Start printed "Connected successfully!" and then never ended. These timers now stop when the host closes:
  - the resource manager's garbage collector, for the host and for the AutoNAT dial-back host (the swarm that `Libp2p.new_` builds now closes the resource manager it was given; a `Swarm` that you construct yourself keeps it open unless you pass `closeResourceManager: true`);
  - the swarm's 30 s probe of relayed connections;
  - the hole punch service's address monitor;
  - the next AutoNAT v2 probe, which was a `Future.delayed` and could not be cancelled (`close()` also no longer waits up to 5 s for a probe that has not started);
  - the connection manager's 1 s status check for each connection.

### Documentation

- README: the Quick Start no longer imports `dart_udx`, which the install section does not list, or an unused import. The mDNS section no longer says that discovery crosses subnets (mDNS stays on the local network), and it says that the example cannot bind port 5353 on macOS. "Routing-based peer discovery" is replaced by a pointer to the Kademlia DHT package. The Testing section says which tests need Docker or Go, and the Contributing section no longer points to files that do not exist.

## [4.1.1] - 2026-10-04

### Fixed

- **A peer on the same port number got a dial from an ephemeral socket.** 4.1.0 kept a fresh socket for a dial to one of the host's own listeners, but it compared only the port number. A dial to a remote peer that listens on the same port number, as nodes on a fixed port all do, therefore still left from an ephemeral socket, and that peer observed an address that leads nowhere. The check now compares the address too: a dial counts as one to the host's own listener only for the listener's own address, or, for a listener on all interfaces, for a loopback or unspecified address with its port.

## [4.1.0] - 2026-10-04

A host behind NAT now learns its public address and can hole-punch without being told its external address.

### Fixed

- **A UDX host never learned its public address from the peers it dialed.** Every ordinary UDX dial left from a new ephemeral socket, so the peer saw the NAT mapping of a port nobody listens on, and the observed address manager rightly discarded it. A host behind NAT therefore advertised only its private addresses, and DCUtR had no public address to punch to unless the application configured one. Ordinary dials now leave from the listener's socket, as go-libp2p does with reuseport, so the observed address is the listen socket's public mapping. A dial to one of the host's own listener ports still gets a fresh socket.
- **Normal operation logged at WARNING and SEVERE.** Each `newStream` logged every phase at WARNING, and the swarm, Yamux stream resets, multistream negotiation, the circuit relay client and AutoRelay logged routine traces at WARNING. A peer that does not support a protocol, or a stream the remote closes during negotiation, logged at SEVERE with a stack trace, although the caller already gets the exception. These are now FINE, so an application can run at WARNING and see only problems. A relay reservation is logged at INFO.

### Added

- **`UDXTransport.dialFromEphemeralSocket`** dials from a fresh ephemeral socket instead of the listener's. The swarm uses it for a direct dial that is not coordinated with the peer, such as the one DCUtR tries before it punches: unanswered packets from the listen socket could leave an entry at the peer's NAT that makes the NAT remap the peer's punch. `Transport.dial` and `UDXTransport.dial` are unchanged.

## [4.0.1] - 2026-10-04

### Fixed

- **A stream handler that failed raised an unhandled error** — the protocol muxer calls handlers without awaiting them, and `setStreamHandler` dropped the handler's future, so any error after its first `await` escaped as an unhandled async error, which a test or a Flutter error zone reports as a crash. Identify push hit this when a host closed while a push was in flight. The error is now logged and the handler's stream reset; other streams and the host carry on, as in go-libp2p.

## [4.0.0] - 2026-10-04

DCUtR hole punching interoperates with go-libp2p over UDX, and ECDSA keys, identify and AutoNAT v2 now behave as in go-libp2p.

### Breaking

- **`Transport.dial` takes a `simultaneousConnect` parameter.** `dial(addr, {Duration? timeout, bool simultaneousConnect = false})` tells a transport that the dial is a DCUtR hole punch. Every `Transport` implementation must add the parameter; transports that cannot hole punch can ignore it. (Dmytro Naumenko)
- **ECDSA keys and signatures now match go-libp2p.** Public keys marshalled as a bare `SEQUENCE { x, y }` and private keys as `SEQUENCE { d, x, y }`; they now marshal as PKIX (SubjectPublicKeyInfo) and SEC 1 `ECPrivateKey`, as the spec and go-libp2p require, so ECDSA peer IDs change again and now equal go-libp2p's. Signatures were made and checked over SHA-256(SHA-256(data)), because pointycastle's signer hashed data the code had already hashed, so no other implementation could verify them; they now cover SHA-256(data) with an RFC 6979 nonce. Both legacy key forms still unmarshal (P-256 only); P-256, P-384 and P-521 keys from go-libp2p are accepted. Points off the curve and SEC 1 keys whose public key does not match the private value are rejected.

### Added

- **`Libp2p.observedAddrActivationThreshold`** sets how many peers must report the same observed address before it is used (default 4), for a host that trusts fewer observers. (Dmytro Naumenko)
- **`Context.withForceFreshDial`** makes `Swarm.dialPeer` dial a new connection even when a healthy one exists, for a caller that knows a connection is broken before the swarm's health checks notice. (Dmytro Naumenko)

### Changed

- **Requires dart_udx ^4.0.0**, in which crossing dials stay two connections, as with go-udx and js-udx; a hole punch to a go-libp2p peer needs it. The wire version is unchanged.
- **A fresh clone builds from published packages.** The dev dependencies on `dart_libp2p_kad_dht` and `dart_libp2p_pubsub` were circular: both depend on dart_libp2p and accept only `<3.0.0`, so pub could not resolve them for 4.0.0, and the committed path overrides hid this only on machines with all the sibling repos checked out. The DHT and GossipSub Go interop tests moved to those packages; a local dart-udx override now goes in a git-ignored `pubspec_overrides.yaml` (see README).

### Fixed

- **A host never identified peers that dialed it** — identify ran only on outbound connections, but the protocol informs only the side that opens the stream, so the listener never learned a dialer's listen addresses, protocols, agent version or public key, and got no observed address from it, until it happened to open a stream itself. Identify now runs on every new connection from both ends, as go-libp2p does.
- **`generateEcdsaKeyPair()` never returned** — it called itself instead of the commented-out generator it meant to use. It now generates a P-256 key pair.
- **A refused TCP dial seemed to go to a random port** — Dart's `SocketException` for a failed connect reports the socket's local ephemeral port, and the TCP transport passed that text through, so the error named a port the library never dialed. The error now names the dialed multiaddr. (#14, reported by cloudabe)
- **AmbientAutoNATv2 left its event bus subscription open after `close()`** — it cancelled its listener but never closed the subscription, so the bus kept delivering events into it.
- **Observed addresses were never activated** — three logic errors in the observed-address manager (protocol codes compared with `Protocol` objects, a missing circuit component treated as present, and parsed values assigned through parameters Dart cannot return through) rejected every observation. (Dmytro Naumenko)
- **Identify was skipped on relayed connections** — a peer reached over a relay never learned the other side's protocols or observed addresses, unlike go-libp2p, which identifies before DCUtR. Identify now runs on relayed connections too; the 30-second timeout that once motivated the skip does not occur in the holepunch harness. (Dmytro Naumenko)
- **New streams could go over a relayed connection while a direct one existed** — `dialPeer` returned the newest healthy connection, which may be the relayed one; it now prefers the newest direct connection. (Dmytro Naumenko)
- **RSA public keys and PeerIds were parsed too loosely or not at all** — `RsaPublicKey.fromRawBytes` validates PKCS#1 and RSA SubjectPublicKeyInfo and rejects other input with a `FormatException`, and `PeerId.decode` accepts any raw base58 identity or sha256 multihash. (Dmytro Naumenko)
- **A punch dial could miss an open UDX listener** — only the most recent listener per address family was remembered; closed listeners are now dropped from a per-family list. (Dmytro Naumenko)
- **Yamux logged teardown errors as SEVERE and slept 1 ms per frame on fast transports**, and a stream whose peer never sent a standalone ACK kept its pending-ACK entry forever. (Dmytro Naumenko)
- **IPv6 TCP listeners crashed `host.start()`** — TCP built its local, remote and listen addresses with `/ip4/` whatever the socket's family, so an IPv6 socket produced `/ip4/::1/...`, which fails to parse. Addresses now take the socket's family, as UDX already did. (Dmytro Naumenko)
- **DCUtR punches got their port rewritten by the NAT** — the uncoordinated direct dial DCUtR makes before punching was flagged as a simultaneous connect, so UDX sent it from the listener socket. Its unanswered packets left a NAT entry for that port pair at the peer's NAT, and the real punch from the same port was then given a different external port. Only punch dials are now simultaneous connects (`Context.withSimultaneousConnect`, which the hole punch code had been setting under keys nothing read); a force-direct dial alone uses a fresh socket. With this, two Dart peers behind cone NATs establish a direct UDX connection in the holepunch docker harness.
- **AutoNAT v2 dropped connections to the peers it probed** — the server dialed back through the host itself, so a dial-back could reuse an existing (even relayed) connection and confirm an address it never dialed, and its cleanup closed every connection to the peer and cleared its addresses. In a DCUtR exchange this removed the relayed connection the punch was coordinated over. AutoNAT v2 now dials back from a separate host with its own identity, swarm and peerstore, as go-libp2p does.
- **go-libp2p could not reserve on a Dart relay** — the relay sent the reservation voucher as a bare protobuf, but relay v2 requires an envelope signed by the relay under `libp2p-relay-rsvp`, and go-libp2p rejected the reservation with `MALFORMED_MESSAGE`. The voucher is now sealed with the relay's key.
- **AutoRelay never reserved on a relay connected after start** — RelayFinder asked its peer source for candidates once at start and never again, because each later tick was skipped while the finder was listening, which is always. Hosts also advertised the circuit client's bare `/p2p-circuit` listen address, which no peer can dial; it is no longer advertised.
- **The UDX listener dropped a second connection from the same address** — it kept one session per `host:port` and closed any later connection from that address as a duplicate. go-udx and js-udx dial every connection from one socket, and a hole punch leaves an inbound and an outbound connection to the same peer; sessions are now kept per connection. Together with dart_udx 4.0.0's fix for crossing dials, a Dart peer and a go-libp2p peer establish a direct UDX connection by hole punching.
- **AutoNAT v2 never confirmed an address** — the client looked up the dial-back nonce, a protobuf `Int64`, in a map keyed by `int`, so every dial-back was rejected and every probe failed.
- **DCUtR did not interoperate with go-libp2p** — holepunch messages were written without a length prefix and read with a single unbounded `read()`, but go-libp2p frames them with an unsigned varint length. A Dart peer failed with `InvalidProtocolBufferException` on go's CONNECT and go reset the stream. Messages are now length-delimited and read through a buffered reader. (Dmytro Naumenko)
- **The punch dial never ran** — `BasicHost.connect` and `Swarm.dialPeer` returned the existing relayed connection, which DCUtR always starts from, so the holepuncher logged a successful direct connection without dialing. Force-direct dials now skip a relayed connection and never dial `/p2p-circuit` addresses; previously a new relayed connection could win the race and be reported as a hole punch. (Dmytro Naumenko)
- **The answering side of DCUtR threw before dialing** — `Context.getForceDirectDial()` cast its value to `String`, but the hole punch service stores `true`. (Dmytro Naumenko)
- **UDX punch dials came from the wrong port** — every dial bound a fresh UDP socket, so the NAT mapping did not match the address sent in CONNECT. A punch dial now reuses the open listener's socket for that address family. (Dmytro Naumenko)
- **`BasicHost.connect` stored this host's own addresses under the peer** — it ran the host's `addrsFactory` over the peer's addresses, so later dials to that peer tried this host's external address. (Dmytro Naumenko)
- **Hosts advertised addresses no socket listens on** — an unspecified listener was expanded onto interfaces of the other IP family, e.g. an IPv4 port on an IPv6 address. (Dmytro Naumenko)
- **The hole punch service advertised only observed addresses** — it now uses `host.addrs` without relay addresses, so addresses supplied through `addrsFactory` are offered in CONNECT. (Dmytro Naumenko)
- **A failed inbound upgrade raised an unhandled error** when no dial was waiting for that peer.

## [3.0.0] - 2026-10-02

### Breaking

- **RSA and ECDSA peer IDs change.** `PeerId.fromPublicKey`/`fromPrivateKey` stored the marshalled key under a sha2-256 multihash code without hashing it, so any key over 42 bytes got a long `22…` ID that no other libp2p implementation produces or accepts. Keys are now hashed, and RSA public keys marshal to PKIX (SubjectPublicKeyInfo) as the spec requires, so RSA IDs match go-libp2p's `Qm…` IDs. Ed25519 IDs are unchanged. Any stored RSA or ECDSA peer ID produced by an earlier release must be re-derived.

### Changed

- **Requires dart_udx ^3.1.0**, which fixes interoperability with go-udx and js-udx: frame type codes, STREAM_DATA_BLOCKED, ACK range overflow, connections from one address, and several streams on one connection (go-udx and js-udx open every stream to destination 0, and 3.0.0 merged them all into the first). The wire version is unchanged.

### Fixed
- **Yamux never saw go-libp2p or js-libp2p end a stream** — they half-close with a WINDOW_UPDATE carrying FIN rather than an empty DATA frame with FIN; both are valid Yamux, but the FIN flag on WINDOW_UPDATE was ignored. `read()` kept waiting, protocol handlers that read to EOF never finished, and js-libp2p's connection monitor aborted idle connections to Dart nodes after ~20 s because its half-open ping streams piled up. The FIN now takes the DATA path, so it lands behind any data still queued.
- **A peer resetting a UDX stream crashed the process** — `UDXP2PStreamAdapter` and `UDXSessionConn` completed their `onClose` future with the error, and usually nothing listens to it, so a remote reset escaped as an unhandled `UDXTransportException`. The future is now marked handled; an `onClose` listener still receives the error.
- **Noise rejected non-Ed25519 peers** — the handshake payload's identity key was always decoded as Ed25519, so RSA peers such as the IPFS bootstrap relays could not connect. Any supported key type is now accepted, and RSA keys in SPKI form are parsed. (Darren Warner)
- **Yamux streams deadlocked against rust-libp2p** — `openStream()` waited for the remote's ACK before returning, but rust-libp2p sends its ACK with its first frame on the stream, which it only sends after reading ours. `openStream()` now returns once the SYN is sent, as the yamux spec allows and go-yamux does. (Darren Warner)

## [2.0.0] - 2026-09-23

### Breaking

- **Requires dart_udx ^3.0.0, whose wire protocol v3 does not interoperate with v2.** A node on this release cannot connect to a 1.0.x node over UDX: a version mismatch is dropped on receive and looks like an unreachable peer. Both ends of a UDX connection must be upgraded together. No dart_libp2p API changed; the break is on the wire. See dart-udx's changelog for what v3 buys, chiefly per-stream reassembly so a gap on one stream no longer stalls the others, which matters here because UDX carries every libp2p stream.

### Changed
- **Default yamux `maxFrameSize` raised from 16KB to 256KB** — Larger frames improve throughput for large responses. The 16KB default limited head-of-line blocking when an encrypted message was lost in transit; dart_udx 2.0.3 reassembles streams on byte offsets rather than packet sequence, so smaller frames buy less than they did. Pass `maxFrameSize` to `MultiplexerConfig` to keep the old value.

### Fixed
- **Yamux streams never freed their slot** — A stream that finished (local close, local or remote reset, or a remote FIN read to EOF) stayed in the session's stream table until the whole session closed, so `numStreams` only grew and every connection refused new streams with `Bad state: Maximum streams reached` once it had opened `maxStreams` of them. Streams now release their slot when they reach a terminal state, and frames arriving for a finished stream are logged at `fine` instead of as a warning.
- **Uncaught `Session closed while opening stream` error** — If a session was torn down while `openStream()` was still writing its SYN, the pending ACK completer failed with no listener, so the error escaped to the caller's zone as an uncaught error on top of the error `openStream()` itself returned. The completer is now marked handled; `openStream()` still fails as before.
- **Identify raced with the protocol book** — `ProtoBook.setProtocols`/`addProtocols`/`removeProtocols` were declared `void` but implemented as `Future<void>`, so identify did not await them and the protocol book could still be empty right after `connect()` returned. These now return `Future<void>` and every caller awaits them.
- **Stalled inbound protocol negotiations hung forever** — The active inbound path in `Swarm._handleIncomingStreams` called `mux.handle()` without a deadline, bypassing the one `BasicHost` sets. It now applies a configurable deadline (10s by default) and clears it afterwards.
- **DHT streams failed after a relay reservation over UDX** — Incoming yamux streams arriving between `acceptStream()` calls were dropped by a broadcast controller and are now buffered in a queue; `SecuredConnection` separates encryption (locked) from UDX transmission (lock-free) through an async write queue, so the Noise lock no longer blocks yamux; and identify refreshes its snapshot in `start()` and `sendIdentifyResp()` so the first exchange advertises the protocols actually registered.
- **UDX transport error handling on macOS** — Transient errors (connection refused, no route to host, connection timed out) are recognised by their macOS errno values as well as the Linux ones, and the raw socket is closed when a connection fails, which leaked a socket before.

### Changed (internal)
- Diagnostic logging added while debugging UDX relay issues is back at `fine` level, removing per-frame and timing noise from production logs.
- Test infrastructure: Docker plus netem harness reproducing the production DHT stream failure against the go-ricochet binary.

## [1.0.3] - 2026-02-22

### Fixed
- **UDX large payload stalls** — Bumped dart_udx to 2.0.3 which fixes control-only stream packets (WindowUpdate) consuming sequence numbers, causing permanent receiver stalls on payloads >60KB.

## [1.0.2] - 2026-02-22

### Fixed
- **AutoNAT v2 go-libp2p interop** — Client and server now use varint-length-prefixed (delimited) message framing, matching go-libp2p's `pbio.NewDelimitedReader`/`Writer`. Previously raw protobuf bytes were written without length prefixes, causing `Message_Msg.notSet` parse errors when communicating with go-libp2p AutoNAT v2 servers.
- **AutoNAT v2 probe spam** — AmbientAutoNATv2 now checks for available peers before attempting a probe, avoiding noisy `Exception: no valid peers for autonat v2` errors with full stack traces every 5 seconds during startup.
- **AutoNAT v2 backoff** — When no AutoNAT v2 peers are available, probes now use exponential backoff (10s, 20s, 40s, 60s cap) instead of retrying at the fixed retry interval.
- **AutoNAT v2 log levels** — Probe errors downgraded from `severe` (with stack trace) to `warning`; no-peers condition logged at `fine` level.

### Added
- `AutoNATv2.hasPeers` getter to check peer availability without throwing exceptions.
- Initial `UNKNOWN` reachability event emitted on the no-peers path so AutoRelay can start even without AutoNAT v2 peers.

## [1.0.1] - 2026-02-21

### Added
- **WebRTC protocol** definition in multiaddr parser

### Fixed
- Yamux session metrics observer null-safety for `remotePeer` access
- Yamux stream close/reset handling improvements
- UDXSessionConn crash when constructor fails before registration
- Self-dial attempt now logged instead of silently returning
- Test reliability improvements across 15 test files (timeouts, resource cleanup)

## [1.0.0] - 2026-02-17

### Added
- **Go-libp2p interoperability** — Full cross-language compatibility with go-libp2p nodes
  - Echo server/client interop tests (TCP and UDX)
  - GossipSub interop tests (both directions)
  - Kademlia DHT interop tests with `/pk/` namespace support
  - `ADD_PROVIDER`/`GET_PROVIDERS` interop
  - Circuit Relay v2 interop tests
  - Identify push interop test (Go → Dart)
  - UDX transport support in Go peer binary
- **Circuit Relay v2** — Full relay implementation with e2e relayed handshakes
  - Connection reuse to prevent duplicate relay connections
  - Parallel dialing support
  - Relay address de-duplication
  - `relayServers` configuration setting
- **AmbientAutoNATv2** — NAT detection with Circuit Relay v2 integration
- **AutoRelay** — Automatic relay discovery, including CGNAT support
- **Hole Punching** — NAT traversal with Docker-based integration test framework
- **Half-close** — Added half-close semantics to the stream stack
- **Happy Eyeballs** — Capability-aware connection establishment
- **Typed exceptions** — `IdentifyTimeoutException` for graceful timeout handling
- **Yamux `maxFrameSize` configuration** with large bidirectional transfer stress tests
- **Bidirectional relay data transfer tests** (mock + e2e integration)
- **mDNS** — Bug fixes, updates, and working examples

### Changed (Breaking)
- **Noise protocol** — Spec compliance changes for go-libp2p interoperability
- **Yamux** — Spec compliance fixes for go-libp2p interoperability (fire-and-forget write responses)
- **Multistream** — Buffering changes for go-libp2p interoperability
- **Identify** — Fixes for signed peer record registration and identify push
- **DHT** — `DHTMode.client` fixes, `/pk/` namespace support

### Fixed
- Noise handshake failure from multistream leftover byte loss
- UDX transport deadlock and connection lifecycle issues
- UDX transport killing long-lived yamux connections
- Yamux zombie sessions — close on keepalive ping send failure
- Yamux read loop blocking
- Concurrent read race condition
- Concurrent upgrade race condition on parallel circuit dials
- MAC authentication errors on large message transfers
- Stream deadline handling
- Relay latching bug — skip identify for circuit-relay connections
- Relay latching — remove reservations when peers disconnect
- AutoRelay not starting RelayFinder behind CGNAT
- Graceful terminal state transitions
- Stale connection handling with default ConnectionManager

## [0.5.3] - 2025-08-16
### Changed
- Updated the Quickstart example in the README. The original example was referencing outdated APIs and would not compile. 

### Added
- Initial changelog documentation

## [0.5.2] - 2025-07-29

### Added
- Comprehensive documentation in `/doc` directory
- Architecture overview and component documentation
- Configuration guide with flexible options system
- Transport layer documentation (TCP and UDX)
- Security protocol documentation (Noise)
- Multiplexing documentation (Yamux)
- Protocol documentation (Ping, Identify, etc.)
- Peerstore management documentation
- Event bus system documentation
- Resource manager documentation
- Cookbook with practical examples
- Getting started guide with step-by-step instructions
- README.md with project overview and quick start guide
- MIT LICENSE file

### Changed
- Improved project structure and organization
- Enhanced documentation coverage across all components
- Better code examples and usage patterns

### Fixed
- Documentation links and cross-references
- Code examples in documentation

---

## Contributing

When contributing to this project, please update this changelog by adding a new entry under the `[Unreleased]` section. Follow the existing format and include:

- **Added**: for new features
- **Changed**: for changes in existing functionality
- **Deprecated**: for soon-to-be removed features
- **Removed**: for now removed features
- **Fixed**: for any bug fixes
- **Security**: in case of vulnerabilities

## Release Process

1. Update version in `pubspec.yaml`
2. Add new changelog entry under `[Unreleased]`
3. Move `[Unreleased]` content to new version section
4. Update release date
5. Tag the release in git 