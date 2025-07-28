import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto; // Renamed to avoid conflict
import 'package:meta/meta.dart';

import '../../../core/crypto/keys.dart' as keys;
import '../../../core/crypto/ed25519.dart' as ed25519_keys; // Added for Ed25519PublicKey
import '../../../core/crypto/pb/crypto.pbenum.dart' as crypto_pb; // Renamed
import '../../../core/network/transport_conn.dart';
import '../../../core/peer/peer_id.dart';
import '../secured_connection.dart';
import '../security_protocol.dart';
import 'xx_pattern.dart';
import '../../../pb/noise/payload.pb.dart' as noise_pb; // Added
import 'package:logging/logging.dart'; // Added for logging

final _log = Logger('NoiseProtocol');

/// Exceptions specific to the Noise Protocol implementation
class NoiseProtocolException implements Exception {
  final String message;
  final Object? cause;

  NoiseProtocolException(this.message, [this.cause]);

  @override
  String toString() => 'NoiseProtocolException: $message${cause != null ? ' ($cause)' : ''}';
}

/// Implementation of the Noise Protocol (XX pattern) for libp2p
class NoiseSecurity implements SecurityProtocol {
  static const String protocolIdForState = '/noise'; // Made public for SecuredConnection
  static const _protocolString = protocolIdForState;

  final keys.KeyPair _identityKey;
  bool _isDisposed = false;

  NoiseSecurity._(this._identityKey);

  /// Creates a new NoiseXXProtocol instance
  static Future<NoiseSecurity> create(keys.KeyPair identityKey) async {
    // Verify Ed25519 compatibility
    final pubKey = identityKey.publicKey;
    if (pubKey.type != crypto_pb.KeyType.Ed25519) { // Changed keyType to type
      throw NoiseProtocolException('Identity key must be Ed25519 compatible (got ${pubKey.type})');
    }
    return NoiseSecurity._(identityKey);
  }

  // Helper to read a length-prefixed message from a SecuredConnection
  Future<Uint8List> _readEncryptedPayload(SecuredConnection conn) async {
    final lengthBytes = await conn.read(2); // Assuming SecuredConnection.read handles underlying raw reads
    if (lengthBytes.length < 2) throw NoiseProtocolException("Failed to read payload length");
    final length = (lengthBytes[0] << 8) | lengthBytes[1];
    return conn.read(length); // SecuredConnection.read will decrypt
  }

  // Helper to write a length-prefixed message to a SecuredConnection
  Future<void> _writeEncryptedPayload(SecuredConnection conn, Uint8List payload) async {
    final lengthBytes = Uint8List(2);
    lengthBytes[0] = payload.length >> 8;
    lengthBytes[1] = payload.length & 0xFF;
    // SecuredConnection.write will encrypt
    // It expects the raw payload, and it handles its own length prefixing for the *encrypted* data.
    // So, we send the raw payload here. The SecuredConnection's write method will then
    // encrypt it and prepend its *own* length prefix for the encrypted blob.
    // This means the _readEncryptedPayload needs to be careful.
    // For the libp2p handshake payload, it's simpler: the payload itself is length-prefixed *before* encryption.
    // The SecuredConnection then encrypts this (length-prefix + payload) and prepends *another* length prefix.

    // Correct approach for libp2p handshake payload:
    // 1. Create payload.
    // 2. Prepend length of this payload.
    // 3. Pass this (length + payload) to SecuredConnection.write().
    final prefixedPayload = Uint8List(2 + payload.length);
    prefixedPayload[0] = payload.length >> 8;
    prefixedPayload[1] = payload.length & 0xFF;
    prefixedPayload.setAll(2, payload);
    await conn.write(prefixedPayload);
  }

  Future<Uint8List> _readLibp2pHandshakePayload(SecuredConnection conn) async {
    // SecuredConnection.read handles decryption and its own framing.
    // We expect it to return the decrypted (length-prefix + actual_payload).
    final decryptedOuterFrame = await conn.read(); // Read one full message decrypted by SecuredConnection
    if (decryptedOuterFrame.length < 2) throw NoiseProtocolException("Payload too short after decryption");
    final actualPayloadLength = (decryptedOuterFrame[0] << 8) | decryptedOuterFrame[1];
    if (decryptedOuterFrame.length != 2 + actualPayloadLength) {
      throw NoiseProtocolException("Decrypted payload length mismatch: expected ${2 + actualPayloadLength}, got ${decryptedOuterFrame.length}");
    }
    return decryptedOuterFrame.sublist(2);
  }


  @override
  Future<SecuredConnection> secureOutbound(TransportConn connection) async {
    if (_isDisposed) throw NoiseProtocolException('Protocol has been disposed');

    try {
      final staticKey = await crypto.X25519().newKeyPair();
      final pattern = await NoiseXXPattern.create(true, staticKey);

      await connection.write(await pattern.writeMessage(Uint8List(0))); // -> e
      await pattern.readMessage(await connection.read(80)); // <- e, ee, s, es
      await connection.write(await pattern.writeMessage(Uint8List(0))); // -> s, se

      // Noise XX handshake complete, session keys derived.
      // Now, exchange libp2p handshake payload over the encrypted channel.

      // ADDED LOGGING
      _log.finer('NoiseSecurity.secureOutbound: Handshake complete. Pattern keys:');
      _log.finer('  - pattern.sendKey.hashCode: ${pattern.sendKey.hashCode}, pattern.sendKey.bytes: ${await pattern.sendKey.extractBytes()}');
      _log.finer('  - pattern.recvKey.hashCode: ${pattern.recvKey.hashCode}, pattern.recvKey.bytes: ${await pattern.recvKey.extractBytes()}');

      // Create a temporary SecuredConnection for exchanging the NoiseHandshakePayload
      final tempSecuredConn = SecuredConnection(
        connection,
        pattern.sendKey,
        pattern.recvKey,
        securityProtocolId: _protocolString, // Temporary, won't have peer details yet
      );

      // 1. Prepare and send initiator's payload
      final initiatorPayload = noise_pb.NoiseHandshakePayload();
      initiatorPayload.identityKey = await _identityKey.publicKey.marshal();
      // Initiator signs responder's static X25519 key
      if (pattern.remoteStaticKey == null) throw NoiseProtocolException("Responder's remote static key is null during outbound secure");
      final signature = await _identityKey.privateKey.sign(pattern.remoteStaticKey!); 
      initiatorPayload.identitySig = signature;
      
      await _writeEncryptedPayload(tempSecuredConn, initiatorPayload.writeToBuffer());

      // 2. Receive and process responder's payload
      final responderEncryptedPayloadBytes = await _readLibp2pHandshakePayload(tempSecuredConn);
      final responderPayload = noise_pb.NoiseHandshakePayload.fromBuffer(responderEncryptedPayloadBytes);

      if (!responderPayload.hasIdentityKey()) throw NoiseProtocolException("Responder payload missing identity key");
      // Assuming Ed25519 key as per Noise spec for libp2p identity
      final remoteLibp2pPublicKey = ed25519_keys.Ed25519PublicKey.unmarshal(Uint8List.fromList(responderPayload.identityKey)); 
      
      if (!responderPayload.hasIdentitySig()) throw NoiseProtocolException("Responder payload missing signature");
      // Responder's signature is over initiator's static X25519 key
      final initiatorStaticNoiseKey = await pattern.getStaticPublicKey(); 
      
      final sigVerified = await remoteLibp2pPublicKey.verify(
          initiatorStaticNoiseKey, Uint8List.fromList(responderPayload.identitySig));
      if (!sigVerified) throw NoiseProtocolException("Failed to verify responder's signature");

      final remotePeerId = await PeerId.fromPublicKey(remoteLibp2pPublicKey);

      // ADDED LOGGING
      _log.finer('NoiseSecurity.secureOutbound: Libp2p handshake payload processed. Finalizing SecuredConnection with pattern keys:');
      _log.finer('  - pattern.sendKey.hashCode: ${pattern.sendKey.hashCode}, pattern.sendKey.bytes: ${await pattern.sendKey.extractBytes()}');
      _log.finer('  - pattern.recvKey.hashCode: ${pattern.recvKey.hashCode}, pattern.recvKey.bytes: ${await pattern.recvKey.extractBytes()}');
      
      return SecuredConnection(
        connection,
        pattern.sendKey,
        pattern.recvKey,
        establishedRemotePeer: remotePeerId,
        establishedRemotePublicKey: remoteLibp2pPublicKey,
        securityProtocolId: _protocolString,
      );
    } catch (e) {
      await connection.close();
      if (e is NoiseProtocolException) rethrow;
      throw NoiseProtocolException('Failed to secure outbound connection', e);
    }
  }

  @override
  Future<SecuredConnection> secureInbound(TransportConn connection) async {
    if (_isDisposed) throw NoiseProtocolException('Protocol has been disposed');

    try {
      final staticKey = await crypto.X25519().newKeyPair();
      final pattern = await NoiseXXPattern.create(false, staticKey);

      await pattern.readMessage(await connection.read(32)); // <- e
      await connection.write(await pattern.writeMessage(Uint8List(0))); // -> e, ee, s, es
      await pattern.readMessage(await connection.read(48)); // <- s, se

      // Noise XX handshake complete. Exchange libp2p handshake payload.
      // ADDED LOGGING
      _log.finer('NoiseSecurity.secureInbound: Handshake complete. Pattern keys:');
      _log.finer('  - pattern.sendKey.hashCode: ${pattern.sendKey.hashCode}, pattern.sendKey.bytes: ${await pattern.sendKey.extractBytes()}');
      _log.finer('  - pattern.recvKey.hashCode: ${pattern.recvKey.hashCode}, pattern.recvKey.bytes: ${await pattern.recvKey.extractBytes()}');
      
      final tempSecuredConn = SecuredConnection(
        connection,
        pattern.sendKey, // Responder's send is initiator's recv
        pattern.recvKey, // Responder's recv is initiator's send
        securityProtocolId: _protocolString,
      );

      // 1. Receive and process initiator's payload
      final initiatorEncryptedPayloadBytes = await _readLibp2pHandshakePayload(tempSecuredConn);
      final initiatorPayload = noise_pb.NoiseHandshakePayload.fromBuffer(initiatorEncryptedPayloadBytes);

      if (!initiatorPayload.hasIdentityKey()) throw NoiseProtocolException("Initiator payload missing identity key");
      // Assuming Ed25519 key
      final remoteLibp2pPublicKey = ed25519_keys.Ed25519PublicKey.unmarshal(Uint8List.fromList(initiatorPayload.identityKey));

      if (!initiatorPayload.hasIdentitySig()) throw NoiseProtocolException("Initiator payload missing signature");
      // Initiator's signature is over responder's static X25519 key
      final responderStaticNoiseKey = await pattern.getStaticPublicKey();
      
      final sigVerified = await remoteLibp2pPublicKey.verify(
          responderStaticNoiseKey, Uint8List.fromList(initiatorPayload.identitySig));
      if (!sigVerified) throw NoiseProtocolException("Failed to verify initiator's signature");
      
      // 2. Prepare and send responder's payload
      final responderPayload = noise_pb.NoiseHandshakePayload();
      responderPayload.identityKey = await _identityKey.publicKey.marshal();
      // Responder signs initiator's X25519 static key (which is pattern.remoteStaticKey from responder's PoV)
      if (pattern.remoteStaticKey == null) throw NoiseProtocolException("Initiator's remote static key is null during inbound secure");
      final signature = await _identityKey.privateKey.sign(pattern.remoteStaticKey!);
      responderPayload.identitySig = signature;

      await _writeEncryptedPayload(tempSecuredConn, responderPayload.writeToBuffer());

      final remotePeerId = await PeerId.fromPublicKey(remoteLibp2pPublicKey);

      // ADDED LOGGING
      _log.finer('NoiseSecurity.secureInbound: Libp2p handshake payload processed. Finalizing SecuredConnection with pattern keys:');
      _log.finer('  - pattern.sendKey.hashCode: ${pattern.sendKey.hashCode}, pattern.sendKey.bytes: ${await pattern.sendKey.extractBytes()}');
      _log.finer('  - pattern.recvKey.hashCode: ${pattern.recvKey.hashCode}, pattern.recvKey.bytes: ${await pattern.recvKey.extractBytes()}');

      return SecuredConnection(
        connection,
        pattern.sendKey,
        pattern.recvKey,
        establishedRemotePeer: remotePeerId,
        establishedRemotePublicKey: remoteLibp2pPublicKey,
        securityProtocolId: _protocolString,
      );
    } catch (e) {
      await connection.close();
      if (e is NoiseProtocolException) rethrow;
      throw NoiseProtocolException('Failed to secure inbound connection', e);
    }
  }

  /// Signs a static key using the identity key
  // Future<Uint8List> signStaticKey(Uint8List staticKey) async {
  //   final message = 'noise-libp2p-static-key:${String.fromCharCodes(staticKey)}';
  //   final signature = await Ed25519().sign(
  //     message.codeUnits,
  //     keyPair: _identityKey,
  //   );
  //   return Uint8List.fromList(signature.bytes);
  // }

  Future<void> dispose() async {
    _isDisposed = true;
  }

  @override
  String get protocolId => _protocolString;

  // Testing support
  @visibleForTesting
  static Future<NoiseSecurity> createForTesting({
    required keys.KeyPair identityKey,
  }) async {
    return NoiseSecurity._(identityKey);
  }
}
