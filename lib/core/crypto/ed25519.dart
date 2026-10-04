import 'dart:typed_data';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/crypto/pb/crypto.pb.dart' as pb;

/// Implementation of Ed25519 public key
class Ed25519PublicKey implements PublicKey {
  final crypto.SimplePublicKey _key;

  Ed25519PublicKey(this._key);

  /// Creates an Ed25519PublicKey from raw bytes
  factory Ed25519PublicKey.fromRawBytes(Uint8List bytes) {
    if (bytes.length != 32) {
      throw FormatException('Ed25519 public key must be 32 bytes');
    }

    final publicKey = crypto.SimplePublicKey(
      bytes,
      type: crypto.KeyPairType.ed25519,
    );

    return Ed25519PublicKey(publicKey);
  }

  /// Creates an Ed25519PublicKey from its protobuf bytes
  static PublicKey unmarshal(Uint8List bytes) {
    final pbKey = pb.PublicKey.fromBuffer(bytes);

    if (pbKey.type != pb.KeyType.Ed25519) {
      throw FormatException('Not an Ed25519 public key');
    }
    return Ed25519PublicKey.fromRawBytes(Uint8List.fromList(pbKey.data));
  }

  @override
  pb.KeyType get type => pb.KeyType.Ed25519;

  @override
  Uint8List get raw {
    return Uint8List.fromList(_key.bytes);
  }

  @override
  Uint8List marshal() {
    final pbKey = pb.PublicKey(
      type: type,
      data: raw,
    );
    return pbKey.writeToBuffer();
  }

  @override
  Future<bool> verify(Uint8List data, Uint8List signature) async {
    final algorithm = crypto.Ed25519();
    final sig = crypto.Signature(signature, publicKey: _key);
    return algorithm.verify(data, signature: sig);
  }

  @override
  Future<bool> equals(PublicKey other) async {
    if (other is! Ed25519PublicKey) return false;

    // Compare the raw bytes of the keys
    final thisBytes = raw;
    final otherBytes = other.raw;

    if (thisBytes.length != otherBytes.length) return false;

    for (var i = 0; i < thisBytes.length; i++) {
      if (thisBytes[i] != otherBytes[i]) return false;
    }

    return true;
  }
}

/// Implementation of Ed25519 private key.
///
/// The key keeps its 32-byte seed, from which the signing key is derived.
/// [marshal] writes the seed followed by the public key (64 bytes), the
/// format that go-libp2p writes and reads.
class Ed25519PrivateKey implements PrivateKey {
  final crypto.SimpleKeyPair _keyPair;
  late final Ed25519PublicKey _publicKey;
  Uint8List? _privateKeyBytes;

  /// Private constructor that requires a public key
  Ed25519PrivateKey._(this._keyPair, this._publicKey, [this._privateKeyBytes]);

  /// Creates a private key from a `cryptography` key pair.
  ///
  /// The seed is read from [keyPair] when [privateKeyBytes] is not given.
  static Future<Ed25519PrivateKey> create(crypto.SimpleKeyPair keyPair, [Uint8List? privateKeyBytes]) async {
    final publicKeyObj = await keyPair.extractPublicKey();
    final publicKey = Ed25519PublicKey(publicKeyObj);
    final seed = privateKeyBytes ?? Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
    return Ed25519PrivateKey._(keyPair, publicKey, seed);
  }

  /// Creates an Ed25519PrivateKey with a public key.
  ///
  /// Without [_privateKeyBytes] (the 32-byte seed) the key can sign, but
  /// [raw] and [marshal] throw. Prefer [create].
  Ed25519PrivateKey.withPublicKey(this._keyPair, this._publicKey, [this._privateKeyBytes]);

  /// Creates an Ed25519PrivateKey from raw bytes: the 32-byte seed, the seed
  /// followed by the public key (64 bytes, as go-libp2p's `Raw()` returns
  /// it), or go-libp2p's legacy 96-byte form, which repeats the public key.
  ///
  /// Throws a [FormatException] when the public key in [bytes] does not
  /// belong to the seed.
  static Future<Ed25519PrivateKey> fromRawBytes(Uint8List bytes) async {
    if (bytes.length != 32 && bytes.length != 64 && bytes.length != 96) {
      throw FormatException('Ed25519 private key must be 32, 64 or 96 bytes, got ${bytes.length}');
    }

    final seed = Uint8List.fromList(bytes.sublist(0, 32));
    final keyPair = await crypto.Ed25519().newKeyPairFromSeed(seed);
    final key = await create(keyPair, seed);

    if (bytes.length > 32) {
      final storedPublicKey = bytes.sublist(32, 64);
      if (!_bytesEqual(storedPublicKey, key.publicKey.raw)) {
        final zeroSeed = seed.every((b) => b == 0);
        throw FormatException(zeroSeed
            ? 'Ed25519 private key has an all-zero seed: it was written by '
                'Ed25519PrivateKey.marshal() before dart_libp2p 4.1.3, which '
                'did not save the private key. The key cannot be recovered.'
            : 'Ed25519 private key: the public key does not match the seed');
      }
      if (bytes.length == 96 && !_bytesEqual(bytes.sublist(64), storedPublicKey)) {
        throw FormatException('Ed25519 private key: the two public keys in the 96-byte form differ');
      }
    }
    return key;
  }

  /// Creates an Ed25519PrivateKey from its protobuf bytes, as [marshal] and
  /// go-libp2p's `crypto.MarshalPrivateKey` write them.
  static Future<PrivateKey> unmarshal(Uint8List bytes) async {
    final pbKey = pb.PrivateKey.fromBuffer(bytes);

    if (pbKey.type != pb.KeyType.Ed25519) {
      throw FormatException('Not an Ed25519 private key');
    }

    return fromRawBytes(Uint8List.fromList(pbKey.data));
  }

  bool _publicKeyInitialized() {
    try {
      // This will throw if _publicKey is not initialized
      _publicKey.toString();
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  pb.KeyType get type => pb.KeyType.Ed25519;

  /// The 32-byte seed. (go-libp2p's `Raw()` returns the seed followed by
  /// the public key; [fromRawBytes] accepts both.)
  @override
  Uint8List get raw {
    if (_privateKeyBytes != null) {
      return Uint8List.fromList(_privateKeyBytes!);
    }
    throw StateError(
      'This Ed25519PrivateKey was built with withPublicKey() and no seed, so '
      'its private key bytes are unknown. Use Ed25519PrivateKey.create().'
    );
  }

  /// The protobuf form: type Ed25519 and data = seed || public key
  /// (64 bytes), as go-libp2p writes it.
  @override
  Uint8List marshal() {
    final publicKeyBytes = publicKey.raw;
    final seed = raw;

    final combined = Uint8List(seed.length + publicKeyBytes.length);
    combined.setRange(0, seed.length, seed);
    combined.setRange(seed.length, combined.length, publicKeyBytes);

    final pbKey = pb.PrivateKey(
      type: type,
      data: combined,
    );

    return pbKey.writeToBuffer();
  }

  @override
  Future<Uint8List> sign(Uint8List data) async {

    final wand = await crypto.Ed25519().newSignatureWandFromKeyPair(this._keyPair);

    final sig = await wand.sign(data);

    return Uint8List.fromList(sig.bytes);

  }

  @override
  PublicKey get publicKey {
    if (!_publicKeyInitialized()) {
      throw StateError('Public key not initialized. Call _initPublicKey() first.');
    }
    return _publicKey;
  }

  @override
  Future<bool> equals(PrivateKey other) async {
    if (other is! Ed25519PrivateKey) return false;

    // Try to compare the raw bytes if available
    try {
      final thisBytes = raw;
      final otherBytes = other.raw;
      return _bytesEqual(thisBytes, otherBytes);
    } catch (e) {
      // Fall back to comparing public keys
      return publicKey.equals(other.publicKey);
    }
  }

  /// Generate a new Ed25519 key pair
  static Future<KeyPair> generateKeyPairFromSeed(Uint8List seed) async {
    final algorithm = crypto.Ed25519();
    final keyPair = await algorithm.newKeyPairFromSeed(seed);
    final privateKey = await Ed25519PrivateKey.create(keyPair, Uint8List.fromList(seed));

    return KeyPair(privateKey.publicKey, privateKey);
  }

  /// Generate a new Ed25519 key pair
  static Future<KeyPair> generateKeyPair() async {
    final algorithm = crypto.Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final privateKey = await Ed25519PrivateKey.create(keyPair);

    return KeyPair(privateKey.publicKey, privateKey);
  }
}

/// Helper function to compare two byte arrays
bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;

  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }

  return true;
}

Future<KeyPair> generateEd25519KeyPairFromSeed(Uint8List privateKeySeed) async{
  return Ed25519PrivateKey.generateKeyPairFromSeed(privateKeySeed);
}

/// Generate a new Ed25519 key pair
Future<KeyPair> generateEd25519KeyPair() async {
  return Ed25519PrivateKey.generateKeyPair();
}
