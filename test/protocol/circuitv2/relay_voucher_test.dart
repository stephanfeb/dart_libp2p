import 'package:dart_libp2p/core/network/network.dart' show Reachability;
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/record/envelope.dart';
import 'package:dart_libp2p/p2p/host/eventbus/basic.dart' as p2p_event_bus;
import 'package:dart_libp2p/p2p/protocol/circuitv2/client/reservation.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/pb/voucher.pb.dart';
import 'package:dart_libp2p/p2p/protocol/circuitv2/proto.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_mgr;
import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

import '../../real_net_stack.dart';

void main() {
  group('Circuit relay v2 reservation voucher', () {
    late Libp2pNode relay;
    late Libp2pNode client;

    setUp(() async {
      final udx = UDX();
      final resourceManager = NullResourceManager();
      final connManager = p2p_conn_mgr.ConnectionManager();
      relay = await createLibp2pNode(
        udxInstance: udx,
        resourceManager: resourceManager,
        connManager: connManager,
        hostEventBus: p2p_event_bus.BasicBus(),
        enableRelay: true,
        forceReachability: Reachability.public,
      );
      client = await createLibp2pNode(
        udxInstance: udx,
        resourceManager: resourceManager,
        connManager: connManager,
        hostEventBus: p2p_event_bus.BasicBus(),
        enableAutoRelay: true,
      );
      await Future.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      await client.host.close();
      await relay.host.close();
    });

    test('is an envelope signed by the relay, as go-libp2p requires', () async {
      await client.host.connect(AddrInfo(relay.peerId, relay.listenAddrs));

      final reservation = await client.host.circuitV2Client!.reserve(relay.peerId);

      expect(reservation.voucher, isNotNull);
      final envelope = unmarshalEnvelopeFromProto(reservation.voucher!);
      await envelope.validate(CircuitV2Protocol.recordDomain);
      expect(envelope.payloadType, CircuitV2Protocol.recordCodec);
      expect(envelope.publicKey.raw, relay.keyPair.publicKey.raw);

      final voucher = ReservationVoucher.fromBuffer(envelope.rawPayload);
      expect(voucher.relay, relay.peerId.toBytes());
      expect(voucher.peer, client.peerId.toBytes());
    });
  });
}
