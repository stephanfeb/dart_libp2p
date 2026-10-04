import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/crypto/pb/crypto.pb.dart' as pb;
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:test/test.dart';

// Vectors produced by go-libp2p v0.49 (core/crypto, core/peer) from the
// RFC 8032 test 1 seed. The signed message is
// "noise-libp2p-static-key:hello".
const _seed = '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60';
const _goPrivateKey = '080112409d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
    'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a';
const _goPublicKey = '08011220d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a';
const _goPeerId = '12D3KooWQK1wnefoLrcVHbbnf5tLzbopUd3K3bFAoJpA7YJgL5pV';
const _message = '6e6f6973652d6c69627032702d7374617469632d6b65793a68656c6c6f';
const _goSignature = '50cfd3ca8a40595cd7db7899dfefc2511e4d444af55670a8174c75adf241055f'
    '152b0c7c3cbe340d918666316bf92aae8037e6fc26cd375f9d1a46085da2dd0e';

Uint8List _hex(String s) => Uint8List.fromList(hex.decode(s));

void main() {
  group('Ed25519', () {
    test('Generate key pair', () async {
      final keyPair = await generateEd25519KeyPair();

      expect(keyPair.publicKey, isNotNull);
      expect(keyPair.privateKey, isNotNull);
      expect(keyPair.publicKey.type.value, equals(1)); // Ed25519 type value
      expect(keyPair.privateKey.type.value, equals(1)); // Ed25519 type value
    });

    test('Sign and verify', () async {
      final keyPair = await generateEd25519KeyPair();
      final message = Uint8List.fromList([1, 2, 3, 4, 5]);

      final signature = await keyPair.privateKey.sign(message);
      expect(signature, isNotNull);
      expect(signature.length, equals(64)); // Ed25519 signature is 64 bytes

      final verified = await keyPair.publicKey.verify(message, signature);
      expect(verified, isTrue);

      // Verify with wrong message
      final wrongMessage = Uint8List.fromList([5, 4, 3, 2, 1]);
      final wrongVerified = await keyPair.publicKey.verify(wrongMessage, signature);
      expect(wrongVerified, isFalse);
    });

    test('Marshal and unmarshal public key', () async {
      final keyPair = await generateEd25519KeyPair();
      final publicKey = keyPair.publicKey;

      final marshaled = publicKey.marshal();
      expect(marshaled, isNotNull);

      final unmarshaled = Ed25519PublicKey.unmarshal(marshaled);
      expect(unmarshaled, isNotNull);
      expect(unmarshaled.type.value, equals(publicKey.type.value));

      final equal = await publicKey.equals(unmarshaled);
      expect(equal, isTrue);
    });

    test('a marshalled private key restores the same key', () async {
      final keyPair = await generateEd25519KeyPair();

      final restored = await Ed25519PrivateKey.unmarshal(keyPair.privateKey.marshal());

      expect(hex.encode(restored.publicKey.raw), hex.encode(keyPair.publicKey.raw));
      final message = Uint8List.fromList([1, 2, 3, 4, 5]);
      expect(await keyPair.publicKey.verify(message, await restored.sign(message)), isTrue);
    });

    test('raw gives the seed of a generated key, and fromRawBytes restores it', () async {
      final keyPair = await generateEd25519KeyPair();
      final seed = keyPair.privateKey.raw;
      expect(seed.length, 32);

      final restored = await Ed25519PrivateKey.fromRawBytes(seed);
      expect(hex.encode(restored.publicKey.raw), hex.encode(keyPair.publicKey.raw));
    });

    test('fromRawBytes rejects a public key that does not belong to the seed', () async {
      final other = await generateEd25519KeyPair();
      final bytes = Uint8List.fromList([..._hex(_seed), ...other.publicKey.raw]);
      expect(() => Ed25519PrivateKey.fromRawBytes(bytes), throwsFormatException);
    });

    test('a key written by the old marshal bug fails with an explanation', () async {
      // Before 4.1.3, marshal() wrote 32 zero bytes in place of the seed.
      final keyPair = await generateEd25519KeyPair();
      final broken = pb.PrivateKey(
        type: pb.KeyType.Ed25519,
        data: [...List.filled(32, 0), ...keyPair.publicKey.raw],
      ).writeToBuffer();
      expect(
        () => Ed25519PrivateKey.unmarshal(broken),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('cannot be recovered'))),
      );
    });

    group('go-libp2p interop', () {
      test('marshals a key as go-libp2p does', () async {
        final keyPair = await generateEd25519KeyPairFromSeed(_hex(_seed));
        expect(hex.encode(keyPair.privateKey.marshal()), _goPrivateKey);
        expect(hex.encode(keyPair.publicKey.marshal()), _goPublicKey);
        expect(PeerId.fromPublicKey(keyPair.publicKey).toBase58(), _goPeerId);
      });

      test('unmarshals a key that go-libp2p marshalled', () async {
        final privateKey = await Ed25519PrivateKey.unmarshal(_hex(_goPrivateKey));
        expect(hex.encode(privateKey.raw), _seed);
        expect(PeerId.fromPublicKey(privateKey.publicKey).toBase58(), _goPeerId);
        expect(hex.encode(await privateKey.sign(_hex(_message))), _goSignature);
      });

      test('accepts go-libp2p Raw() bytes and the legacy 96-byte form', () async {
        final goRaw = _hex(_goPrivateKey).sublist(4); // strip the protobuf header
        expect(goRaw.length, 64);
        final fromRaw = await Ed25519PrivateKey.fromRawBytes(goRaw);
        expect(PeerId.fromPublicKey(fromRaw.publicKey).toBase58(), _goPeerId);

        final legacy = Uint8List.fromList([...goRaw, ...goRaw.sublist(32)]);
        final fromLegacy = await Ed25519PrivateKey.fromRawBytes(legacy);
        expect(PeerId.fromPublicKey(fromLegacy.publicKey).toBase58(), _goPeerId);
      });

      test('verifies a go-libp2p signature', () async {
        final publicKey = Ed25519PublicKey.unmarshal(_hex(_goPublicKey));
        expect(await publicKey.verify(_hex(_message), _hex(_goSignature)), isTrue);
      });
    });

    test('Public key equality', () async {
      final keyPair1 = await generateEd25519KeyPair();
      final keyPair2 = await generateEd25519KeyPair();

      // Same key should be equal
      final equal1 = await keyPair1.publicKey.equals(keyPair1.publicKey);
      expect(equal1, isTrue);

      // Different keys should not be equal
      final equal2 = await keyPair1.publicKey.equals(keyPair2.publicKey);
      expect(equal2, isFalse);
    });

    test('Private key equality', () async {
      final keyPair1 = await generateEd25519KeyPair();
      final keyPair2 = await generateEd25519KeyPair();

      // Same key should be equal
      final equal1 = await keyPair1.privateKey.equals(keyPair1.privateKey);
      expect(equal1, isTrue);

      // Different keys should not be equal
      final equal2 = await keyPair1.privateKey.equals(keyPair2.privateKey);
      expect(equal2, isFalse);
    });

    test('Public key from raw bytes', () async {
      final keyPair = await generateEd25519KeyPair();
      final publicKey = keyPair.publicKey;
      final rawBytes = publicKey.raw;

      final recreatedKey = Ed25519PublicKey.fromRawBytes(rawBytes);
      expect(recreatedKey, isNotNull);

      final equal = await publicKey.equals(recreatedKey);
      expect(equal, isTrue);
    });

    test('Get public key from private key', () async {
      final keyPair = await generateEd25519KeyPair();
      final privateKey = keyPair.privateKey;
      final publicKey = privateKey.publicKey;

      expect(publicKey, isNotNull);

      final equal = await publicKey.equals(keyPair.publicKey);
      expect(equal, isTrue);
    });
  });
}
