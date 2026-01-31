import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';

/// Manages a go-libp2p test peer process for interop testing.
class GoProcessManager {
  final String binaryPath;
  Process? _process;
  PeerId? _peerId;
  MultiAddr? _listenAddr;
  final List<String> _output = [];
  final _outputController = StreamController<String>.broadcast();
  bool _ready = false;

  GoProcessManager({required this.binaryPath});

  PeerId get peerId {
    if (_peerId == null) throw StateError('Go peer not started');
    return _peerId!;
  }

  MultiAddr get listenAddr {
    if (_listenAddr == null) throw StateError('Go peer not started');
    return _listenAddr!;
  }

  List<String> get output => List.unmodifiable(_output);

  /// Builds the Go peer binary if it doesn't exist.
  static Future<String> ensureBinary(String goSourceDir) async {
    final binaryPath = '$goSourceDir/go-peer';
    final binary = File(binaryPath);

    if (!await binary.exists()) {
      final result = await Process.run(
        'go',
        ['build', '-o', 'go-peer', '.'],
        workingDirectory: goSourceDir,
      );
      if (result.exitCode != 0) {
        throw Exception('Failed to build Go peer: ${result.stderr}');
      }
    }
    return binaryPath;
  }

  /// Starts the Go peer in server mode on a random port.
  Future<void> startServer({int port = 0}) async {
    await _start(['--mode=server', '--port=$port']);
  }

  /// Starts the Go peer in echo-server mode.
  Future<void> startEchoServer({int port = 0}) async {
    await _start(['--mode=echo-server', '--port=$port']);
  }

  Future<void> _start(List<String> args) async {
    _process = await Process.start(binaryPath, args);

    _process!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      _output.add('[stderr] $line');
      _outputController.add('[stderr] $line');
    });

    _process!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      _output.add(line);
      _outputController.add(line);

      if (line.startsWith('PeerID: ')) {
        _peerId = PeerId.fromString(line.substring('PeerID: '.length).trim());
      } else if (line.startsWith('Listening: ') && line.contains('127.0.0.1')) {
        _listenAddr = MultiAddr(line.substring('Listening: '.length).trim());
      } else if (line == 'Ready') {
        _ready = true;
      }
    });

    // Wait for the process to be ready
    await waitForOutput('Ready', timeout: const Duration(seconds: 30));
  }

  /// Runs the Go peer in client mode (connects and exits).
  Future<ProcessResult> runClient(String targetMultiaddr) async {
    return Process.run(
      binaryPath,
      ['--mode=client', '--target=$targetMultiaddr'],
    );
  }

  /// Runs the Go peer in ping mode.
  Future<ProcessResult> runPing(String targetMultiaddr) async {
    return Process.run(
      binaryPath,
      ['--mode=ping', '--target=$targetMultiaddr'],
    );
  }

  /// Runs the Go peer in echo-client mode.
  Future<ProcessResult> runEchoClient(String targetMultiaddr, String message) async {
    return Process.run(
      binaryPath,
      ['--mode=echo-client', '--target=$targetMultiaddr', '--message=$message'],
    );
  }

  /// Waits for a specific string to appear in the output.
  Future<String> waitForOutput(String pattern, {Duration timeout = const Duration(seconds: 30)}) async {
    // Check existing output first
    for (final line in _output) {
      if (line.contains(pattern)) return line;
    }

    return _outputController.stream
        .firstWhere((line) => line.contains(pattern))
        .timeout(timeout, onTimeout: () {
      throw TimeoutException(
        'Timed out waiting for "$pattern" in Go peer output.\nOutput so far:\n${_output.join("\n")}',
        timeout,
      );
    });
  }

  /// Stops the Go peer process.
  Future<void> stop() async {
    if (_process != null) {
      _process!.stdin.writeln('quit');
      // Give it a moment to exit gracefully
      final exitCode = await _process!.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _process!.kill(ProcessSignal.sigterm);
          return _process!.exitCode.timeout(
            const Duration(seconds: 2),
            onTimeout: () {
              _process!.kill(ProcessSignal.sigkill);
              return -1;
            },
          );
        },
      );
      _process = null;
    }
    _peerId = null;
    _listenAddr = null;
    _ready = false;
    _output.clear();
  }
}
