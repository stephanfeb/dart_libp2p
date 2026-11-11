# Libp2p Cookbook

This cookbook provides practical, goal-oriented recipes for common tasks you might want to accomplish with `dart-libp2p`.

## Recipe: Building a Simple P2P Chat

This recipe demonstrates how to build a simple, command-line chat application where two peers can exchange messages directly.

### 1. The Chat Protocol

First, we define a simple protocol for our chat application. When a peer wants to send a message, it will open a stream to the other peer using the protocol ID `/chat/1.0.0`, write the message to it, followed by a newline character, and close its side of the stream. The receiver reads until the stream ends.

### 2. The `ChatClient` Class

We'll create a `ChatClient` class to encapsulate the logic for sending and receiving messages.

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_libp2p/dart_libp2p.dart';

class ChatClient {
  final Host host;
  static const String protocolId = '/chat/1.0.0';

  ChatClient(this.host) {
    // Set a stream handler for our chat protocol
    host.setStreamHandler(protocolId, _handleIncomingMessage);
  }

  // The last characters of a peer ID tell peers apart; the first ones do not.
  String _short(PeerId id) {
    final s = id.toBase58();
    return s.substring(s.length - 6);
  }

  // Handler for incoming chat messages: one message per stream
  Future<void> _handleIncomingMessage(P2PStream stream, PeerId remotePeer) async {
    try {
      // Read until the sender closes its side (read() returns an empty list)
      final bytes = <int>[];
      while (true) {
        final chunk = await stream.read();
        if (chunk.isEmpty) break;
        bytes.addAll(chunk);
        if (bytes.length > 64 * 1024) break; // a chat message is small
      }
      // Display the received message
      print('\n[${_short(remotePeer)} says]: ${utf8.decode(bytes).trimRight()}');
      stdout.write('> ');
    } catch (e) {
      print('Error on chat stream: $e');
    } finally {
      await stream.close();
    }
  }

  // Send a message to a peer
  Future<void> sendMessage(PeerId targetPeer, String message) async {
    try {
      final stream = await host.newStream(targetPeer, [protocolId], Context());
      await stream.write(utf8.encode('$message\n'));
      // closeWrite() tells the receiver that the message is complete.
      await stream.closeWrite();
      await stream.close();
    } catch (e) {
      print('Error sending message to ${targetPeer.toBase58()}: $e');
    }
  }
}
```

### 3. The Main Application

Now, let's wire everything together. We'll create two hosts, connect them, and then start a loop to read messages from the command line and send them.

```dart
Future<Host> createHost() async {
  // ... (use the createHost function from the Getting Started guide)
}

void main() async {
  // Create two hosts
  final host1 = await createHost();
  final host2 = await createHost();

  print('Host 1: ${host1.id.toBase58()} listening on ${host1.network.listenAddresses}');
  print('Host 2: ${host2.id.toBase58()} listening on ${host2.network.listenAddresses}');

  // Create chat clients for each host
  final chat1 = ChatClient(host1);
  ChatClient(host2); // registers the handler on host2

  // Connect host1 to host2
  await host1.connect(AddrInfo(host2.id, host2.network.listenAddresses));
  print('\n--- Chat session started! ---');
  print('Type a message and press Enter to send. Close stdin (Ctrl-D) to quit.');
  print('Messages from you will be sent from ${host1.id.toBase58()}.');
  print('---------------------------\n');

  // Read lines from stdin and send each one
  stdout.write('> ');
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    await chat1.sendMessage(host2.id, line);
    stdout.write('> ');
  }

  // stdin closed: shut down
  await host1.close();
  await host2.close();
}
```

### Running the Example

When you run this code, you'll see the PeerIDs and listen addresses for both hosts. The application will then wait for you to type a message. Anything you type will be sent from Host 1 to Host 2, and Host 2 will print it to the console. Close the input (Ctrl-D) to close both hosts and end the program.

Put the imports of the Getting Started `createHost` at the top of the same file.

This simple example illustrates the power of libp2p for building peer-to-peer applications. You can easily extend this to handle multiple peers, message history, and more complex interactions.
