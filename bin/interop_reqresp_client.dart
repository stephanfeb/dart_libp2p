/// Interop request/response client for Go↔Dart testing.
/// Usage: dart run bin/interop_reqresp_client.dart <multiaddr-with-p2p> [count]
///
/// Sends length-prefixed requests the way a Ricochet client does: open a
/// stream, write a 4-byte big-endian length and the body, read the
/// length-prefixed response, close the stream. The first requests start
/// together, before any connection exists, as an app does at startup; the
/// rest follow one at a time. Exits 0 when every response matches.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/context.dart' as core_context;
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart' as p2p_conn_manager;
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';

const String reqRespProtocol = '/interop/reqresp/1.0.0';

Future<void> _request(Host host, PeerId server, int n) async {
  final stream = await host
      .newStream(server, [reqRespProtocol], core_context.Context())
      .timeout(const Duration(seconds: 15));
  final body = utf8.encode(jsonEncode({'operation': 'GET_INFO', 'n': n, 'pad': 'x' * 120}));
  final frame = Uint8List(4 + body.length);
  ByteData.view(frame.buffer).setUint32(0, body.length);
  frame.setRange(4, frame.length, body);
  await stream.write(frame);

  final lengthBytes = await stream.read(4).timeout(const Duration(seconds: 10));
  if (lengthBytes.length < 4) {
    throw StateError('request $n: short length (${lengthBytes.length} bytes)');
  }
  final length = ByteData.sublistView(lengthBytes).getUint32(0);
  final response = BytesBuilder();
  while (response.length < length) {
    final chunk = await stream.read(length - response.length).timeout(const Duration(seconds: 10));
    if (chunk.isEmpty) break;
    response.add(chunk);
  }
  await stream.close();
  final got = utf8.decode(response.takeBytes());
  if (got != 'ok $n') {
    throw StateError('request $n: got "$got"');
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln('Usage: dart run bin/interop_reqresp_client.dart <multiaddr/p2p/peerid> [count]');
    exit(1);
  }
  final targetMa = MultiAddr(arguments[0]);
  final count = arguments.length > 1 ? int.parse(arguments[1]) : 30;
  final server = PeerId.fromString(targetMa.valueForProtocol(Protocols.p2p.name)!);

  final keyPair = await crypto_ed25519.generateEd25519KeyPair();
  final connManager = p2p_conn_manager.ConnectionManager();
  final host = await p2p_config.Libp2p.new_([
    p2p_config.Libp2p.identity(keyPair),
    p2p_config.Libp2p.connManager(connManager),
    p2p_config.Libp2p.transport(UDXTransport(connManager: connManager)),
    p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
  ]);
  await host.start();
  await host.peerStore.addrBook
      .addAddrs(server, [targetMa.decapsulate(Protocols.p2p.name)!], const Duration(hours: 1));

  var failures = 0;
  Future<void> run(int n) => _request(host, server, n).catchError((Object e) {
        failures++;
        stderr.writeln('FAIL: $e');
      });

  // Startup burst: several requests at once, before any connection exists.
  await Future.wait([for (var n = 0; n < 5; n++) run(n)]);
  for (var n = 5; n < count; n++) {
    await run(n);
  }

  await host.close();
  if (failures > 0) {
    stderr.writeln('FAIL: $failures of $count requests failed');
    exit(1);
  }
  stdout.writeln('OK $count requests');
  exit(0);
}
