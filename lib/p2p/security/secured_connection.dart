import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:collection';

import 'package:cryptography/cryptography.dart' hide PublicKey;
import 'package:dart_libp2p/core/peer/peer_id.dart';
import '../../core/multiaddr.dart';
import '../../core/network/conn.dart';
import '../../core/network/transport_conn.dart';
import '../../core/crypto/keys.dart';
import '../../core/network/context.dart';
import '../../core/network/stream.dart';
import '../../core/network/rcmgr.dart' show ConnScope; // Import ConnScope
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:logging/logging.dart'; // Added for logging
import 'package:convert/convert.dart';

final _log = Logger('SecuredConnection');

/// Optimized buffer for handling large payload transfers
class _DecryptedDataBuffer {
  final Queue<Uint8List> _chunks = Queue<Uint8List>();
  int _totalLength = 0;
  
  void add(Uint8List chunk) {
    if (chunk.isNotEmpty) {
      _chunks.add(chunk);
      _totalLength += chunk.length;
    }
  }
  
  bool get isEmpty => _chunks.isEmpty;
  int get length => _totalLength;
  
  Uint8List takeBytes(int count) {
    if (count <= 0 || _totalLength == 0) {
      return Uint8List(0);
    }
    
    final actualCount = count > _totalLength ? _totalLength : count;
    final result = Uint8List(actualCount);
    var resultOffset = 0;
    
    while (resultOffset < actualCount && _chunks.isNotEmpty) {
      final chunk = _chunks.first;
      final needed = actualCount - resultOffset;
      
      if (chunk.length <= needed) {
        // Take entire chunk
        result.setRange(resultOffset, resultOffset + chunk.length, chunk);
        resultOffset += chunk.length;
        _totalLength -= chunk.length;
        _chunks.removeFirst();
      } else {
        // Take partial chunk
        result.setRange(resultOffset, resultOffset + needed, chunk);
        final remaining = chunk.sublist(needed);
        _chunks.removeFirst();
        _chunks.addFirst(remaining);
        _totalLength -= needed;
        resultOffset += needed;
      }
    }
    
    return result;
  }
  
  Uint8List takeAll() {
    if (_totalLength == 0) {
      return Uint8List(0);
    }
    
    final result = Uint8List(_totalLength);
    var offset = 0;
    
    while (_chunks.isNotEmpty) {
      final chunk = _chunks.removeFirst();
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    
    _totalLength = 0;
    return result;
  }
  
  void clear() {
    _chunks.clear();
    _totalLength = 0;
  }
}

/// A connection secured by a security protocol
class SecuredConnection implements TransportConn {
  final TransportConn _connection;
  final crypto.SecretKey _encryptionKey;
  final crypto.SecretKey _decryptionKey;
  final PeerId? establishedRemotePeer;
  final PublicKey? establishedRemotePublicKey;
  final String securityProtocolId; // Added to resolve circular dependency
  int _sendNonce = 0;
  int _recvNonce = 0;
  final _DecryptedDataBuffer _decryptedBuffer = _DecryptedDataBuffer(); // Optimized buffer

  SecuredConnection(
      this._connection,
      this._encryptionKey,
      this._decryptionKey, {
        this.establishedRemotePeer,
        this.establishedRemotePublicKey,
        required this.securityProtocolId, // Make it required
      }) {
    // ADDED LOGGING
    _log.finer('SecuredConnection Constructor: Peer ${establishedRemotePeer?.toString() ?? 'unknown'}');
    _log.finer('  - _encryptionKey.hashCode: ${_encryptionKey.hashCode}');
    _encryptionKey.extractBytes().then((bytes) => _log.finer('  - _encryptionKey.bytes: $bytes'));
    _log.finer('  - _decryptionKey.hashCode: ${_decryptionKey.hashCode}');
    _decryptionKey.extractBytes().then((bytes) => _log.finer('  - _decryptionKey.bytes: $bytes'));

  }

  Uint8List _getNonce(int counter) {
    final nonce = Uint8List(12);  // ChaCha20-Poly1305 uses 12-byte nonces
    nonce[0] = (counter >> 56) & 0xFF;
    nonce[1] = (counter >> 48) & 0xFF;
    nonce[2] = (counter >> 40) & 0xFF;
    nonce[3] = (counter >> 32) & 0xFF;
    nonce[4] = (counter >> 24) & 0xFF;
    nonce[5] = (counter >> 16) & 0xFF;
    nonce[6] = (counter >> 8) & 0xFF;
    nonce[7] = counter & 0xFF;
    return nonce;
  }

  @override
  Future<void> close() => _connection.close();

  @override
  Future<Uint8List> read([int? length]) async {
    _log.finer('SecuredConnection.read: Called with length: $length, _decryptedBuffer.length: ${_decryptedBuffer.length}'); // ADDED
    if (length == 0) {
      _log.finer('SecuredConnection.read: Requested length is 0, returning empty Uint8List.'); // ADDED
      return Uint8List(0); // Handle zero length request immediately
    }

    if (length == null) {
      if (!_decryptedBuffer.isEmpty) {
        final data = _decryptedBuffer.takeAll();
        _log.finer('SecuredConnection.read (length=null): Returning buffered data of length ${data.length}. Data preview: ${data.take(20).toList()}'); // ADDED
        return data;
      }
      final decryptedMessage = await _readAndDecryptMessage();
      _log.finer('SecuredConnection.read (length=null): Returning directly from _readAndDecryptMessage, length ${decryptedMessage.length}. Data preview: ${decryptedMessage.take(20).toList()}'); // ADDED
      return decryptedMessage;
    }

    // length is not null here
    while (_decryptedBuffer.length < length) {
      Uint8List decryptedChunk;
      try {
        _log.finer('SecuredConnection.read (length=$length): _decryptedBuffer.length (${_decryptedBuffer.length}) < requested ($length). Calling _readAndDecryptMessage().'); // ADDED
        decryptedChunk = await _readAndDecryptMessage();
      } catch (e) {
        _log.finer('SecuredConnection.read (length=$length): Error in _readAndDecryptMessage: $e. Current _decryptedBuffer.length: ${_decryptedBuffer.length}'); // ADDED
        if (_decryptedBuffer.length < length) {
          rethrow;
        }
        // If we have enough buffered data despite the error, we can proceed to return it.
        break;
      }

      if (decryptedChunk.isEmpty) { // EOF from _readAndDecryptMessage
        _log.finer('SecuredConnection.read (length=$length): _readAndDecryptMessage returned empty (EOF). Breaking loop.'); // ADDED
        break;
      }

      // Use optimized buffer - no more array reallocations!
      _decryptedBuffer.add(decryptedChunk);
      _log.finer('SecuredConnection.read (length=$length): Added ${decryptedChunk.length} bytes to _decryptedBuffer. New _decryptedBuffer.length: ${_decryptedBuffer.length}'); // ADDED
    }

    if (_decryptedBuffer.isEmpty) {
      _log.finer('SecuredConnection.read (length=$length): _decryptedBuffer is empty after loop. Returning empty Uint8List.'); // ADDED
      return Uint8List(0);
    }

    if (_decryptedBuffer.length >= length) {
      final dataToReturn = _decryptedBuffer.takeBytes(length);
      _log.finer('SecuredConnection.read (length=$length): Returning ${dataToReturn.length} bytes. Remaining _decryptedBuffer.length: ${_decryptedBuffer.length}. Data preview: ${dataToReturn.take(20).toList()}'); // ADDED
      return dataToReturn;
    } else { // Less data than requested due to EOF
      final dataToReturn = _decryptedBuffer.takeAll();
      _log.finer('SecuredConnection.read (length=$length): Returning ${dataToReturn.length} bytes (less than requested due to EOF). _decryptedBuffer is now empty. Data preview: ${dataToReturn.take(20).toList()}'); // ADDED
      return dataToReturn;
    }
  }

  /// Reads exactly the expected number of bytes, handling partial reads from the underlying transport
  Future<Uint8List> _readFullMessage(int expectedLength, {Duration? timeout}) async {
    timeout ??= Duration(seconds: 30); // Default timeout for message reads
    final startTime = DateTime.now();
    
    if (expectedLength == 0) {
      return Uint8List(0);
    }
    
    var buffer = Uint8List(0);
    int readAttempts = 0;
    
    while (buffer.length < expectedLength) {
      readAttempts++;
      
      // Check timeout
      if (DateTime.now().difference(startTime) > timeout) {
        _log.warning('SecuredConnection: Timeout reading message after ${readAttempts} attempts. Expected: $expectedLength, Got: ${buffer.length}');
        throw TimeoutException('Timeout reading message', timeout);
      }
      
      final remaining = expectedLength - buffer.length;
      _log.finer('SecuredConnection: _readFullMessage attempt $readAttempts: need $remaining more bytes (have ${buffer.length}/$expectedLength)');
      
      final chunk = await _connection.read(remaining);
      
      if (chunk.isEmpty) {
        _log.finer('SecuredConnection: _readFullMessage got EOF after $readAttempts attempts. Expected: $expectedLength, Got: ${buffer.length}');
        break; // EOF - return what we have
      }
      
      _log.finer('SecuredConnection: _readFullMessage attempt $readAttempts: received ${chunk.length} bytes');
      
      // Efficiently append chunk to buffer
      final newBuffer = Uint8List(buffer.length + chunk.length);
      newBuffer.setAll(0, buffer);
      newBuffer.setAll(buffer.length, chunk);
      buffer = newBuffer;
    }
    
    _log.finer('SecuredConnection: _readFullMessage completed after $readAttempts attempts. Expected: $expectedLength, Got: ${buffer.length}');
    return buffer;
  }

  Future<Uint8List> _readAndDecryptMessage() async {
    // This method now encapsulates reading one full encrypted message and decrypting it.
    // It handles partial reads from the underlying transport robustly.
    _log.finer('SecuredConnection: Reading length prefix');
    final lengthBytes = await _readFullMessage(2);
    _log.finer('SecuredConnection: FROM_UNDERLYING_READ (Length Prefix) - Bytes: ${hex.encode(lengthBytes)}');

    if (lengthBytes.isEmpty) {
      _log.finer('SecuredConnection: EOF when reading length prefix.');
      return Uint8List(0);
    }
    if (lengthBytes.length < 2) {
      _log.finer('SecuredConnection: Connection closed while reading length prefix, got ${lengthBytes.length} bytes.');
      throw StateError('Connection closed while reading length prefix');
    }

    final dataLength = (lengthBytes[0] << 8) | lengthBytes[1];
    _log.finer('SecuredConnection: Got length prefix: $dataLength');

    if (dataLength == 0) return Uint8List(0); // Valid empty message

    _log.finer('SecuredConnection: Reading combined data of length $dataLength');
    final combinedData = await _readFullMessage(dataLength);
    _log.finer('SecuredConnection: FROM_UNDERLYING_READ (Message Body) - Length: ${combinedData.length}, Bytes: ${hex.encode(combinedData)}');

    if (combinedData.length < dataLength) {
      _log.finer('SecuredConnection: Connection closed while reading message body. Expected: $dataLength, Got: ${combinedData.length}');
      throw StateError('Connection closed while reading message body. Expected: $dataLength, Got: ${combinedData.length}');
    }
    _log.finer('SecuredConnection: Got combined data of length ${combinedData.length}');

    final encrypted = combinedData.sublist(0, dataLength - 16);
    final mac = combinedData.sublist(dataLength - 16);
    _log.finer('SecuredConnection: Split into encrypted(${encrypted.length}) and MAC(${mac.length})');
    _log.finer('SecuredConnection:   Raw Received Ciphertext: ${hex.encode(encrypted)}');
    _log.finer('SecuredConnection:   Raw Received MAC: ${hex.encode(mac)}');
    _log.finer('SecuredConnection: First 4 bytes of encrypted: ${encrypted.take(4).toList()}');
    _log.finer('SecuredConnection: First 4 bytes of MAC: ${mac.take(4).toList()}');
    _log.finer('SecuredConnection: Full MAC: ${mac.toList()}');

    final algorithm = crypto.Chacha20.poly1305Aead();
    final nonce = _getNonce(_recvNonce++);
    _log.finer('SecuredConnection: Attempting decryption with nonce: ${nonce.toList()}');
    // ADDED LOGGING for hashCode
    _log.finer('SecuredConnection: Using decryption key (hashCode: ${_decryptionKey.hashCode}): ${await _decryptionKey.extractBytes()}');

    try {
      final plaintext = await algorithm.decrypt(
        crypto.SecretBox(
          encrypted,
          nonce: nonce,
          mac: crypto.Mac(mac),
        ),
        secretKey: _decryptionKey,
        aad: Uint8List(0),
      );
      _log.finer('SecuredConnection: Decryption successful, got ${plaintext.length} bytes');
      return Uint8List.fromList(plaintext);
    } catch (e) {
      _log.finer('SecuredConnection: Decryption failed with error: $e');
      _log.finer('SecuredConnection: Full message details:');
      _log.finer('  - Length prefix: ${lengthBytes.toList()}');
      _log.finer('  - Total data length: $dataLength');
      _log.finer('  - Encrypted data length: ${encrypted.length}');
      _log.finer('  - MAC length: ${mac.length}');
      _log.finer('  - Nonce: ${nonce.toList()}');
      rethrow;
    }
  }

  @override
  Future<void> write(Uint8List data) async {
    // ADDED LOGGING: Print the initial plaintext data received by write()

    _log.finer('SecuredConnection.write: Plaintext data received (length: ${data.length}, first 20 bytes: ${data.take(20).toList()})');
    _log.finer('SecuredConnection: Writing data of length ${data.length}');
    final algorithm = crypto.Chacha20.poly1305Aead();
    final nonce = _getNonce(_sendNonce++);
    _log.finer('SecuredConnection: Using nonce: ${nonce.toList()}');
    // ADDED LOGGING for hashCode
    _log.finer('SecuredConnection: Using encryption key (hashCode: ${_encryptionKey.hashCode}): ${await _encryptionKey.extractBytes()}');

    final secretBox = await algorithm.encrypt(
      data,
      secretKey: _encryptionKey,
      nonce: nonce,
      aad: Uint8List(0),
    );


    // Calculate total length of encrypted data + MAC
    final dataLength = secretBox.cipherText.length + secretBox.mac.bytes.length;
    _log.finer('SecuredConnection: Encrypted data length: ${secretBox.cipherText.length}');
    _log.finer('SecuredConnection: MAC length: ${secretBox.mac.bytes.length}');
    _log.finer('SecuredConnection: MAC: ${secretBox.mac.bytes.toList()}');
    _log.finer('SecuredConnection:   Raw Ciphertext to send: ${hex.encode(secretBox.cipherText)}');
    _log.finer('SecuredConnection:   Raw MAC to send: ${hex.encode(secretBox.mac.bytes)}');


    // Write length prefix and data in one operation
    final combinedData = Uint8List(2 + dataLength)
    // Write length prefix (2 bytes)
      ..[0] = dataLength >> 8
      ..[1] = dataLength & 0xFF
    // Write encrypted data
      ..setAll(2, secretBox.cipherText)
    // Write MAC
      ..setAll(2 + secretBox.cipherText.length, secretBox.mac.bytes);

    _log.finer('SecuredConnection: Writing ${data.length} bytes as ${dataLength} bytes encrypted+MAC');
    _log.finer('SecuredConnection:   Raw Ciphertext to send: ${hex.encode(secretBox.cipherText)}');
    _log.finer('SecuredConnection:   Raw MAC to send: ${hex.encode(secretBox.mac.bytes)}');
    _log.finer('SecuredConnection: First 4 bytes of encrypted: ${secretBox.cipherText.take(4).toList()}');
    _log.finer('SecuredConnection: TO_UNDERLYING_WRITE - Length: ${combinedData.length}, Bytes: ${hex.encode(combinedData)}');
    await _connection.write(combinedData);
  }

  @override
  bool get isClosed => _connection.isClosed;

  @override
  MultiAddr get localMultiaddr => _connection.localMultiaddr;

  @override
  MultiAddr get remoteMultiaddr => _connection.remoteMultiaddr;

  // Deprecated methods that should be replaced with localMultiaddr/remoteMultiaddr
  @override
  MultiAddr get localAddr => localMultiaddr;

  @override
  MultiAddr get remoteAddr => remoteMultiaddr;

  @override
  Socket get socket => throw UnimplementedError('Socket access not supported in SecuredConnection');

  @override
  void setReadTimeout(Duration timeout) => _connection.setReadTimeout(timeout);

  @override
  void setWriteTimeout(Duration timeout) => _connection.setWriteTimeout(timeout);

  @override
  String get id => _connection.id;

  @override
  Future<P2PStream> newStream(Context context) =>
      _connection.newStream(context);

  @override
  Future<List<P2PStream>> get streams => _connection.streams;

  @override
  PeerId get localPeer => _connection.localPeer;

  @override
  PeerId get remotePeer => establishedRemotePeer ?? _connection.remotePeer;

  @override
  Future<PublicKey?> get remotePublicKey async => establishedRemotePublicKey ?? await _connection.remotePublicKey;

  @override
  ConnState get state {
    // If secured, update the state to reflect the security protocol used
    // If secured, update the state to reflect the security protocol used
    // This state is now built using the provided securityProtocolId
    final originalState = _connection.state;
    return ConnState(
      streamMultiplexer: originalState.streamMultiplexer,
      security: securityProtocolId, // Use the passed-in ID
      transport: originalState.transport,
      usedEarlyMuxerNegotiation: originalState.usedEarlyMuxerNegotiation,
    );
  }

  @override
  ConnStats get stat => _connection.stat;

  @override
  ConnScope get scope => _connection.scope;

  @override
  void notifyActivity() {
    _connection.notifyActivity();
  }
}
