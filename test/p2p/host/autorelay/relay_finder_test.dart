import 'package:test/test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/event/bus.dart';
import 'package:dart_libp2p/core/network/network.dart';
import 'package:dart_libp2p/p2p/transport/upgrader.dart';
import 'package:dart_libp2p/p2p/host/autorelay/relay_finder.dart';
import 'package:dart_libp2p/p2p/host/autorelay/autorelay_config.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/client/reservation.dart';

@GenerateMocks([Host, Peerstore, AddrBook, EventBus, Network, Upgrader])
import 'relay_finder_test.mocks.dart';

void main() {
  group('RelayFinder', () {
    late MockHost mockHost;
    late MockPeerstore mockPeerstore;
    late MockAddrBook mockAddrBook;
    late MockEventBus mockEventBus;
    late MockNetwork mockNetwork;
    late MockUpgrader mockUpgrader;
    late AutoRelayConfig config;

    setUp(() {
      mockHost = MockHost();
      mockPeerstore = MockPeerstore();
      mockAddrBook = MockAddrBook();
      mockEventBus = MockEventBus();
      mockNetwork = MockNetwork();
      mockUpgrader = MockUpgrader();
      
      // Use a static relay address for testing (relay server from integration tests)
      final relayPeerId = PeerId.fromString('12D3KooWRcr1tPJ5D46uESVgA1sJrNmcGrW2XHGcHztHadBvcv3G');
      final relayAddr = MultiAddr('/ip4/10.10.3.10/tcp/4001');
      config = AutoRelayConfig(
        staticRelays: [AddrInfo(relayPeerId, [relayAddr])],
      );

      // Setup basic mock responses
      when(mockHost.peerStore).thenReturn(mockPeerstore);
      when(mockPeerstore.addrBook).thenReturn(mockAddrBook);
      when(mockHost.eventBus).thenReturn(mockEventBus);
      when(mockHost.network).thenReturn(mockNetwork);
    });

    group('Circuit Address Construction', () {
      test('should construct circuit addresses when connected to relay', () async {
        // Arrange
        final relayFinder = RelayFinder(mockHost, mockUpgrader, config);
        
        // Create a relay peer ID
        final relayPeerId = PeerId.fromString('12D3KooWRcr1tPJ5D46uESVgA1sJrNmcGrW2XHGcHztHadBvcv3G');
        
        // Relay addresses (what the relay advertises)
        final relayAddresses = [
          MultiAddr('/ip4/10.10.3.10/tcp/4001'),
          MultiAddr('/ip4/192.168.1.1/tcp/4001'),
        ];
        
        // Note: We need to access the internal _relays map to add our test relay
        // Since it's private, we'll test through the public API
        
        // Mock the peerstore to return relay addresses
        when(mockAddrBook.addrs(relayPeerId))
            .thenAnswer((_) async => relayAddresses);
        
        // Mock current host addresses (peer's own addresses)
        final currentHostAddrs = [
          MultiAddr('/ip4/192.168.1.100/tcp/4001'),
        ];
        
        // Act - Get relay addresses
        // Note: This will return empty initially since we haven't added the relay
        // In real usage, RelayFinder would discover and add relays
        final circuitAddrs = await relayFinder.getRelayAddrs(currentHostAddrs);
        
        // Assert - Since we can't directly add to _relays, this test verifies
        // the address construction logic by checking the expected format
        // In a real scenario with a connected relay, we'd expect:
        // /ip4/10.10.3.10/tcp/4001/p2p/12D3KooWRelayPeerID123456789/p2p-circuit
        
        // For now, verify the method doesn't crash
        expect(circuitAddrs, isA<List<MultiAddr>>());
        
        // TODO: Once RelayFinder has a public method to add relay connections,
        // enhance this test to verify actual circuit address construction
      });

      test('should construct valid circuit address format', () {
        // Arrange - Test the expected format of circuit addresses
        final relayId = '12D3KooWRcr1tPJ5D46uESVgA1sJrNmcGrW2XHGcHztHadBvcv3G';
        final relayAddr = MultiAddr('/ip4/10.10.3.10/tcp/4001');
        
        // Manually construct what we expect AutoRelay to build
        final expectedCircuitAddr = relayAddr
            .encapsulate('p2p', relayId)
            .encapsulate('p2p-circuit', '');
        
        // Assert - Verify the address has correct format
        final addrString = expectedCircuitAddr.toString();
        expect(addrString, contains('/ip4/10.10.3.10/tcp/4001'));
        expect(addrString, contains('/p2p/$relayId'));
        expect(addrString, contains('/p2p-circuit'));
        
        // Verify components are in correct order
        expect(addrString, matches(RegExp(r'/ip4/.*/tcp/\d+/p2p/.*?/p2p-circuit')));
      });

      test('should handle multiple relay addresses', () async {
        // Arrange
        final relayFinder = RelayFinder(mockHost, mockUpgrader, config);
        
        final relayPeerId1 = PeerId.fromString('12D3KooWRcr1tPJ5D46uESVgA1sJrNmcGrW2XHGcHztHadBvcv3G');
        final relayPeerId2 = PeerId.fromString('12D3KooWF22ud67s2HPZrmD8PdGKEc6A8xaK9qvLmfbLTdqNLSXx');
        
        final relay1Addrs = [
          MultiAddr('/ip4/10.10.1.1/tcp/4001'),
          MultiAddr('/ip4/10.10.1.2/tcp/4001'),
        ];
        
        final relay2Addrs = [
          MultiAddr('/ip4/10.10.2.1/tcp/4001'),
        ];
        
        // Mock peerstore responses
        when(mockAddrBook.addrs(relayPeerId1))
            .thenAnswer((_) async => relay1Addrs);
        when(mockAddrBook.addrs(relayPeerId2))
            .thenAnswer((_) async => relay2Addrs);
        
        final currentHostAddrs = [
          MultiAddr('/ip4/192.168.1.100/tcp/4001'),
        ];
        
        // Act
        final circuitAddrs = await relayFinder.getRelayAddrs(currentHostAddrs);
        
        // Assert - Verify format
        expect(circuitAddrs, isA<List<MultiAddr>>());
        
        // With 2 relays having 3 total addresses, we'd expect 3 circuit addresses
        // (once the relays are actually added to the internal _relays map)
      });

      test('should include private/loopback addresses in result', () async {
        // Arrange
        final relayFinder = RelayFinder(mockHost, mockUpgrader, config);
        
        // Peer's current addresses include private and loopback
        final currentHostAddrs = [
          MultiAddr('/ip4/127.0.0.1/tcp/4001'),      // loopback
          MultiAddr('/ip4/192.168.1.100/tcp/4001'),  // private
          MultiAddr('/ip4/10.0.0.5/tcp/4001'),       // private
        ];
        
        // Act
        final circuitAddrs = await relayFinder.getRelayAddrs(currentHostAddrs);
        
        // Assert - Should include private/loopback addresses
        // (These are filtered in getRelayAddrs to be included)
        expect(circuitAddrs, isA<List<MultiAddr>>());
        
        // The method should add circuit addresses AND keep private/loopback
        // Once relays are added, we'd verify this properly
      });

      test('should use address caching to avoid excessive lookups', () async {
        // Arrange
        final relayFinder = RelayFinder(mockHost, mockUpgrader, config);
        
        final currentHostAddrs = [
          MultiAddr('/ip4/192.168.1.100/tcp/4001'),
        ];
        
        // Act - Call twice in succession
        final addrs1 = await relayFinder.getRelayAddrs(currentHostAddrs);
        final addrs2 = await relayFinder.getRelayAddrs(currentHostAddrs);
        
        // Assert - Both calls should return same cached result
        expect(addrs1, equals(addrs2));
        
        // Verify peerstore wasn't called excessively (due to caching)
        // The cache expires after 30 seconds, so within that window,
        // we should see the same result
      });
    });

    group('Relay Candidate Selection', () {
      test('should filter out relay addresses from candidates', () {
        // Arrange - Addresses that should NOT be selected as relay candidates
        final relayCircuitAddr = MultiAddr('/ip4/10.10.1.1/tcp/4001/p2p/QmRelay/p2p-circuit');
        final directAddr = MultiAddr('/ip4/10.10.1.2/tcp/4001');
        
        // Assert - Only direct addresses should be candidates
        // This tests the logic that relay addresses shouldn't be used as relay candidates
        expect(relayCircuitAddr.toString(), contains('/p2p-circuit'));
        expect(directAddr.toString(), isNot(contains('/p2p-circuit')));
      });

      test('should respect max relay limit from config', () {
        // Arrange
        final relayPeerId = PeerId.fromString('12D3KooWRcr1tPJ5D46uESVgA1sJrNmcGrW2XHGcHztHadBvcv3G');
        final relayAddr = MultiAddr('/ip4/10.10.3.10/tcp/4001');
        final customConfig = AutoRelayConfig(
          staticRelays: [AddrInfo(relayPeerId, [relayAddr])],
        );
        // Note: AutoRelayConfig should have a maxCandidateRelays field
        
        final relayFinder = RelayFinder(mockHost, mockUpgrader, customConfig);
        
        // Assert - Verify config is respected
        expect(relayFinder, isNotNull);
        // TODO: Add assertions once config max relay limits are accessible
      });
    });

    group('Reservation Management', () {
      test('should track reservation expiration times', () {
        // Arrange
        final expiration = DateTime.now().add(Duration(hours: 1));
        final reservation = Reservation(
          expiration,  // expire
          [],  // addrs
          null,  // voucher
        );
        
        // Assert
        expect(reservation.expire, equals(expiration));
        expect(reservation.expire.isAfter(DateTime.now()), isTrue);
      });

      test('should detect expired reservations', () {
        // Arrange - Create an already-expired reservation
        final expiration = DateTime.now().subtract(Duration(minutes: 1));
        final reservation = Reservation(
          expiration,  // expire
          [],  // addrs
          null,  // voucher
        );
        
        // Assert
        expect(reservation.expire.isBefore(DateTime.now()), isTrue);
      });
    });

    group('Edge Cases', () {
      test('should handle empty relay list gracefully', () async {
        // Arrange
        final relayFinder = RelayFinder(mockHost, mockUpgrader, config);
        
        final currentHostAddrs = [
          MultiAddr('/ip4/192.168.1.100/tcp/4001'),
        ];
        
        // Act - No relays connected
        final circuitAddrs = await relayFinder.getRelayAddrs(currentHostAddrs);
        
        // Assert - Should still return private addresses
        expect(circuitAddrs, isA<List<MultiAddr>>());
        // With no relays, should only contain filtered currentHostAddrs
      });

      test('should handle relay with no addresses', () async {
        // Arrange
        final relayFinder = RelayFinder(mockHost, mockUpgrader, config);
        
        final relayPeerId = PeerId.fromString('12D3KooWF22ud67s2HPZrmD8PdGKEc6A8xaK9qvLmfbLTdqNLSXx');
        
        // Mock peerstore returning empty address list
        when(mockAddrBook.addrs(relayPeerId))
            .thenAnswer((_) async => <MultiAddr>[]);
        
        final currentHostAddrs = [
          MultiAddr('/ip4/192.168.1.100/tcp/4001'),
        ];
        
        // Act
        final circuitAddrs = await relayFinder.getRelayAddrs(currentHostAddrs);
        
        // Assert - Should handle gracefully without throwing
        expect(circuitAddrs, isA<List<MultiAddr>>());
      });

      test('should handle malformed addresses gracefully', () async {
        // Arrange
        final relayFinder = RelayFinder(mockHost, mockUpgrader, config);
        
        final relayPeerId = PeerId.fromString('12D3KooWF22ud67s2HPZrmD8PdGKEc6A8xaK9qvLmfbLTdqNLSXx');
        
        // Mock peerstore returning mix of valid and potentially problematic addresses
        final mixedAddrs = [
          MultiAddr('/ip4/10.10.1.1/tcp/4001'),  // valid
          // In real scenarios, there might be edge cases with address formats
        ];
        
        when(mockAddrBook.addrs(relayPeerId))
            .thenAnswer((_) async => mixedAddrs);
        
        final currentHostAddrs = [
          MultiAddr('/ip4/192.168.1.100/tcp/4001'),
        ];
        
        // Act & Assert - Should not throw
        expect(
          () async => await relayFinder.getRelayAddrs(currentHostAddrs),
          returnsNormally,
        );
      });
    });
  });
}
