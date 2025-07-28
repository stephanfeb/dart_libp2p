import 'dart:typed_data';

/// Yamux frame types
enum YamuxFrameType {
  /// Used to send data
  dataFrame(0x0),
  /// Used to update window sizes
  windowUpdate(0x1),
  /// Used to create new streams
  newStream(0x2),
  /// Used to reset streams
  reset(0x3),
  /// Used for keepalive
  ping(0x4),
  /// Used to respond to pings
  goAway(0x5);

  final int value;
  const YamuxFrameType(this.value);

  static YamuxFrameType fromValue(int value) {
    return YamuxFrameType.values.firstWhere(
      (type) => type.value == value,
      orElse: () => throw FormatException('Invalid frame type: $value'),
    );
  }
}

/// Yamux frame flags
class YamuxFlags {
  static const int syn = 0x1;
  static const int ack = 0x2;
  static const int fin = 0x4;
  static const int rst = 0x8;
}

/// Represents a Yamux frame
class YamuxFrame {
  /// Frame version (must be 0)
  static const int version = 0;

  /// Frame type
  final YamuxFrameType type;

  /// Frame flags
  final int flags;

  /// Stream ID
  final int streamId;

  /// Frame length
  final int length;

  /// Frame data
  final Uint8List data;

  const YamuxFrame({
    required this.type,
    required this.flags,
    required this.streamId,
    required this.length,
    required this.data,
  });

  /// Creates a frame from bytes
  factory YamuxFrame.fromBytes(Uint8List bytes) {
    if (bytes.length < 12) {
      throw FormatException('Frame too short');
    }

    final header = ByteData.view(bytes.buffer, bytes.offsetInBytes, 12);
    
    // Version must be 0
    final version = header.getUint8(0);
    if (version != YamuxFrame.version) {
      throw FormatException('Invalid version: $version');
    }

    // Parse type
    final type = YamuxFrameType.fromValue(header.getUint8(1));
    
    // Parse flags
    final flags = header.getUint16(2, Endian.big);
    
    // Parse stream ID
    final streamId = header.getUint32(4, Endian.big);
    
    // Parse length
    final length = header.getUint32(8, Endian.big);
    
    // Get data
    final data = bytes.length > 12 ? bytes.sublist(12) : Uint8List(0);
    if (data.length != length) {
      throw FormatException('Frame data length mismatch');
    }

    return YamuxFrame(
      type: type,
      flags: flags,
      streamId: streamId,
      length: length,
      data: data,
    );
  }

  /// Converts the frame to bytes
  Uint8List toBytes() {
    // ADDED LOG: Log frame details before serialization
    // print('YamuxFrame.toBytes: Serializing Frame - Type: $type, StreamID: $streamId, Flags: $flags, Length: $length, Data (first 10 bytes): ${data.take(10).toList()}');

    final buffer = ByteData(12 + length);
    
    // Write version
    buffer.setUint8(0, version);
    
    // Write type
    buffer.setUint8(1, type.value);
    
    // Write flags
    buffer.setUint16(2, flags, Endian.big);
    
    // Write stream ID
    buffer.setUint32(4, streamId, Endian.big);
    
    // Write length
    buffer.setUint32(8, length, Endian.big);
    
    // Write data
    if (length > 0) {
      buffer.buffer.asUint8List().setRange(12, 12 + length, data);
    }

    final resultBytes = buffer.buffer.asUint8List();
    // ADDED LOG: Log the first few bytes of the serialized frame
    // print('YamuxFrame.toBytes: Serialized Bytes (first 16): ${resultBytes.take(16).toList()}');
    return resultBytes;
  }

  /// Creates a DATA frame
  static YamuxFrame createData(int streamId, Uint8List data, {bool fin = false}) {
    return YamuxFrame(
      type: YamuxFrameType.dataFrame,
      flags: fin ? YamuxFlags.fin : 0,
      streamId: streamId,
      length: data.length,
      data: data,
    );
  }

  /// Creates a WINDOW_UPDATE frame
  static YamuxFrame windowUpdate(int streamId, int delta) {
    final data = ByteData(4)..setUint32(0, delta, Endian.big);
    return YamuxFrame(
      type: YamuxFrameType.windowUpdate,
      flags: 0,
      streamId: streamId,
      length: 4,
      data: data.buffer.asUint8List(),
    );
  }

  /// Creates a NEW_STREAM frame
  static YamuxFrame newStream(int streamId) {
    return YamuxFrame(
      type: YamuxFrameType.newStream,
      flags: YamuxFlags.syn,
      streamId: streamId,
      length: 0,
      data: Uint8List(0),
    );
  }

  /// Creates a RESET frame
  static YamuxFrame reset(int streamId) {
    return YamuxFrame(
      type: YamuxFrameType.reset,
      flags: YamuxFlags.rst,
      streamId: streamId,
      length: 0,
      data: Uint8List(0),
    );
  }

  /// Creates a PING frame
  static YamuxFrame ping(bool ack, [int? value]) {
    Uint8List data;
    if (value != null) {
      final byteData = ByteData(8);
      byteData.setUint64(0, value, Endian.big);
      data = byteData.buffer.asUint8List();
    } else {
      data = Uint8List(0);
    }
    
    return YamuxFrame(
      type: YamuxFrameType.ping,
      flags: ack ? YamuxFlags.ack : 0,
      streamId: 0,
      length: data.length,
      data: data,
    );
  }

  /// Creates a GO_AWAY frame
  static YamuxFrame goAway(int reason) {
    final data = ByteData(4)..setUint32(0, reason, Endian.big);
    return YamuxFrame(
      type: YamuxFrameType.goAway,
      flags: 0,
      streamId: 0,
      length: 4,
      data: data.buffer.asUint8List(),
    );
  }
}
