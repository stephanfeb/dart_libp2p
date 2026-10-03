import 'dart:typed_data';
import 'package:pointycastle/pointycastle.dart' as pc;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/ecc/curves/secp384r1.dart';
import 'package:pointycastle/ecc/curves/secp521r1.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/ec_key_generator.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';
import 'package:pointycastle/digests/sha256.dart';
import '../../p2p/crypto/key_generator.dart' show fortunaRandom;
import '../../core/crypto/pb/crypto.pb.dart' as pb;
import 'keys.dart' as p2pkeys;

/// The default ECDSA curve used (P-256)
final ECDomainParameters ECDSACurve = ECCurve_secp256r1();

/// Exception thrown when an ECDSA key is invalid
class ECDSAKeyException implements Exception {
  final String message;
  ECDSAKeyException(this.message);
  @override
  String toString() => message;
}

// id-ecPublicKey (RFC 5480).
const _ecPublicKeyOid = '1.2.840.10045.2.1';

// The named curves go-libp2p can marshal, by OID.
final Map<String, ECDomainParameters Function()> _curvesByOid = {
  '1.2.840.10045.3.1.7': () => ECCurve_secp256r1(),
  '1.3.132.0.34': () => ECCurve_secp384r1(),
  '1.3.132.0.35': () => ECCurve_secp521r1(),
};

String _curveOid(ECDomainParameters params) {
  switch (params.domainName) {
    case 'prime256v1':
    case 'secp256r1':
      return '1.2.840.10045.3.1.7';
    case 'secp384r1':
      return '1.3.132.0.34';
    case 'secp521r1':
      return '1.3.132.0.35';
  }
  throw ECDSAKeyException('Unsupported ECDSA curve: ${params.domainName}');
}

ECDomainParameters _curveForOid(pc.ASN1Object? oid) {
  final id = oid is pc.ASN1ObjectIdentifier ? oid.objectIdentifierAsString : null;
  final curve = _curvesByOid[id];
  if (curve == null) {
    throw ECDSAKeyException('Unsupported ECDSA curve: $id');
  }
  return curve();
}

int _fieldSize(ECDomainParameters params) => (params.curve.fieldSize + 7) ~/ 8;

Uint8List _unsignedBytes(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}

BigInt _bigIntFromBytes(List<int> bytes) =>
    bytes.fold(BigInt.zero, (acc, b) => (acc << 8) | BigInt.from(b));

/// Decodes an uncompressed point and checks that it lies on the curve.
ECPoint _decodePoint(ECDomainParameters params, List<int> encoded) {
  final size = _fieldSize(params);
  if (encoded.length != 1 + 2 * size || encoded[0] != 0x04) {
    throw ECDSAKeyException('Expected an uncompressed EC point');
  }
  return _pointFromCoordinates(
    params,
    _bigIntFromBytes(encoded.sublist(1, 1 + size)),
    _bigIntFromBytes(encoded.sublist(1 + size)),
  );
}

ECPoint _pointFromCoordinates(ECDomainParameters params, BigInt x, BigInt y) {
  final point = params.curve.createPoint(x, y);
  final px = point.x!, py = point.y!;
  final onCurve = py * py == px * px * px + params.curve.a! * px + params.curve.b!;
  if (!onCurve) {
    throw ECDSAKeyException('EC point is not on the curve');
  }
  return point;
}

Uint8List _encodePoint(ECDomainParameters params, ECPoint q) {
  final size = _fieldSize(params);
  return Uint8List.fromList([
    0x04,
    ..._unsignedBytes(q.x!.toBigInteger()!, size),
    ..._unsignedBytes(q.y!.toBigInteger()!, size),
  ]);
}

ECDSASigner _signer() => ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64));

/// Implementation of ECDSA public key
class EcdsaPublicKey implements p2pkeys.PublicKey {
  final ECPublicKey _key;

  EcdsaPublicKey(this._key);

  /// Creates an EcdsaPublicKey from its DER encoding.
  ///
  /// Accepts PKIX (SubjectPublicKeyInfo), the form go-libp2p and the libp2p
  /// spec use, and the bare SEQUENCE { x, y } of P-256 coordinates that
  /// earlier versions of this library produced.
  factory EcdsaPublicKey.fromRawBytes(Uint8List bytes) {
    try {
      final parser = pc.ASN1Parser(bytes);
      final top = parser.nextObject();
      if (top is! pc.ASN1Sequence || parser.hasNext() || top.elements?.length != 2) {
        throw FormatException('Expected a SEQUENCE of two elements');
      }
      final elements = top.elements!;

      if (elements[0] is pc.ASN1Integer && elements[1] is pc.ASN1Integer) {
        final point = _pointFromCoordinates(
          ECDSACurve,
          (elements[0] as pc.ASN1Integer).integer!,
          (elements[1] as pc.ASN1Integer).integer!,
        );
        return EcdsaPublicKey(ECPublicKey(point, ECDSACurve));
      }

      final algorithm = elements[0];
      final subjectPublicKey = elements[1];
      if (algorithm is! pc.ASN1Sequence ||
          algorithm.elements?.length != 2 ||
          algorithm.elements![0] is! pc.ASN1ObjectIdentifier ||
          (algorithm.elements![0] as pc.ASN1ObjectIdentifier).objectIdentifierAsString != _ecPublicKeyOid ||
          subjectPublicKey is! pc.ASN1BitString) {
        throw FormatException('Not an EC SubjectPublicKeyInfo');
      }
      final params = _curveForOid(algorithm.elements![1]);
      final point = _decodePoint(params, subjectPublicKey.stringValues!);
      return EcdsaPublicKey(ECPublicKey(point, params));
    } catch (e) {
      throw ECDSAKeyException('Failed to parse ECDSA public key: ${e.toString()}');
    }
  }

  /// Creates an EcdsaPublicKey from its protobuf bytes
  static p2pkeys.PublicKey unmarshal(Uint8List bytes) {
    final pbKey = pb.PublicKey.fromBuffer(bytes);

    if (pbKey.type != pb.KeyType.ECDSA) {
      throw FormatException('Not an ECDSA public key');
    }
    return EcdsaPublicKey.fromRawBytes(Uint8List.fromList(pbKey.data));
  }

  @override
  pb.KeyType get type => pb.KeyType.ECDSA;

  /// The key as DER PKIX (SubjectPublicKeyInfo), as go-libp2p marshals it.
  @override
  Uint8List get raw {
    try {
      final params = _key.parameters!;
      final algorithm = pc.ASN1Sequence()
        ..add(pc.ASN1ObjectIdentifier.fromIdentifierString(_ecPublicKeyOid))
        ..add(pc.ASN1ObjectIdentifier.fromIdentifierString(_curveOid(params)));
      final spki = pc.ASN1Sequence()
        ..add(algorithm)
        ..add(pc.ASN1BitString(stringValues: _encodePoint(params, _key.Q!)));
      return Uint8List.fromList(spki.encode());
    } catch (e) {
      throw ECDSAKeyException('Failed to encode ECDSA public key: ${e.toString()}');
    }
  }

  @override
  Uint8List marshal() {
    final pbKey = pb.PublicKey(
      type: type,
      data: raw,
    );
    return pbKey.writeToBuffer();
  }

  /// Verifies an ASN.1 DER signature over the SHA-256 hash of [data], as
  /// go-libp2p signs for every curve.
  @override
  Future<bool> verify(Uint8List data, Uint8List signature) async {
    try {
      final parser = pc.ASN1Parser(signature);
      final asn1Sequence = parser.nextObject() as pc.ASN1Sequence;
      if (parser.hasNext() || asn1Sequence.elements!.length != 2) return false;

      final r = (asn1Sequence.elements![0] as pc.ASN1Integer).integer!;
      final s = (asn1Sequence.elements![1] as pc.ASN1Integer).integer!;

      final signer = _signer();
      signer.init(false, PublicKeyParameter<ECPublicKey>(_key));
      return signer.verifySignature(data, ECSignature(r, s));
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> equals(p2pkeys.PublicKey other) async {
    if (other is! EcdsaPublicKey) return false;

    final q1 = _key.Q!;
    final q2 = other._key.Q!;

    return _key.parameters!.domainName == other._key.parameters!.domainName &&
           q1.x!.toBigInteger() == q2.x!.toBigInteger() &&
           q1.y!.toBigInteger() == q2.y!.toBigInteger();
  }
}

/// Implementation of ECDSA private key
class EcdsaPrivateKey implements p2pkeys.PrivateKey {
  final ECPrivateKey _key;
  late final EcdsaPublicKey _publicKey;

  EcdsaPrivateKey(this._key, this._publicKey);

  /// Creates an EcdsaPrivateKey from its DER encoding.
  ///
  /// Accepts SEC 1 ECPrivateKey (RFC 5915), the form go-libp2p uses, and the
  /// bare SEQUENCE { d, x, y } of P-256 values that earlier versions of this
  /// library produced.
  static Future<p2pkeys.PrivateKey> fromRawBytes(Uint8List bytes) async {
    try {
      final parser = pc.ASN1Parser(bytes);
      final top = parser.nextObject();
      if (top is! pc.ASN1Sequence || parser.hasNext()) {
        throw FormatException('Expected a SEQUENCE');
      }
      final elements = top.elements!;

      if (elements.length == 3 && elements.every((e) => e is pc.ASN1Integer)) {
        final d = (elements[0] as pc.ASN1Integer).integer!;
        final point = _pointFromCoordinates(
          ECDSACurve,
          (elements[1] as pc.ASN1Integer).integer!,
          (elements[2] as pc.ASN1Integer).integer!,
        );
        return EcdsaPrivateKey(
          ECPrivateKey(d, ECDSACurve),
          EcdsaPublicKey(ECPublicKey(point, ECDSACurve)),
        );
      }

      if (elements.length < 2 ||
          elements[0] is! pc.ASN1Integer ||
          (elements[0] as pc.ASN1Integer).integer != BigInt.one ||
          elements[1] is! pc.ASN1OctetString) {
        throw FormatException('Not a SEC 1 ECPrivateKey');
      }
      pc.ASN1Object? curveOid;
      List<int>? publicPoint;
      for (final e in elements.skip(2)) {
        if (e.tag == 0xa0) {
          curveOid = pc.ASN1Parser(e.valueBytes!).nextObject();
        } else if (e.tag == 0xa1) {
          final bits = pc.ASN1Parser(e.valueBytes!).nextObject();
          if (bits is! pc.ASN1BitString) throw FormatException('Bad publicKey field');
          publicPoint = bits.stringValues;
        }
      }
      // go-libp2p always includes the curve; without it the curve is unknown.
      final params = _curveForOid(curveOid);
      final d = _bigIntFromBytes((elements[1] as pc.ASN1OctetString).octets!);
      if (d == BigInt.zero || d >= params.n) {
        throw FormatException('Private value out of range');
      }
      final q = (params.G * d)!;
      if (publicPoint != null) {
        final stored = _decodePoint(params, publicPoint);
        if (stored.x!.toBigInteger() != q.x!.toBigInteger() ||
            stored.y!.toBigInteger() != q.y!.toBigInteger()) {
          throw FormatException('Public key does not match the private value');
        }
      }
      return EcdsaPrivateKey(
        ECPrivateKey(d, params),
        EcdsaPublicKey(ECPublicKey(q, params)),
      );
    } catch (e) {
      throw ECDSAKeyException('Failed to parse ECDSA private key: ${e.toString()}');
    }
  }

  /// Creates an EcdsaPrivateKey from its protobuf bytes
  static Future<p2pkeys.PrivateKey> unmarshal(Uint8List bytes) async {
    final pbKey = pb.PrivateKey.fromBuffer(bytes);

    if (pbKey.type != pb.KeyType.ECDSA) {
      throw FormatException('Not an ECDSA private key');
    }

    return fromRawBytes(Uint8List.fromList(pbKey.data));
  }

  @override
  pb.KeyType get type => pb.KeyType.ECDSA;

  /// The key as DER SEC 1 ECPrivateKey with the curve and public key, as
  /// go-libp2p marshals it (x509.MarshalECPrivateKey).
  @override
  Uint8List get raw {
    try {
      final params = _key.parameters!;
      final curve = pc.ASN1Object(tag: 0xa0)
        ..valueBytes = pc.ASN1ObjectIdentifier.fromIdentifierString(_curveOid(params)).encode();
      final publicKey = pc.ASN1Object(tag: 0xa1)
        ..valueBytes = pc.ASN1BitString(stringValues: _encodePoint(params, _publicKey._key.Q!)).encode();
      final sec1 = pc.ASN1Sequence()
        ..add(pc.ASN1Integer(BigInt.one))
        ..add(pc.ASN1OctetString(octets: _unsignedBytes(_key.d!, (params.n.bitLength + 7) ~/ 8)))
        ..add(curve)
        ..add(publicKey);
      return Uint8List.fromList(sec1.encode());
    } catch (e) {
      throw ECDSAKeyException('Failed to encode ECDSA private key: ${e.toString()}');
    }
  }

  @override
  Uint8List marshal() {
    final pbKey = pb.PrivateKey(
      type: type,
      data: raw,
    );
    return pbKey.writeToBuffer();
  }

  /// Signs the SHA-256 hash of [data] with a deterministic nonce (RFC 6979)
  /// and returns the ASN.1 DER signature, as go-libp2p does.
  @override
  Future<Uint8List> sign(Uint8List data) async {
    try {
      final signer = _signer();
      signer.init(true, PrivateKeyParameter<ECPrivateKey>(_key));
      final signature = signer.generateSignature(data) as ECSignature;

      final asn1Sequence = pc.ASN1Sequence();
      asn1Sequence.add(pc.ASN1Integer(signature.r));
      asn1Sequence.add(pc.ASN1Integer(signature.s));

      return Uint8List.fromList(asn1Sequence.encode());
    } catch (e) {
      throw ECDSAKeyException('Failed to sign data: ${e.toString()}');
    }
  }

  @override
  p2pkeys.PublicKey get publicKey => _publicKey;

  @override
  Future<bool> equals(p2pkeys.PrivateKey other) async {
    if (other is! EcdsaPrivateKey) return false;

    // Compare public keys
    final publicKeyEquals = await _publicKey.equals(other.publicKey);
    if (!publicKeyEquals) return false;

    // Compare private values
    return _key.d == other._key.d;
  }
}

/// Generates a new ECDSA key pair on P-256, the curve go-libp2p uses.
Future<p2pkeys.KeyPair> generateEcdsaKeyPair() async {
  final generator = ECKeyGenerator()
    ..init(ParametersWithRandom(ECKeyGeneratorParameters(ECDSACurve), fortunaRandom()));
  final keyPair = generator.generateKeyPair();

  final ecdsaPublicKey = EcdsaPublicKey(keyPair.publicKey as ECPublicKey);
  final ecdsaPrivateKey = EcdsaPrivateKey(keyPair.privateKey as ECPrivateKey, ecdsaPublicKey);

  return p2pkeys.KeyPair(ecdsaPublicKey, ecdsaPrivateKey);
}
