import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/p2p/host/peerstore/pstoremem/peerstore.dart';
import 'package:test/test.dart';

void main() {
  group('MemoryPeerstore', () {
    late MemoryPeerstore peerstore;
    late PeerId peerId;
    late List<MultiAddr> multiaddrs;

    setUp(() async {
      peerstore = MemoryPeerstore();
      peerId = await PeerId.random();
      multiaddrs = [
        MultiAddr('/ip4/127.0.0.1/tcp/12345'),
        MultiAddr('/ip4/192.168.1.100/tcp/54321'),
      ];
    });

    test('should retrieve peer with addresses after addOrUpdatePeer', () async {
      // Add peer with addresses
      peerstore.addOrUpdatePeer(peerId, addrs: multiaddrs);

      // Get the peer
      final retrievedPeerInfo = await peerstore.getPeer(peerId);

      // Assertions
      expect(retrievedPeerInfo, isNotNull, reason: 'PeerInfo should not be null after adding addresses.');
      if (retrievedPeerInfo != null) {
        expect(retrievedPeerInfo.addrs, isNotEmpty, reason: 'PeerInfo.addrs should not be empty.');
        expect(retrievedPeerInfo.addrs.length, equals(multiaddrs.length), reason: 'PeerInfo.addrs length should match added addresses.');
        for (var addr in multiaddrs) {
          expect(retrievedPeerInfo.addrs.contains(addr), isTrue, reason: 'PeerInfo.addrs should contain address $addr');
        }
      }
    });

    test('getPeer returns null for non-existent peer', () async {
      final nonExistentPeerId = await PeerId.random();
      final retrievedPeerInfo = await peerstore.getPeer(nonExistentPeerId);
      expect(retrievedPeerInfo, isNull);
    });
    
    test('addOrUpdatePeer with protocols and metadata', () async {
      final protocols = ['/test/1.0.0', '/example/2.0'];
      final metadata = {'key1': 'value1', 'key2': 123};

      peerstore.addOrUpdatePeer(peerId, protocols: protocols, metadata: metadata);
      final retrievedPeerInfo = await peerstore.getPeer(peerId);

      expect(retrievedPeerInfo, isNotNull);
      if (retrievedPeerInfo != null) {
        expect(retrievedPeerInfo.protocols, equals(protocols.toSet()));
        expect(retrievedPeerInfo.metadata, equals(metadata));
      }
    });

    test('addOrUpdatePeer updates existing peer data', () async {
      // Initial add
      peerstore.addOrUpdatePeer(peerId, addrs: [multiaddrs[0]], protocols: ['/initial/1.0']);
      
      // Update
      final updatedProtocols = ['/updated/1.0', '/another/2.0'];
      final updatedMetadata = {'newKey': 'newValue'};
      peerstore.addOrUpdatePeer(peerId, addrs: [multiaddrs[1]], protocols: updatedProtocols, metadata: updatedMetadata);

      final retrievedPeerInfo = await peerstore.getPeer(peerId);
      expect(retrievedPeerInfo, isNotNull);
      if (retrievedPeerInfo != null) {
        // Addresses should be merged by AddrBook (current MemoryPeerstore uses Duration.zero, so this might not reflect a merge yet)
        // For now, we expect at least the latest address to be there if TTLs were working as expected.
        // This part of the test will become more relevant after fixing TTL in addOrUpdatePeer.
        expect(retrievedPeerInfo.addrs.contains(multiaddrs[1]), isTrue, reason: "Should contain the subsequently added address");
        
        expect(retrievedPeerInfo.protocols, equals(updatedProtocols.toSet()), reason: "Protocols should be overwritten by setProtocols");
        expect(retrievedPeerInfo.metadata, equals(updatedMetadata), reason: "Metadata should be updated");
      }
    });

  });
}
