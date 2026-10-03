import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dart_libp2p/core/crypto/ecdsa.dart';
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/crypto/pb/crypto.pb.dart' as pb;
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:pointycastle/pointycastle.dart' as pc;
import 'package:test/test.dart';

// Vectors produced by go-libp2p v0.49 (core/crypto, core/peer). The message
// is "noise-libp2p-static-key:hello".
const _message = '6e6f6973652d6c69627032702d7374617469632d6b65793a68656c6c6f';

const _vectors = {
  'P-256': (
    publicKey:
        '0803125b3059301306072a8648ce3d020106082a8648ce3d030107034200045a'
        'eb4301c696080333039169ce896ee644373b3924a000a968ec3af9507be376e8'
        'c9815be6c588a7d1feafa00a801e4d338cb4976aaae604ec75535bdc5b1bd8',
    privateKey:
        '08031279307702010104205a8aecbf5318e44ca5e175687153c2f23c33e2deb1'
        'eb8e7475aa06c35d830f43a00a06082a8648ce3d030107a144034200045aeb43'
        '01c696080333039169ce896ee644373b3924a000a968ec3af9507be376e8c981'
        '5be6c588a7d1feafa00a801e4d338cb4976aaae604ec75535bdc5b1bd8',
    peerId: 'QmZu9py8NZfiSnsrrB1nYNMZ2WZp4Vr5z37QLftYGzVJiY',
    signature:
        '30440220073327d029b0ca814587fb09f9cdac24c7cee8f402e3e2f64626b7d4'
        '7f4de8ca02200427d783c872828e464c5aab2047804f993358d92be35def4e64'
        '893b1b11f657',
  ),
  'P-384': (
    publicKey:
        '080312783076301006072a8648ce3d020106052b81040022036200041725a0b8'
        '49d136aebc32884cf072cf0c48e7f4f6da753a9f78fe1b1a69295b4885e485bc'
        '6d38a3bc3989363a465ce80f1d75d5b0bb46c5b9a691280fd03409c8ad03675b'
        '6f1fa4163a19e18d00f6a31635441bb585a303dcee29a62374bf4629',
    privateKey:
        '080312a7013081a40201010430cfa9d79c811269790474b8c8dbc1ad1f1b66f0'
        '78854eae78b05c377670f1e158c139a7f618a4b75c516cecf46401e58aa00706'
        '052b81040022a164036200041725a0b849d136aebc32884cf072cf0c48e7f4f6'
        'da753a9f78fe1b1a69295b4885e485bc6d38a3bc3989363a465ce80f1d75d5b0'
        'bb46c5b9a691280fd03409c8ad03675b6f1fa4163a19e18d00f6a31635441bb5'
        '85a303dcee29a62374bf4629',
    peerId: 'QmcDmwZw6pmb6QJEjDA9e3ADz3dw7GCy4jEmuhEETnSdsr',
    signature:
        '306402301e8f01bf40a1ea862af76d91ff8aaa461015508a5777234d8ef1a741'
        '41215d04b8b3565e0f6909b2cb1615d283dbc450023060292bbd2cd3b221587a'
        'ce86332c4145bf5ff5be0bf7fa08bd73f218221da8fa2ab2c08280fdb5a49efa'
        'e371db7c34bd',
  ),
};

Uint8List _hex(String s) => Uint8List.fromList(hex.decode(s));

void main() {
  group('ECDSA interop with go-libp2p', () {
    for (final MapEntry(key: curve, value: v) in _vectors.entries) {
      group(curve, () {
        final goKey = publicKeyFromProto(pb.PublicKey.fromBuffer(_hex(v.publicKey)));

        test('unmarshals a Go public key', () {
          expect(goKey, isA<EcdsaPublicKey>());
        });

        test('verifies a Go signature', () async {
          expect(await goKey.verify(_hex(_message), _hex(v.signature)), isTrue);
        });

        test('rejects a Go signature over other data', () async {
          expect(await goKey.verify(Uint8List.fromList([1, 2, 3]), _hex(v.signature)), isFalse);
        });

        test('marshals back to the same bytes as Go', () {
          expect(hex.encode(goKey.marshal()), v.publicKey);
        });

        test('derives the same peer ID as Go', () {
          expect(PeerId.fromPublicKey(goKey).toBase58(), v.peerId);
        });

        test('unmarshals a Go private key and marshals it back', () async {
          final privateKey = await EcdsaPrivateKey.unmarshal(_hex(v.privateKey));
          expect(hex.encode(privateKey.marshal()), v.privateKey);
          expect(await privateKey.publicKey.equals(goKey), isTrue);
        });

        test('signs so that the Go public key verifies', () async {
          final privateKey = await EcdsaPrivateKey.unmarshal(_hex(v.privateKey));
          final signature = await privateKey.sign(_hex(_message));
          expect(await goKey.verify(_hex(_message), signature), isTrue);
        });
      });
    }
  });

  group('ECDSA keys', () {
    test('generates P-256 keys that round-trip and sign', () async {
      final keyPair = await generateEcdsaKeyPair();
      final data = Uint8List.fromList('hello'.codeUnits);

      final publicKey = EcdsaPublicKey.unmarshal(keyPair.publicKey.marshal());
      final privateKey = await EcdsaPrivateKey.unmarshal(keyPair.privateKey.marshal());

      expect(await publicKey.equals(keyPair.publicKey), isTrue);
      expect(await privateKey.equals(keyPair.privateKey), isTrue);
      expect(await publicKey.verify(data, await privateKey.sign(data)), isTrue);
      expect(PeerId.fromPublicKey(keyPair.publicKey).toBase58(), startsWith('Qm'));
    });

    test('still reads the legacy SEQUENCE { x, y } and { d, x, y } forms', () async {
      final keyPair = await generateEcdsaKeyPair();
      final spki = pc.ASN1Parser(keyPair.publicKey.raw).nextObject() as pc.ASN1Sequence;
      final point = (spki.elements![1] as pc.ASN1BitString).stringValues!;
      final x = _toBigInt(point.sublist(1, 33));
      final y = _toBigInt(point.sublist(33));
      final sec1 = pc.ASN1Parser(keyPair.privateKey.raw).nextObject() as pc.ASN1Sequence;
      final d = _toBigInt((sec1.elements![1] as pc.ASN1OctetString).octets!);

      final legacyPublic = (pc.ASN1Sequence()
            ..add(pc.ASN1Integer(x))
            ..add(pc.ASN1Integer(y)))
          .encode();
      final legacyPrivate = (pc.ASN1Sequence()
            ..add(pc.ASN1Integer(d))
            ..add(pc.ASN1Integer(x))
            ..add(pc.ASN1Integer(y)))
          .encode();

      final publicKey = EcdsaPublicKey.fromRawBytes(legacyPublic);
      final privateKey = await EcdsaPrivateKey.fromRawBytes(legacyPrivate);
      expect(await publicKey.equals(keyPair.publicKey), isTrue);
      expect(await privateKey.equals(keyPair.privateKey), isTrue);
      expect(hex.encode(publicKey.raw), hex.encode(keyPair.publicKey.raw));
    });

    test('rejects a point that is not on the curve', () {
      final goKey = _hex(_vectors['P-256']!.publicKey);
      final spki = pb.PublicKey.fromBuffer(goKey).data;
      final bad = Uint8List.fromList(spki)..[spki.length - 1] ^= 0x01;
      expect(() => EcdsaPublicKey.fromRawBytes(bad), throwsA(isA<ECDSAKeyException>()));
    });
  });
}

BigInt _toBigInt(List<int> bytes) =>
    bytes.fold(BigInt.zero, (acc, b) => (acc << 8) | BigInt.from(b));
