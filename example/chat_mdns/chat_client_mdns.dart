import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_libp2p/dart_libp2p.dart';
import 'package:dart_libp2p/p2p/discovery/mdns/mdns.dart';
import 'package:dart_libp2p/core/network/context.dart';

class ChatClientMdns implements MdnsNotifee {
  final Host host;
  final MdnsDiscovery mdnsDiscovery;
  static const String protocolId = '/chat/1.0.0';
  static const String chatNamespace = 'dart-libp2p-chat';
  
  // Track discovered peers
  final Map<PeerId, AddrInfo> discoveredPeers = {};
  
  // Currently selected peer for chatting
  PeerId? _currentPeer;
  
  ChatClientMdns(this.host) : mdnsDiscovery = MdnsDiscovery(host) {
    // Set up our chat protocol handler
    host.setStreamHandler(protocolId, _handleIncomingMessage);
    
    // Set up mDNS discovery
    mdnsDiscovery.notifee = this;
  }

  /// Start mDNS advertising and discovery
  Future<void> startDiscovery() async {
    await mdnsDiscovery.start();
    await mdnsDiscovery.advertise(chatNamespace);
    
    // Start listening for other chat peers
    final discoveryStream = await mdnsDiscovery.findPeers(chatNamespace);
    discoveryStream.listen((peer) {
      // Peer discovery through stream (backup to notifee)
      _onPeerDiscovered(peer);
    });
    
    print('📡 mDNS discovery started - advertising and looking for chat peers...');
  }

  /// Stop mDNS services
  Future<void> stopDiscovery() async {
    await mdnsDiscovery.stop();
  }

  @override
  void handlePeerFound(AddrInfo peer) {
    _onPeerDiscovered(peer);
  }

  void _onPeerDiscovered(AddrInfo peer) {
    // Don't add ourselves
    if (peer.id == host.id) return;
    
    // Add to discovered peers if not already present
    if (!discoveredPeers.containsKey(peer.id)) {
      discoveredPeers[peer.id] = peer;
      print('\n🔍 Discovered new chat peer: [${_truncatePeerId(peer.id)}]');
      showPeerList();
      stdout.write('> ');
    }
  }

  /// Display list of discovered peers
  void showPeerList() {
    if (discoveredPeers.isEmpty) {
      print('No chat peers discovered yet. Waiting for peers...');
      return;
    }
    
    print('\n📋 Available chat peers:');
    int index = 1;
    for (final peer in discoveredPeers.values) {
      final prefix = _currentPeer == peer.id ? '👉' : '  ';
      print('$prefix $index. [${_truncatePeerId(peer.id)}] - ${peer.addrs.first}');
      index++;
    }
    
    if (_currentPeer == null && discoveredPeers.isNotEmpty) {
      print('\n💡 Type "select <number>" to choose a peer to chat with.');
      print('💡 Type "list" to see available peers.');
    }
  }

  /// Select a peer to chat with by index
  bool selectPeer(int index) {
    if (index < 1 || index > discoveredPeers.length) {
      print('❌ Invalid peer number. Use "list" to see available peers.');
      return false;
    }
    
    final peer = discoveredPeers.values.elementAt(index - 1);
    _currentPeer = peer.id;
    print('✅ Selected peer [${_truncatePeerId(peer.id)}] for chatting.');
    return true;
  }

  /// Handle incoming chat messages
  Future<void> _handleIncomingMessage(P2PStream stream, PeerId remotePeer) async {
    try {
      // Read the message from the stream
      final data = await stream.read();
      if (data.isNotEmpty) {
        final message = utf8.decode(data).trim();
        // Display the received message
        print('\n📨 [${_truncatePeerId(remotePeer)} says]: $message');
        stdout.write('> ');
      }
    } catch (e) {
      print('Error reading from chat stream from ${_truncatePeerId(remotePeer)}: $e');
    } finally {
      // Close the stream when done
      await stream.close();
    }
  }

  /// Send a message to the currently selected peer
  Future<bool> sendMessage(String message) async {
    if (_currentPeer == null) {
      print('❌ No peer selected. Use "select <number>" to choose a peer.');
      return false;
    }
    
    final peer = discoveredPeers[_currentPeer!];
    if (peer == null) {
      print('❌ Selected peer is no longer available.');
      _currentPeer = null;
      return false;
    }
    
    try {
      // Connect to the peer if we're not already connected
      if (host.network.connectedness(_currentPeer!) != Connectedness.connected) {
        await host.connect(peer);
      }
      
      final ctx = Context();
      final stream = await host.newStream(_currentPeer!, [protocolId], ctx);
      await stream.write(utf8.encode(message + '\n'));
      await stream.close();
      
      // Show our own message
      print('📤 [You → ${_truncatePeerId(_currentPeer!)}]: $message');
      return true;
    } catch (e) {
      print('❌ Error sending message to ${_truncatePeerId(_currentPeer!)}: $e');
      return false;
    }
  }

  /// Process a command from user input
  Future<bool> processCommand(String input) async {
    final parts = input.trim().split(' ');
    final command = parts[0].toLowerCase();
    
    switch (command) {
      case 'list':
        showPeerList();
        return true;
        
      case 'select':
        if (parts.length != 2) {
          print('❌ Usage: select <number>');
          return true;
        }
        final index = int.tryParse(parts[1]);
        if (index == null) {
          print('❌ Please provide a valid number.');
          return true;
        }
        selectPeer(index);
        return true;
        
      case 'quit' || 'exit':
        return false;
        
      case 'help' || '?':
        _showHelp();
        return true;
        
      default:
        // Not a command, treat as message
        if (_currentPeer == null) {
          print('❌ No peer selected. Use "select <number>" to choose a peer first.');
          return true;
        }
        await sendMessage(input);
        return true;
    }
  }

  void _showHelp() {
    print('''
📚 Available commands:
  list         - Show discovered peers
  select <n>   - Select peer number <n> for chatting
  help or ?    - Show this help message
  quit or exit - Exit the application
  
💬 To send a message, just type it and press Enter (after selecting a peer).
''');
  }

  /// Get current status summary
  String getStatus() {
    final peersCount = discoveredPeers.length;
    final currentPeerName = _currentPeer != null ? _truncatePeerId(_currentPeer!) : 'none';
    return 'Peers: $peersCount | Selected: $currentPeerName';
  }

  // Helper function to truncate peer IDs for display
  String _truncatePeerId(PeerId peerId, [int length = 6]) {
    return peerId.toBase58().substring(0, length);
  }
}
