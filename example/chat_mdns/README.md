# mDNS P2P Chat Example

This advanced example demonstrates a peer-to-peer chat application with **automatic peer discovery** using mDNS (Multicast DNS). Unlike the basic chat example, this version can discover and chat with multiple peers on your local network without needing to know their addresses beforehand.

## What This Example Demonstrates

- **mDNS Peer Discovery**: Automatically discover other chat instances on the local network
- **Multi-Peer Support**: Chat with multiple discovered peers
- **Interactive Commands**: Select peers, list available peers, send messages
- **Real-World Networking**: Uses actual network discovery mechanisms
- **Robust Connection Management**: Handles peer connections and discovery gracefully

## How It Works

1. **Host Creation**: Creates a libp2p host with UDX transport and Noise security
2. **mDNS Advertising**: Advertises itself on the network as a chat peer
3. **mDNS Discovery**: Listens for other chat peers advertising on the network
4. **Peer Selection**: Allows you to choose which discovered peer to chat with
5. **Message Exchange**: Sends messages to selected peers using the `/chat/1.0.0` protocol

## Running the Example

### Single Instance

From the project root directory:

```bash
dart run example/chat_mdns/main.dart
```

### Multiple Instances (Recommended!)

To see mDNS discovery in action, run multiple instances:

**Terminal 1:**
```bash
dart run example/chat_mdns/main.dart
```

**Terminal 2:**
```bash
dart run example/chat_mdns/main.dart
```

**Different Machine:**
```bash
# On another computer on the same network
dart run example/chat_mdns/main.dart
```

## Expected Output

```
🚀 Starting mDNS P2P Chat Example
This example uses mDNS to discover chat peers on your local network.

🏠 Your chat host: [12D3Ko]
📡 Listening on: [/ip4/127.0.0.1/udp/54321/udx]

📡 mDNS discovery started - advertising and looking for chat peers...
🔍 Searching for other chat peers on your network...
📢 Other chat apps on this network should discover you automatically.

--- mDNS P2P Chat Session ---
Commands:
  list         - Show discovered peers
  select <n>   - Select peer number for chatting
  help or ?    - Show help
  quit         - Exit

💡 Tip: Run this program on multiple devices/terminals to see peer discovery in action!
-----------------------------

🔍 Discovered new chat peer: [QmAbCd]

📋 Available chat peers:
   1. [QmAbCd] - /ip4/127.0.0.1/udp/12345/udx

💡 Type "select <number>" to choose a peer to chat with.
💡 Type "list" to see available peers.
📊 Status: Peers: 1 | Selected: none
> select 1
✅ Selected peer [QmAbCd] for chatting.
📊 Status: Peers: 1 | Selected: QmAbCd
> Hello from mDNS chat!
📤 [You → QmAbCd]: Hello from mDNS chat!
📊 Status: Peers: 1 | Selected: QmAbCd
> 
```

## Available Commands

| Command | Description |
|---------|-------------|
| `list` | Show all discovered peers |
| `select <n>` | Select peer number `n` for chatting |
| `help` or `?` | Show help message |
| `quit` or `exit` | Exit the application |
| Any other text | Send as message to selected peer |

## Key Features

### Automatic Peer Discovery

- **mDNS Broadcasting**: Each instance advertises itself using mDNS
- **mDNS Listening**: Discovers other chat instances automatically
- **Real-Time Updates**: New peers appear as they join the network

### Multi-Peer Support

- **Peer List**: Shows all discovered peers with truncated IDs
- **Peer Selection**: Choose which peer to send messages to
- **Dynamic Discovery**: New peers can join anytime

### Interactive Interface

- **Status Display**: Shows number of discovered peers and currently selected peer
- **Command Processing**: Handles various user commands
- **Message Display**: Shows incoming messages with sender identification

## Network Requirements

- **Same Network**: All peers must be on the same local network (WiFi/Ethernet)
- **Multicast Support**: Network must allow multicast traffic (most home networks do)
- **Firewall**: May need to allow UDP traffic on random ports

## Troubleshooting

### No Peers Discovered

- Make sure all instances are on the same network
- Check that multicast/mDNS is allowed by your network
- Try running on the same machine first (different terminals)

### Connection Errors

- Firewall may be blocking UDP connections
- Some corporate networks block peer-to-peer traffic
- Try running as administrator/root if needed

## Architecture Highlights

### ChatClientMdns Class

The enhanced chat client provides:

- **MdnsNotifee Interface**: Receives notifications when peers are discovered
- **Peer Management**: Tracks discovered peers and manages connections
- **Command Processing**: Handles user commands and message sending
- **Multi-Peer Support**: Can chat with any discovered peer

### mDNS Integration

- **Service Advertising**: Announces chat service availability
- **Service Discovery**: Finds other chat services on the network
- **Namespace**: Uses `'dart-libp2p-chat'` namespace for chat peers
- **Address Embedding**: Includes peer IDs in advertised addresses

## Comparison with Basic Chat

| Feature | Basic Chat | mDNS Chat |
|---------|------------|-----------|
| Peer Discovery | Manual (hardcoded addresses) | Automatic (mDNS) |
| Number of Peers | 2 only | Multiple |
| Network Setup | Requires known addresses | Zero configuration |
| Real-World Usage | Limited | Production-ready |
| User Interface | Simple | Interactive commands |

This mDNS chat example represents a much more realistic peer-to-peer application that could be deployed in real-world scenarios!
