# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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