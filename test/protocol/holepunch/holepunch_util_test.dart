import 'dart:typed_data';

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/network/network.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/util/buffered_reader.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/pb/holepunch.pb.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch/util.dart';
import 'package:test/test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';

@GenerateMocks([Host, Network, Conn, P2PStream])
import 'holepunch_util_test.mocks.dart';

void main() {
  group('Holepunch Utility Functions', () {
    group('Protocol Constants', () {
      test('protocol ID should be correct', () {
        expect(protocolId, equals('/libp2p/dcutr'));
      });

      test('service name should be correct', () {
        expect(serviceName, equals('libp2p.holepunch'));
      });

      test('timeout values should be reasonable', () {
        expect(streamTimeout, equals(Duration(minutes: 1)));
        expect(dialTimeout, equals(Duration(seconds: 5)));
        expect(maxRetries, equals(3));
        expect(maxMsgSize, equals(4 * 1024));
      });
    });

    group('Relay Address Detection', () {
      test('should detect relay addresses correctly', () {
        final relayAddr =
            MultiAddr('/ip4/127.0.0.1/tcp/4001/p2p/QmRelay/p2p-circuit');
        final directAddr = MultiAddr('/ip4/127.0.0.1/tcp/4001');

        expect(isRelayAddress(relayAddr), isTrue);
        expect(isRelayAddress(directAddr), isFalse);
      });

      test('should handle addresses without circuit protocol gracefully', () {
        final nonRelayAddr = MultiAddr('/ip4/127.0.0.1/tcp/4001');
        expect(isRelayAddress(nonRelayAddr), isFalse);
      });
    });

    group('Remove Relay Addresses', () {
      test('should filter out relay addresses from list', () {
        final addresses = [
          MultiAddr('/ip4/127.0.0.1/tcp/4001'), // direct
          MultiAddr('/ip4/127.0.0.1/tcp/4002/p2p/QmRelay/p2p-circuit'), // relay
          MultiAddr('/ip6/::1/tcp/4003'), // direct
          MultiAddr(
              '/ip4/192.168.1.100/tcp/4004/p2p/QmRelay2/p2p-circuit'), // relay
        ];

        final filteredAddresses = removeRelayAddrs(addresses);

        expect(filteredAddresses, hasLength(2));
        expect(filteredAddresses[0].toString(),
            contains('/ip4/127.0.0.1/tcp/4001'));
        expect(filteredAddresses[1].toString(), contains('/ip6/::1/tcp/4003'));
      });

      test('should return empty list when all addresses are relay addresses',
          () {
        final addresses = [
          MultiAddr('/ip4/127.0.0.1/tcp/4001/p2p/QmRelay1/p2p-circuit'),
          MultiAddr('/ip4/127.0.0.1/tcp/4002/p2p/QmRelay2/p2p-circuit'),
        ];

        final filteredAddresses = removeRelayAddrs(addresses);
        expect(filteredAddresses, isEmpty);
      });

      test('should return all addresses when none are relay addresses', () {
        final addresses = [
          MultiAddr('/ip4/127.0.0.1/tcp/4001'),
          MultiAddr('/ip6/::1/tcp/4002'),
        ];

        final filteredAddresses = removeRelayAddrs(addresses);
        expect(filteredAddresses, hasLength(2));
        expect(filteredAddresses, equals(addresses));
      });
    });

    group('Address Serialization', () {
      test('should convert addresses to bytes and back', () {
        final addresses = [
          MultiAddr('/ip4/127.0.0.1/tcp/4001'),
          MultiAddr('/ip6/::1/tcp/4002'),
        ];

        final bytes = addrsToBytes(addresses);
        final reconverted = addrsFromBytes(bytes);

        expect(reconverted, hasLength(2));
        expect(reconverted[0].toString(), equals(addresses[0].toString()));
        expect(reconverted[1].toString(), equals(addresses[1].toString()));
      });

      test('should handle empty address list', () {
        final addresses = <MultiAddr>[];
        final bytes = addrsToBytes(addresses);
        final reconverted = addrsFromBytes(bytes);

        expect(bytes, isEmpty);
        expect(reconverted, isEmpty);
      });

      test('should skip invalid bytes during deserialization', () {
        final validAddr = MultiAddr('/ip4/127.0.0.1/tcp/4001');
        final validBytes = [validAddr.toBytes()];
        final invalidBytes = [
          Uint8List.fromList([1, 2, 3])
        ]; // Invalid multiaddr bytes

        final mixedBytes = [...validBytes, ...invalidBytes];
        final reconverted = addrsFromBytes(mixedBytes);

        // Should only return valid addresses, skipping invalid ones
        expect(reconverted, hasLength(1));
        expect(reconverted[0].toString(), equals(validAddr.toString()));
      });

      test('should handle different input types for bytes', () {
        final addr = MultiAddr('/ip4/127.0.0.1/tcp/4001');
        final addrBytes = addr.toBytes();

        // Test with Uint8List
        final fromUint8List = addrsFromBytes([addrBytes]);
        expect(fromUint8List, hasLength(1));

        // Test with List<int>
        final fromListInt = addrsFromBytes([addrBytes.toList()]);
        expect(fromListInt, hasLength(1));

        // Both should produce same result
        expect(fromUint8List[0].toString(), equals(fromListInt[0].toString()));
      });
    });

    group('Delimited Message Encoding & Varint Framing', () {
      test('prepends the protobuf payload length as a uvarint', () {
        final message = HolePunch()
          ..type = HolePunch_Type.CONNECT
          ..obsAddrs.add(Uint8List.fromList([1, 2, 3, 4]));
        final payload = message.writeToBuffer();

        final encoded = encodeDelimitedMessage(message);
        final prefix = _decodeUvarint(encoded);

        expect(prefix.value, payload.length);
        expect(encoded.sublist(prefix.byteLength), payload);
      });

      test('uses a multi-byte uvarint for payloads larger than 127 bytes', () {
        final message = HolePunch()
          ..type = HolePunch_Type.CONNECT
          ..obsAddrs.add(Uint8List(256));
        final payload = message.writeToBuffer();

        final encoded = encodeDelimitedMessage(message);
        final prefix = _decodeUvarint(encoded);

        expect(payload.length, greaterThan(127));
        expect(prefix.byteLength, greaterThan(1));
        expect(prefix.value, payload.length);
        expect(encoded.sublist(prefix.byteLength), payload);
      });

      test('buffered reader reads a fragmented delimited message', () async {
        final message = HolePunch()
          ..type = HolePunch_Type.CONNECT
          ..obsAddrs.add(Uint8List(256));
        final encoded = encodeDelimitedMessage(message);
        final chunks = <Uint8List>[
          Uint8List.fromList(encoded.sublist(0, 1)),
          Uint8List.fromList(encoded.sublist(1, 17)),
          Uint8List.fromList(encoded.sublist(17)),
        ];
        var nextChunk = 0;
        final stream = MockP2PStream();
        when(stream.read()).thenAnswer(
          (_) async =>
              nextChunk < chunks.length ? chunks[nextChunk++] : Uint8List(0),
        );

        final reader = BufferedP2PStreamReader(stream);
        final payloadLength = await reader.readVarint();
        final payload = await reader.readExact(payloadLength);
        final decoded = HolePunch.fromBuffer(payload);

        expect(payloadLength, message.writeToBuffer().length);
        expect(decoded.type, HolePunch_Type.CONNECT);
        expect(decoded.obsAddrs.single, Uint8List(256));
      });
    });

    group('Direct Connection Detection', () {
      late MockHost mockHost;
      late MockNetwork mockNetwork;
      late PeerId testPeerId;

      setUp(() async {
        mockHost = MockHost();
        mockNetwork = MockNetwork();
        testPeerId = await PeerId.random();

        when(mockHost.network).thenReturn(mockNetwork);
      });

      test('should return direct connection when available', () {
        final mockDirectConn = MockConn();
        final mockRelayConn = MockConn();

        final directAddr = MultiAddr('/ip4/127.0.0.1/tcp/4001');
        final relayAddr =
            MultiAddr('/ip4/127.0.0.1/tcp/4002/p2p/QmRelay/p2p-circuit');

        when(mockDirectConn.remoteMultiaddr).thenReturn(directAddr);
        when(mockRelayConn.remoteMultiaddr).thenReturn(relayAddr);

        when(mockNetwork.connsToPeer(testPeerId))
            .thenReturn([mockRelayConn, mockDirectConn]);

        final directConn = getDirectConnection(mockHost, testPeerId);

        expect(directConn, equals(mockDirectConn));
      });

      test('should return null when only relay connections exist', () {
        final mockRelayConn1 = MockConn();
        final mockRelayConn2 = MockConn();

        final relayAddr1 =
            MultiAddr('/ip4/127.0.0.1/tcp/4001/p2p/QmRelay1/p2p-circuit');
        final relayAddr2 =
            MultiAddr('/ip4/127.0.0.1/tcp/4002/p2p/QmRelay2/p2p-circuit');

        when(mockRelayConn1.remoteMultiaddr).thenReturn(relayAddr1);
        when(mockRelayConn2.remoteMultiaddr).thenReturn(relayAddr2);

        when(mockNetwork.connsToPeer(testPeerId))
            .thenReturn([mockRelayConn1, mockRelayConn2]);

        final directConn = getDirectConnection(mockHost, testPeerId);

        expect(directConn, isNull);
      });

      test('should return null when no connections exist', () {
        when(mockNetwork.connsToPeer(testPeerId)).thenReturn([]);

        final directConn = getDirectConnection(mockHost, testPeerId);

        expect(directConn, isNull);
      });

      test('should return first direct connection when multiple exist', () {
        final mockDirectConn1 = MockConn();
        final mockDirectConn2 = MockConn();

        final directAddr1 = MultiAddr('/ip4/127.0.0.1/tcp/4001');
        final directAddr2 = MultiAddr('/ip4/127.0.0.1/tcp/4002');

        when(mockDirectConn1.remoteMultiaddr).thenReturn(directAddr1);
        when(mockDirectConn2.remoteMultiaddr).thenReturn(directAddr2);

        when(mockNetwork.connsToPeer(testPeerId))
            .thenReturn([mockDirectConn1, mockDirectConn2]);

        final directConn = getDirectConnection(mockHost, testPeerId);

        expect(directConn, equals(mockDirectConn1));
      });
    });
  });
}

({int value, int byteLength}) _decodeUvarint(Uint8List bytes) {
  var value = 0;
  var shift = 0;
  for (var index = 0; index < bytes.length; index++) {
    final byte = bytes[index];
    value |= (byte & 0x7f) << shift;
    if ((byte & 0x80) == 0) {
      return (value: value, byteLength: index + 1);
    }
    shift += 7;
  }
  throw StateError('unterminated uvarint');
}
