import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';

import 'handshake_state.dart';

/// Represents the immutable state of a Noise handshake
class HandshakeState {
  final Uint8List chainKey;
  final Uint8List handshakeHash;
  final XXHandshakeState state;
  final SecretKey? sendKey;
  final SecretKey? recvKey;
  final Uint8List? remoteEphemeralKey;
  final Uint8List? remoteStaticKey;

  const HandshakeState({
    required this.chainKey,
    required this.handshakeHash,
    required this.state,
    this.sendKey,
    this.recvKey,
    this.remoteEphemeralKey,
    this.remoteStaticKey,
  });

  HandshakeState copyWith({
    Uint8List? chainKey,
    Uint8List? handshakeHash,
    XXHandshakeState? state,
    SecretKey? sendKey,
    SecretKey? recvKey,
    Uint8List? remoteEphemeralKey,
    Uint8List? remoteStaticKey,
  }) {
    return HandshakeState(
      chainKey: chainKey ?? this.chainKey,
      handshakeHash: handshakeHash ?? this.handshakeHash,
      state: state ?? this.state,
      sendKey: sendKey ?? this.sendKey,
      recvKey: recvKey ?? this.recvKey,
      remoteEphemeralKey: remoteEphemeralKey ?? this.remoteEphemeralKey,
      remoteStaticKey: remoteStaticKey ?? this.remoteStaticKey,
    );
  }
}

/// Message type for length validation
enum NoiseMessageType {
  ephemeralKey,
  secondMessage,
  finalMessage,
}

/// Implementation of the Noise XX pattern for libp2p
/// 
/// The XX pattern:
///   -> e                    // Initial: Initiator sends ephemeral key
///   <- e, ee, s, es        // Response: Responder sends ephemeral key, performs ee+es
///   -> s, se               // Final: Initiator sends static key, performs se
class NoiseXXPattern {
  static const PROTOCOL_NAME = 'Noise_XX_25519_ChaChaPoly_SHA256';
  static const KEY_LEN = 32;
  static const MAC_LEN = 16;
  
  // Core components
  final bool _isInitiator;
  final SimpleKeyPair _staticKeys;
  final SimpleKeyPair _ephemeralKeys;
  
  // Current handshake state
  HandshakeState _state;
  
  NoiseXXPattern._(
    this._isInitiator,
    this._staticKeys,
    this._ephemeralKeys,
    this._state,
  );

  /// Creates a new NoiseXXPattern instance
  static Future<NoiseXXPattern> create(bool isInitiator, SimpleKeyPair staticKeys) async {
    // Generate ephemeral keys
    final ephemeralKeys = await X25519().newKeyPair();
    
    // Initialize symmetric state
    final protocolName = utf8.encode(PROTOCOL_NAME);
    _validateProtocolName(protocolName);
    
    final initialHash = await Sha256().hash(protocolName);
    final tempKey = SecretKey(Uint8List.fromList(initialHash.bytes));
    
    final state = HandshakeState(
      chainKey: Uint8List.fromList(initialHash.bytes),
      handshakeHash: Uint8List.fromList(initialHash.bytes),
      state: XXHandshakeState.initial,
      sendKey: tempKey,
      recvKey: tempKey,
    );
    
    return NoiseXXPattern._(isInitiator, staticKeys, ephemeralKeys, state);
  }

  /// Process an incoming handshake message
  Future<void> readMessage(Uint8List message) async {
    if (_state.state == XXHandshakeState.error) {
      throw StateError('Cannot read message in error state');
    }
    
    try {
      _validateReadState();
      
      _state = await switch (_state.state) {
        XXHandshakeState.initial => _processInitialMessage(message),
        XXHandshakeState.sentE => _processSecondMessage(message),
        XXHandshakeState.sentEES => _processFinalMessage(message),
        _ => throw StateError('Cannot read message in state: ${_state.state}'),
      };
    } catch (e) {
      // Only set error state for non-validation errors
      if (e is! StateError) {
        _state = _state.copyWith(state: XXHandshakeState.error);
      }
      rethrow;
    }
  }

  /// Generate the next handshake message
  Future<Uint8List> writeMessage(List<int> payload) async {
    if (_state.state == XXHandshakeState.error) {
      throw StateError('Cannot write message in error state');
    }
    
    try {
      _validateWriteState();
      
      final result = await switch (_state.state) {
        XXHandshakeState.initial => _writeInitialMessage(),
        XXHandshakeState.sentE => _writeSecondMessage(),
        XXHandshakeState.sentEES => _writeFinalMessage(payload),
        _ => throw StateError('Cannot write message in state: ${_state.state}'),
      };
      
      _state = result.$2;  // Update state
      return result.$1;    // Return message
    } catch (e) {
      // Only set error state for non-validation errors
      if (e is! StateError) {
        _state = _state.copyWith(state: XXHandshakeState.error);
      }
      rethrow;
    }
  }

  /// Validates that we can read in the current state
  void _validateReadState() {
    if (_state.state == XXHandshakeState.complete) {
      throw StateError('Handshake already complete');
    }

    if (_isInitiator && _state.state == XXHandshakeState.initial) {
      throw StateError('Initiator cannot read first message');
    }
  }

  /// Validates that we can write in the current state
  void _validateWriteState() {
    if (_state.state == XXHandshakeState.complete) {
      throw StateError('Handshake already complete');
    }

    if (!_isInitiator && _state.state == XXHandshakeState.initial) {
      throw StateError('Responder cannot write first message');
    }

    if (_isInitiator && _state.state == XXHandshakeState.sentE) {
      throw StateError('Initiator cannot write second message');
    }

    if (!_isInitiator && _state.state == XXHandshakeState.sentE) {
      if (_state.remoteEphemeralKey == null) {
        throw StateError('Cannot write second message without remote ephemeral key');
      }
    }

    if (_isInitiator && _state.state == XXHandshakeState.sentEES) {
      if (_state.remoteStaticKey == null) {
        throw StateError('Cannot write final message without remote static key');
      }
    }
  }

  /// Process the initial message (e)
  Future<HandshakeState> _processInitialMessage(Uint8List message) async {
    _validateMessageLength(message, KEY_LEN, NoiseMessageType.ephemeralKey);
    
    var state = _state;
    
    // Extract remote ephemeral key
    final remoteEphemeral = message.sublist(0, KEY_LEN);
    await _validatePublicKey(remoteEphemeral);
    
    // Mix hash
    final newHash = await _mixHash(state.handshakeHash, remoteEphemeral);
    state = state.copyWith(
      handshakeHash: newHash,
      remoteEphemeralKey: remoteEphemeral,
    );
    
    return state.copyWith(
      state: XXHandshakeState.sentE,
    );
  }

  /// Process the second message (e, ee, s, es)
  Future<HandshakeState> _processSecondMessage(Uint8List message) async {
    // Check state first
    if (!_isInitiator && _state.state == XXHandshakeState.sentE) {
      throw StateError('Responder cannot receive second message');
    }
    
    final minLen = KEY_LEN + KEY_LEN + MAC_LEN;
    _validateMessageLength(message, minLen, NoiseMessageType.secondMessage);
    
    var state = _state;
    var newChainKey = state.chainKey;
    
    // Extract and validate remote ephemeral key
    final remoteEphemeral = message.sublist(0, KEY_LEN);
    await _validatePublicKey(remoteEphemeral);
    
    // Mix hash
    var newHash = await _mixHash(state.handshakeHash, remoteEphemeral);
    state = state.copyWith(
      handshakeHash: newHash,
      remoteEphemeralKey: remoteEphemeral,
    );
    
    // ee
    newChainKey = await _dh(
      _ephemeralKeys,
      remoteEphemeral,
      state.chainKey,
    );
    state = state.copyWith(chainKey: newChainKey);
    
    // Decrypt s
    final encryptedStatic = message.sublist(KEY_LEN, KEY_LEN + KEY_LEN + MAC_LEN);
    if (state.recvKey == null) {
      throw StateError('Receive key is null during static key decryption - this should never happen');
    }
    final recvKeyFinal = state.recvKey as SecretKey;
    final remoteStatic = await _decryptWithAd(
      encryptedStatic,
      state.handshakeHash,
      recvKeyFinal,
    );
    await _validatePublicKey(remoteStatic);
    
    // Mix hash
    newHash = await _mixHash(state.handshakeHash, encryptedStatic);
    state = state.copyWith(
      handshakeHash: newHash,
      remoteStaticKey: remoteStatic,
    );
    
    // es - initiator uses ephemeral with responder's static
    if (_isInitiator) {
      newChainKey = await _dh(
        _ephemeralKeys,
        remoteStatic,
        state.chainKey,
      );
      state = state.copyWith(chainKey: newChainKey);
    }
    
    return state.copyWith(
      state: XXHandshakeState.sentEES,
    );
  }

  /// Process the final message (s, se)
  Future<HandshakeState> _processFinalMessage(Uint8List message) async {
    final minLen = KEY_LEN + MAC_LEN;
    _validateMessageLength(message, minLen, NoiseMessageType.finalMessage);
    
    var state = _state;
    
    // Decrypt s
    final encryptedStatic = message.sublist(0, KEY_LEN + MAC_LEN);
    if (state.recvKey == null) {
      throw StateError('Receive key is null during static key decryption - this should never happen');
    }
    final recvKeyFinal = state.recvKey as SecretKey;
    final remoteStatic = await _decryptWithAd(
      encryptedStatic,
      state.handshakeHash,
      recvKeyFinal,
    );
    await _validatePublicKey(remoteStatic);
    
    // Mix hash with encrypted static key
    var newHash = await _mixHash(state.handshakeHash, encryptedStatic);
    state = state.copyWith(
      handshakeHash: newHash,
      remoteStaticKey: remoteStatic,
    );
    
    // se - responder uses ephemeral with initiator's static
    if (state.remoteEphemeralKey == null) {
      throw StateError('Remote ephemeral key is null during se operation - this should never happen');
    }
    final remoteEphemeral = state.remoteEphemeralKey as List<int>;
    var newChainKey = await _dh(
      _isInitiator ? _staticKeys : _ephemeralKeys,
      _isInitiator ? remoteEphemeral : remoteStatic,
      state.chainKey,
    );
    state = state.copyWith(chainKey: newChainKey);
    
    // Process payload if present
    if (message.length > minLen) {
      final encryptedPayload = message.sublist(minLen);
      if (state.recvKey == null) {
        throw StateError('Receive key is null during payload decryption - this should never happen');
      }
      final recvKeyFinal = state.recvKey as SecretKey;
      final payload = await _decryptWithAd(
        encryptedPayload,
        state.handshakeHash,
        recvKeyFinal,
      );
      newHash = await _mixHash(state.handshakeHash, encryptedPayload);
      state = state.copyWith(handshakeHash: newHash);
    }
    
    // Derive final keys
    final (sendKey, recvKey) = await _deriveKeys(state.chainKey);
    
    return state.copyWith(
      sendKey: sendKey,
      recvKey: recvKey,
      state: XXHandshakeState.complete,
    );
  }

  /// Write the initial message (e)
  Future<(Uint8List message, HandshakeState state)> _writeInitialMessage() async {
    // Get our ephemeral public key
    final ephemeralPub = await _ephemeralKeys.extractPublicKey();
    final ephemeralBytes = await ephemeralPub.bytes;
    
    // Mix hash
    final newHash = await _mixHash(_state.handshakeHash, ephemeralBytes);
    
    return (
      Uint8List.fromList(ephemeralBytes),
      _state.copyWith(
        handshakeHash: newHash,
        state: XXHandshakeState.sentE,
      ),
    );
  }

  /// Write the second message (e, ee, s, es)
  Future<(Uint8List message, HandshakeState state)> _writeSecondMessage() async {
    var state = _state;
    var newChainKey = state.chainKey;
    final messageBytes = <int>[];
    
    // Validate we have the required keys
    if (state.remoteEphemeralKey == null) {
      throw StateError('Cannot write second message without remote ephemeral key');
    }
    
    // e
    final ephemeralPub = await _ephemeralKeys.extractPublicKey();
    final ephemeralBytes = await ephemeralPub.bytes;
    messageBytes.addAll(ephemeralBytes);
    
    // Mix hash
    var newHash = await _mixHash(state.handshakeHash, ephemeralBytes);
    state = state.copyWith(handshakeHash: newHash);
    
    // ee
    newChainKey = await _dh(
      _ephemeralKeys,
      state.remoteEphemeralKey as List<int>,
      state.chainKey,
    );
    state = state.copyWith(chainKey: newChainKey);
    
    // s
    final staticPub = await _staticKeys.extractPublicKey();
    final staticBytes = await staticPub.bytes;
    if (state.sendKey == null) {
      throw StateError('Send key is null during static key encryption - this should never happen');
    }
    final sendKeyFinal = state.sendKey as SecretKey;
    final encryptedStatic = await _encryptWithAd(
      staticBytes,
      state.handshakeHash,
      sendKeyFinal,
    );
    messageBytes.addAll(encryptedStatic);
    
    // Mix hash
    newHash = await _mixHash(state.handshakeHash, encryptedStatic);
    state = state.copyWith(handshakeHash: newHash);
    
    // es - responder uses static with initiator's ephemeral
    if (!_isInitiator) {
      newChainKey = await _dh(
        _staticKeys,
        state.remoteEphemeralKey as List<int>,
        state.chainKey,
      );
      state = state.copyWith(chainKey: newChainKey);
    }
    
    return (
      Uint8List.fromList(messageBytes),
      state.copyWith(state: XXHandshakeState.sentEES),
    );
  }

  /// Write the final message (s, se)
  Future<(Uint8List message, HandshakeState state)> _writeFinalMessage(List<int> payload) async {
    var state = _state;
    final messageBytes = <int>[];
    
    // s - encrypt and send static key
    final staticPub = await _staticKeys.extractPublicKey();
    final staticBytes = await staticPub.bytes;
    if (state.sendKey == null) {
      throw StateError('Send key is null during static key encryption - this should never happen');
    }
    final sendKeyFinal = state.sendKey as SecretKey;
    final encryptedStatic = await _encryptWithAd(
      staticBytes,
      state.handshakeHash,
      sendKeyFinal,
    );
    messageBytes.addAll(encryptedStatic);
    
    // Mix hash with encrypted static key
    var newHash = await _mixHash(state.handshakeHash, encryptedStatic);
    state = state.copyWith(handshakeHash: newHash);
    
    // se - initiator uses static with responder's ephemeral
    if (state.remoteEphemeralKey == null) {
      throw StateError('Remote ephemeral key is null during se operation - this should never happen');
    }
    final remoteEphemeral = state.remoteEphemeralKey as List<int>;
    var newChainKey = await _dh(
      _isInitiator ? _staticKeys : _ephemeralKeys,
      _isInitiator ? remoteEphemeral : state.remoteStaticKey!,
      state.chainKey,
    );
    state = state.copyWith(chainKey: newChainKey);
    
    // Encrypt payload if present
    if (payload.isNotEmpty) {
      if (state.sendKey == null) {
        throw StateError('Send key is null during payload encryption - this should never happen');
      }
      final encryptedPayload = await _encryptWithAd(
        payload,
        state.handshakeHash,
        sendKeyFinal,
      );
      messageBytes.addAll(encryptedPayload);
      newHash = await _mixHash(state.handshakeHash, encryptedPayload);
      state = state.copyWith(handshakeHash: newHash);
    }
    
    // Derive final keys
    final (sendKey, recvKey) = await _deriveKeys(state.chainKey);
    
    return (
      Uint8List.fromList(messageBytes),
      state.copyWith(
        sendKey: sendKey,
        recvKey: recvKey,
        state: XXHandshakeState.complete,
      ),
    );
  }

  // Cryptographic operations

  /// Validates a public key
  Future<void> _validatePublicKey(List<int> publicKey) async {
    if (publicKey.length != KEY_LEN) {
      throw StateError('Invalid public key length: ${publicKey.length}');
    }
    // Additional validation could be added here
  }

  /// Validates protocol name
  static void _validateProtocolName(List<int> protocolName) {
    if (protocolName.length != utf8.encode(PROTOCOL_NAME).length) {
      throw StateError('Invalid protocol name length');
    }
    if (!protocolName.every((b) => b >= 32 && b <= 126)) {
      throw StateError('Protocol name contains non-printable characters');
    }
    if (PROTOCOL_NAME != 'Noise_XX_25519_ChaChaPoly_SHA256') {
      throw StateError('Invalid protocol name');
    }
  }

  /// Validates message length
  void _validateMessageLength(Uint8List message, int minLength, NoiseMessageType type) {
    switch (type) {
      case NoiseMessageType.ephemeralKey:
        if (message.length < KEY_LEN) {
          throw StateError('Message too short to contain ephemeral key: ${message.length} < $KEY_LEN');
        }
        break;
      case NoiseMessageType.secondMessage:
        // First check for ephemeral key
        if (message.length < KEY_LEN) {
          throw StateError('Message too short to contain ephemeral key: ${message.length} < $KEY_LEN');
        }
        // Then check if we have enough space for the encrypted static key
        if (message.length < KEY_LEN + KEY_LEN) {
          throw StateError('Message too short to contain encrypted static key: ${message.length} < ${KEY_LEN + KEY_LEN}');
        }
        // Finally check for full message length including MAC
        if (message.length < minLength) {
          throw StateError('Second message too short: ${message.length} < $minLength (needs 32 bytes ephemeral key + 32 bytes encrypted static key + 16 bytes MAC)');
        }
        break;
      case NoiseMessageType.finalMessage:
        if (message.length < minLength) {
          throw StateError('Final message too short: ${message.length} < $minLength (needs 32 bytes encrypted static key + 16 bytes MAC)');
        }
        break;
    }
  }

  /// Performs Diffie-Hellman and mixes the result into the chain key
  Future<Uint8List> _dh(
    SimpleKeyPair privateKey,
    List<int> publicKey,
    List<int> currentChainKey,
  ) async {
    final algorithm = X25519();
    final shared = await algorithm.sharedSecretKey(
      keyPair: privateKey,
      remotePublicKey: SimplePublicKey(publicKey, type: KeyPairType.x25519),
    );
    final sharedBytes = await shared.extractBytes();
    
    final hmac = Hmac.sha256();
    final result = await hmac.calculateMac(
      sharedBytes,
      secretKey: SecretKey(currentChainKey),
    );
    return Uint8List.fromList(result.bytes);
  }

  /// Mixes data into the handshake hash
  Future<Uint8List> _mixHash(List<int> currentHash, List<int> data) async {
    final hash = await Sha256().hash([...currentHash, ...data]);
    return Uint8List.fromList(hash.bytes);
  }

  /// Encrypts data with additional data
  Future<Uint8List> _encryptWithAd(
    List<int> plaintext,
    List<int> ad,
    SecretKey key,
  ) async {
    final algorithm = Chacha20.poly1305Aead();
    final nonce = List<int>.filled(algorithm.nonceLength, 0);
    final secretBox = await algorithm.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: ad,
    );
    return Uint8List.fromList([
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
  }

  /// Decrypts data with additional data
  Future<Uint8List> _decryptWithAd(
    List<int> data,
    List<int> ad,
    SecretKey key,
  ) async {
    if (data.length < MAC_LEN) {
      throw StateError('Data too short to contain MAC');
    }
    
    final algorithm = Chacha20.poly1305Aead();
    final nonce = List<int>.filled(algorithm.nonceLength, 0);
    final cipherText = data.sublist(0, data.length - MAC_LEN);
    final mac = data.sublist(data.length - MAC_LEN);
    
    return Uint8List.fromList(await algorithm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: key,
      aad: ad,
    ));
  }

  /// Derives the final cipher keys
  Future<(SecretKey sendKey, SecretKey recvKey)> _deriveKeys(List<int> chainKey) async {
    final hmac = Hmac.sha256();
    final k1 = await hmac.calculateMac([0x01], secretKey: SecretKey(chainKey));
    final k2 = await hmac.calculateMac([0x02], secretKey: SecretKey(chainKey));

    final k1Key = SecretKey(Uint8List.fromList(k1.bytes));
    final k2Key = SecretKey(Uint8List.fromList(k2.bytes));

    // According to Noise spec:
    // For one-way patterns:
    // - The initiator sends with k1 and receives with k2
    // - The responder sends with k2 and receives with k1
    return _isInitiator ? (k1Key, k2Key) : (k2Key, k1Key);
  }

  // Public API

  bool get isComplete => _state.state == XXHandshakeState.complete;
  XXHandshakeState get state => _state.state;

  Future<Uint8List> getStaticPublicKey() async {
    final pubKey = await _staticKeys.extractPublicKey();
    return Uint8List.fromList(await pubKey.bytes);
  }
  
  Uint8List get remoteStaticKey {
    final key = _state.remoteStaticKey;
    if (key == null) {
      throw StateError('Remote static key not available');
    }
    return key;
  }

  SecretKey get sendKey {
    final key = _state.sendKey;
    if (key == null) {
      throw StateError('Send key not initialized');
    }
    return key;
  }

  SecretKey get recvKey {
    final key = _state.recvKey;
    if (key == null) {
      throw StateError('Receive key not initialized');
    }
    return key;
  }

  // Testing support
  @visibleForTesting
  static Future<NoiseXXPattern> createForTesting(
    bool isInitiator,
    SimpleKeyPair staticKeys,
    SimpleKeyPair ephemeralKeys,
  ) async {
    final protocolName = utf8.encode(PROTOCOL_NAME);
    _validateProtocolName(protocolName);
    
    final initialHash = await Sha256().hash(protocolName);
    final tempKey = SecretKey(Uint8List.fromList(initialHash.bytes));
    
    final state = HandshakeState(
      chainKey: Uint8List.fromList(initialHash.bytes),
      handshakeHash: Uint8List.fromList(initialHash.bytes),
      state: XXHandshakeState.initial,
      sendKey: tempKey,
      recvKey: tempKey,
    );
    
    return NoiseXXPattern._(isInitiator, staticKeys, ephemeralKeys, state);
  }

  @visibleForTesting
  Uint8List get debugChainKey => _state.chainKey;
  
  @visibleForTesting
  Uint8List get debugHandshakeHash => _state.handshakeHash;
  
  @visibleForTesting
  SimpleKeyPair get debugEphemeralKeys => _ephemeralKeys;
  
  @visibleForTesting
  Uint8List? get debugRemoteStaticKey => _state.remoteStaticKey;
}
