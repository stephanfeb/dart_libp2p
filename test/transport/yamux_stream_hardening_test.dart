import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:logging/logging.dart';

import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/stream.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/frame.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/yamux_exceptions.dart';

// Generate mocks
@GenerateMocks([Conn])
import 'yamux_stream_hardening_test.mocks.dart';

void main() {
  // Set up logging for tests
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  group('YamuxStream State Exception Handling', () {
    late MockConn mockConn;
    late List<YamuxFrame> sentFrames;
    late YamuxStream stream;

    setUp(() {
      mockConn = MockConn();
      sentFrames = [];
      
      // Create a stream with a mock frame sender
      stream = YamuxStream(
        id: 1,
        protocol: '/test/1.0.0',
        metadata: {},
        initialWindowSize: 65536,
        sendFrame: (frame) async {
          sentFrames.add(frame);
        },
        parentConn: mockConn,
        logPrefix: 'Test',
      );
    });

    test('read() on reset stream throws YamuxStreamStateException', () async {
      // Force the stream into reset state
      await stream.forceReset();
      
      // Attempt to read should throw a properly classified exception
      await expectLater(
        stream.read(),
        throwsA(isA<YamuxStreamStateException>()
            .having((e) => e.currentState, 'currentState', 'reset')
            .having((e) => e.requestedOperation, 'requestedOperation', 'read')
            .having((e) => e.streamId, 'streamId', 1)),
      );
    });

    test('read() on closed stream throws YamuxStreamStateException', () async {
      // Open the stream first
      await stream.open();
      
      // Close the stream
      await stream.close();
      
      // Attempt to read should throw a properly classified exception
      await expectLater(
        stream.read(),
        throwsA(isA<YamuxStreamStateException>()
            .having((e) => e.currentState, 'currentState', 'closed')
            .having((e) => e.requestedOperation, 'requestedOperation', 'read')
            .having((e) => e.streamId, 'streamId', 1)),
      );
    });

    test('read() on init stream throws YamuxStreamStateException', () async {
      // Stream starts in init state, attempt to read should throw
      await expectLater(
        stream.read(),
        throwsA(isA<YamuxStreamStateException>()
            .having((e) => e.currentState, 'currentState', contains('init'))
            .having((e) => e.requestedOperation, 'requestedOperation', 'read')
            .having((e) => e.streamId, 'streamId', 1)),
      );
    });

    test('read() with timeout on hanging stream', () async {
      // Open the stream
      await stream.open();
      
      // Start a read operation that will timeout
      final readFuture = stream.read();
      
      // Wait a bit to ensure the read is waiting
      await Future.delayed(Duration(milliseconds: 100));
      
      // The read should eventually timeout and throw YamuxStreamTimeoutException
      expect(
        () async => await readFuture.timeout(Duration(seconds: 1)),
        throwsA(anyOf([
          isA<TimeoutException>(),
          isA<YamuxStreamTimeoutException>(),
        ])),
      );
    });

    test('read() returns EOF on closing stream with empty queue', () async {
      // Open the stream
      await stream.open();
      
      // Simulate receiving a FIN frame to put stream in closing state
      final finFrame = YamuxFrame.createData(1, Uint8List(0), fin: true);
      await stream.handleFrame(finFrame);
      
      // Read should return EOF (empty data) instead of throwing
      final result = await stream.read();
      expect(result, isEmpty);
    });

    test('read() handles state transitions gracefully', () async {
      // Open the stream
      await stream.open();
      
      // Start a read operation
      final readFuture = stream.read();
      
      // Reset the stream while read is waiting
      await stream.reset();
      
      // The read should throw a properly classified exception
      await expectLater(
        readFuture,
        throwsA(isA<YamuxStreamStateException>()
            .having((e) => e.currentState, 'currentState', 'reset')
            .having((e) => e.requestedOperation, 'requestedOperation', 'read')
            .having((e) => e.streamId, 'streamId', 1)),
      );
    });

    test('multiple concurrent reads handle state changes safely', () async {
      // Open the stream
      await stream.open();
      
      // Start multiple read operations
      final readFutures = List.generate(3, (_) => stream.read());
      
      // Reset the stream while reads are waiting
      await Future.delayed(Duration(milliseconds: 50));
      await stream.reset();
      
      // All reads should complete without hanging
      final results = await Future.wait(
        readFutures.map((f) => f.catchError((e) => Uint8List(0))),
      );
      
      // All should return EOF or handle the error gracefully
      for (final result in results) {
        expect(result, isEmpty);
      }
    });

    test('YamuxExceptionHandler.classifyYamuxException works correctly', () {
      // Test StateError classification
      final stateError = StateError('Stream is now in state YamuxStreamState.reset');
      final classified = YamuxExceptionHandler.classifyYamuxException(
        stateError,
        StackTrace.current,
        streamId: 1,
        operation: 'read',
        currentState: 'reset',
      );
      
      expect(classified, isA<YamuxStreamStateException>());
      final streamStateEx = classified as YamuxStreamStateException;
      expect(streamStateEx.currentState, 'reset');
      expect(streamStateEx.requestedOperation, 'read');
      expect(streamStateEx.streamId, 1);
    });

    test('YamuxExceptionHandler.shouldResetStream logic', () {
      // Test different exception types
      final resetStateEx = YamuxStreamStateException(
        'test',
        currentState: 'reset',
        requestedOperation: 'read',
        streamId: 1,
      );
      expect(YamuxExceptionHandler.shouldResetStream(resetStateEx), false);
      
      final openStateEx = YamuxStreamStateException(
        'test',
        currentState: 'open',
        requestedOperation: 'read',
        streamId: 1,
      );
      expect(YamuxExceptionHandler.shouldResetStream(openStateEx), true);
      
      final protocolEx = YamuxStreamProtocolException(
        'test',
        protocolError: 'format_error',
        streamId: 1,
      );
      expect(YamuxExceptionHandler.shouldResetStream(protocolEx), true);
    });

    test('stream state validation methods work correctly', () async {
      // Test _isValidStateForRead through public interface
      
      // Init state should be invalid for read
      await expectLater(
        stream.read(),
        throwsA(isA<YamuxStreamStateException>()),
      );
      
      // Open state should be valid for read (will timeout but not throw state error)
      await stream.open();
      final readFuture = stream.read();
      
      // Cancel the read to avoid timeout
      await stream.reset();
      
      // Should throw a properly classified exception
      await expectLater(
        readFuture,
        throwsA(isA<YamuxStreamStateException>()),
      );
    });
  });

  group('YamuxStream Exception Integration', () {
    late MockConn mockConn;
    late List<YamuxFrame> sentFrames;
    late YamuxStream stream;

    setUp(() {
      mockConn = MockConn();
      sentFrames = [];
      
      stream = YamuxStream(
        id: 2,
        protocol: '/integration/1.0.0',
        metadata: {},
        initialWindowSize: 65536,
        sendFrame: (frame) async {
          sentFrames.add(frame);
        },
        parentConn: mockConn,
        logPrefix: 'Integration',
      );
    });

    test('exception context is properly preserved', () async {
      await stream.open();
      await stream.reset();
      
      try {
        await stream.read();
        fail('Should have thrown an exception');
      } catch (e) {
        if (e is YamuxStreamStateException) {
          expect(e.context['streamId'], 2);
          expect(e.context['operation'], 'read');
          expect(e.context['currentState'], contains('reset'));
          expect(e.originalException, isA<StateError>());
        }
      }
    });

    test('exception chaining preserves original error information', () async {
      await stream.open();
      await stream.reset();
      
      try {
        await stream.read();
        fail('Should have thrown an exception');
      } catch (e) {
        if (e is YamuxStreamStateException) {
          expect(e.originalException, isNotNull);
          expect(e.originalStackTrace, isNotNull);
          expect(e.timestamp, isNotNull);
          expect(e.toString(), contains('Stream 2'));
          expect(e.toString(), contains('reset'));
        }
      }
    });
  });
}
