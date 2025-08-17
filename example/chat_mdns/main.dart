import 'dart:async';
import 'dart:convert';
import 'dart:io';


import '../shared/host_utils.dart';
import 'chat_client_mdns.dart';

void main() async {
  print('🚀 Starting mDNS P2P Chat Example');
  print('This example uses mDNS to discover chat peers on your local network.\n');

  try {
    // Create a libp2p host
    final host = await createHostWithRandomPort();
    print('🏠 Your chat host: [${truncatePeerId(host.id)}]');
    print('📡 Listening on: ${host.addrs}\n');

    // Create the mDNS-enabled chat client
    final chatClient = ChatClientMdns(host);

    // Set up graceful shutdown
    bool isShuttingDown = false;
    
    void cleanup() async {
      if (isShuttingDown) return;
      isShuttingDown = true;
      
      print('\n\n🛑 Shutting down...');
      try {
        await chatClient.stopDiscovery();
        await host.close();
        print('✅ Cleanup completed.');
      } catch (e) {
        print('⚠️  Error during cleanup: $e');
      }
      exit(0);
    }

    // Handle Ctrl+C gracefully
    ProcessSignal.sigint.watch().listen((_) => cleanup());

    // Start mDNS discovery
    await chatClient.startDiscovery();
    
    print('🔍 Searching for other chat peers on your network...');
    print('📢 Other chat apps on this network should discover you automatically.\n');
    
    print('--- mDNS P2P Chat Session ---');
    print('Commands:');
    print('  list         - Show discovered peers');
    print('  select <n>   - Select peer number for chatting');
    print('  help or ?    - Show help');
    print('  quit         - Exit');
    print('');
    print('💡 Tip: Run this program on multiple devices/terminals to see peer discovery in action!');
    print('-----------------------------\n');

    // Wait a moment for initial discovery
    await Future.delayed(Duration(seconds: 2));
    chatClient.showPeerList();

    // Start input processing loop
    stdin.transform(utf8.decoder).transform(LineSplitter()).listen((line) async {
      if (line.trim().isEmpty) {
        stdout.write('> ');
        return;
      }
      
      final shouldContinue = await chatClient.processCommand(line);
      if (!shouldContinue) {
        cleanup();
        return;
      }
      
      // Show status and prompt
      print('📊 Status: ${chatClient.getStatus()}');
      stdout.write('> ');
    });

    stdout.write('> ');
    
  } catch (e) {
    print('❌ Error: $e');
    exit(1);
  }
}
