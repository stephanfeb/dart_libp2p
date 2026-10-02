import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/crypto/pb/crypto.pb.dart' as pb;
import 'package:dart_libp2p/core/crypto/rsa.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:test/test.dart';

// Vectors produced by go-libp2p (core/crypto, core/peer) for a 2048-bit key.
const _goPublicKey =
      '080012a60230820122300d06092a864886f70d01010105000382010f00308201'
      '0a0282010100b90267c7520005d26c45eb4c5715a7c5b62ebb56c3b63f3a1b14'
      '5c58488f765999fb9ecc9d520f06d50d328dc8328686bd45d6d7a1118d73eada'
      '035006219e043247696840a1fae3f7bc2755f3c201a6ff3a25cd409e82e1c9ae'
      '3f41f449080442f2e8912c6373d3d9e9a551a59e3aa013b6cb7a74f44fcdc05c'
      '1b8527334373f80d75dc32f27da607be2f3a1769948b6ef7e53744ae0ac5480b'
      '2259be440e717aa2ce56364fb0c2a46632ffa41f139c88d6d8475f81ad57512b'
      '66681099850803f1dbe47e31bd42c416927d1feda122749ba2483d1aba2d6fd0'
      '37a4fb6c2bd5adcf31d626c97a456a1449d53133cde4f1e035fa254ee116fb1e'
      '4d3a8774bb490203010001';
const _goPeerId = 'QmVWLBMNLwJF4HYqCv9ZpXgXbRwAomiP86wcDarv27En3t';
const _goMessage = '6e6f6973652d6c69627032702d7374617469632d6b65793a68656c6c6f'; // "noise-libp2p-static-key:hello"
const _goSignature =
      '87a94d8f8e3e319f7413c9d1a91a3c4c6196ff60be3fcbf91ed189be893662c6'
      'fd1caab4d2f10e47b9b5455b3484a4bb231e40856de9578bf69f62331e6692e8'
      '5933e01493076ee9b82f9c1d7d4600d3a5dbc90efbf0828052fe422b4df0d2f3'
      'f39663a7cc90b8529f2385ced351a8291eba1273a39f9108bc1fe02966c39af3'
      '28a6a62829744662281e286cda64c8536681054681f6f76303ce164f6a47b619'
      'e9a9dd4670dc896a00d6a53012456c74c660a2a44c4c80a6b5920dc00360fb0c'
      '663c00fc3d0b42d6c9923fa5d296cda6e8d5e88d97d32c82d6d54a26883ff4c4'
      '76713f794c3b1000551e3cf77ac2b6cfb3b303b2559db1bef88e4e5cd78ce3e8';

Uint8List _hex(String s) => Uint8List.fromList(hex.decode(s));

void main() {
  group('RSA interop with go-libp2p', () {
    final goKey = publicKeyFromProto(pb.PublicKey.fromBuffer(_hex(_goPublicKey)));

    test('unmarshals a Go public key', () {
      expect(goKey, isA<RsaPublicKey>());
    });

    test('verifies a Go signature', () async {
      expect(await goKey.verify(_hex(_goMessage), _hex(_goSignature)), isTrue);
    });

    test('marshals back to the same bytes as Go', () {
      expect(hex.encode(goKey.marshal()), _goPublicKey);
    });

    test('derives the same peer ID as Go', () {
      expect(PeerId.fromPublicKey(goKey).toBase58(), _goPeerId);
    });

    test('derives SHA2-256 peer IDs for local RSA keys', () async {
      final keyPair = await generateRsaKeyPair();
      final id = PeerId.fromPublicKey(keyPair.publicKey).toBase58();

      expect(id, startsWith('Qm'));
      expect(id, hasLength(46));
      expect(PeerId.decode(id).toBase58(), id);
    });
  });
}
