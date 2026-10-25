import 'package:dart_libp2p/p2p/network/conn_gater.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:test/test.dart';
import '../../mocks/mock_connection.dart';

void main() {
  group('BasicConnGater', () {
    late BasicConnGater gater;
    late MockConnection mockConn;
    late PeerId mockPeerId;
    late MultiAddr mockAddr;

    setUp(() {
      gater = BasicConnGater();
      mockConn = MockConnection(
        localAddr: MultiAddr('/ip4/127.0.0.1/tcp/1234'),
        remoteAddr: MultiAddr('/ip4/127.0.0.1/tcp/5678'),
        remotePeer: PeerId.fromString('QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC'),
      );
      mockPeerId = PeerId.fromString('QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC');
      mockAddr = MultiAddr('/ip4/127.0.0.1/tcp/1234');
    });

    group('Peer blocking', () {
      test('blocks and unblocks peers', () {
        expect(gater.isPeerBlocked(mockPeerId), isFalse);
        
        gater.blockPeer(mockPeerId);
        expect(gater.isPeerBlocked(mockPeerId), isTrue);
        
        gater.unblockPeer(mockPeerId);
        expect(gater.isPeerBlocked(mockPeerId), isFalse);
      });

      test('interceptPeerDial blocks blocked peers', () {
        gater.blockPeer(mockPeerId);
        expect(gater.interceptPeerDial(mockPeerId), isFalse);
      });

      test('interceptPeerDial allows unblocked peers', () {
        expect(gater.interceptPeerDial(mockPeerId), isTrue);
      });
    });

    group('Address blocking', () {
      test('blocks and unblocks addresses', () {
        expect(gater.isAddrBlocked(mockAddr), isFalse);
        
        gater.blockAddr(mockAddr);
        expect(gater.isAddrBlocked(mockAddr), isTrue);
        
        gater.unblockAddr(mockAddr);
        expect(gater.isAddrBlocked(mockAddr), isFalse);
      });

      test('interceptAddrDial blocks blocked addresses', () {
        gater.blockAddr(mockAddr);
        expect(gater.interceptAddrDial(mockPeerId, mockAddr), isFalse);
      });

      test('interceptAddrDial allows unblocked addresses', () {
        expect(gater.interceptAddrDial(mockPeerId, mockAddr), isTrue);
      });
    });

    group('Connection blocking', () {
      test('blocks and unblocks connections', () {
        expect(gater.isConnBlocked(mockConn.id), isFalse);
        
        gater.blockConn(mockConn.id);
        expect(gater.isConnBlocked(mockConn.id), isTrue);
        
        gater.unblockConn(mockConn.id);
        expect(gater.isConnBlocked(mockConn.id), isFalse);
      });

      test('interceptAccept blocks blocked connections', () {
        gater.blockConn(mockConn.id);
        expect(gater.interceptAccept(mockConn), isFalse);
      });

      test('interceptAccept allows unblocked connections', () {
        expect(gater.interceptAccept(mockConn), isTrue);
      });
    });

    group('Subnet blocking', () {
      test('blocks and unblocks subnets', () {
        final subnet = '192.168.1.0/24';
        expect(gater.isSubnetBlocked(subnet), isFalse);
        
        gater.blockSubnet(subnet);
        expect(gater.isSubnetBlocked(subnet), isTrue);
        
        gater.unblockSubnet(subnet);
        expect(gater.isSubnetBlocked(subnet), isFalse);
      });

      test('interceptAddrDial blocks addresses in blocked subnets', () {
        gater.blockSubnet('192.168.1.0/24');
        final addr = MultiAddr('/ip4/192.168.1.100/tcp/1234');
        expect(gater.interceptAddrDial(mockPeerId, addr), isFalse);
      });

      test('interceptAddrDial allows addresses not in blocked subnets', () {
        gater.blockSubnet('192.168.1.0/24');
        final addr = MultiAddr('/ip4/10.0.0.1/tcp/1234');
        expect(gater.interceptAddrDial(mockPeerId, addr), isTrue);
      });
    });

    group('Address prefixes', () {
      test('an address with only an IP blocks every port of that IP', () {
        gater.blockAddr(MultiAddr('/ip4/127.0.0.1'));
        expect(gater.interceptAddrDial(mockPeerId, MultiAddr('/ip4/127.0.0.1/tcp/4001')), isFalse);
        expect(gater.interceptAddrDial(mockPeerId, MultiAddr('/ip4/127.0.0.1/udp/4001/udx')), isFalse);
        expect(gater.interceptAddrDial(mockPeerId, MultiAddr('/ip4/127.0.0.2/tcp/4001')), isTrue);
      });

      test('a full address blocks only that address', () {
        gater.blockAddr(MultiAddr('/ip4/127.0.0.1/tcp/4001'));
        expect(gater.interceptAddrDial(mockPeerId, MultiAddr('/ip4/127.0.0.1/tcp/4001')), isFalse);
        expect(gater.interceptAddrDial(mockPeerId, MultiAddr('/ip4/127.0.0.1/tcp/4002')), isTrue);
        // A dial address can carry the peer ID.
        expect(
            gater.interceptAddrDial(mockPeerId, MultiAddr('/ip4/127.0.0.1/tcp/4001/p2p/$mockPeerId')),
            isFalse);
      });
    });

    group('interceptAccept', () {
      test('rejects a remote address whose IP is blocked', () {
        gater.blockAddr(MultiAddr('/ip4/127.0.0.1'));
        expect(gater.interceptAccept(mockConn), isFalse);
      });

      test('rejects a remote address in a blocked subnet', () {
        gater.blockSubnet('127.0.0.0/8');
        expect(gater.interceptAccept(mockConn), isFalse);
      });

      test('does not decide on the remote peer, which is not known yet', () {
        gater.blockPeer(mockConn.remotePeer);
        expect(gater.interceptAccept(mockConn), isTrue);
      });
    });

    group('Blocked peers after the handshake', () {
      test('interceptSecured and interceptUpgraded reject a blocked peer', () {
        gater.blockPeer(mockPeerId);
        expect(gater.interceptSecured(false, mockPeerId, mockConn), isFalse);
        final (allow, reason) = gater.interceptUpgraded(mockConn);
        expect(allow, isFalse);
        expect(reason?.message, equals('Peer is blocked'));
      });
    });

    test('an IPv6 subnet matches a compressed address', () {
      gater.blockSubnet('2001:db8::/32');
      expect(gater.interceptAddrDial(mockPeerId, MultiAddr('/ip6/2001:db8::1/tcp/4001')), isFalse);
      expect(gater.interceptAddrDial(mockPeerId, MultiAddr('/ip6/2001:db9::1/tcp/4001')), isTrue);
    });

    test('the deprecated limits have no effect', () {
      // ignore: deprecated_member_use_from_same_package
      gater = BasicConnGater(maxConnections: 1, maxConnectionsPerPeer: 1);
      expect(gater.interceptAccept(mockConn), isTrue);
      expect(gater.interceptAccept(mockConn), isTrue);
    });
  });
} 