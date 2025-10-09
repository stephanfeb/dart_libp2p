#!/bin/bash
set -e

echo "🚀 Starting Dart LibP2P Peer Container"
echo "   Role: ${PEER_ROLE:-peer}"
echo "   Name: ${PEER_NAME:-unknown}" 
echo "   Listen Addrs: ${LISTEN_ADDRS:-/ip4/0.0.0.0/tcp/4001}"

# Wait for network dependencies to be ready
if [ -n "$NAT_GATEWAY" ]; then
    echo "⏳ Waiting for NAT gateway at $NAT_GATEWAY..."
    timeout 30 bash -c "until nc -z $NAT_GATEWAY 22 2>/dev/null; do sleep 1; done" || echo "Warning: NAT gateway check timed out"
fi

if [ -n "$RELAY_SERVERS" ]; then
    echo "⏳ Checking relay server connectivity..."
    # Parse first relay server for connectivity check
    FIRST_RELAY=$(echo $RELAY_SERVERS | cut -d',' -f1 | grep -oP '(?<=/ip4/)[^/]+')
    if [ -n "$FIRST_RELAY" ]; then
        timeout 10 bash -c "until nc -z $FIRST_RELAY 4001 2>/dev/null; do sleep 1; done" || echo "Warning: Relay server check timed out"
    fi
fi

# Configure routing for NAT traversal
if [ -n "$PUBLIC_NET_SUBNET" ] && [ -n "$NAT_GATEWAY" ]; then
    echo "🔀 Configuring route to $PUBLIC_NET_SUBNET via NAT gateway $NAT_GATEWAY..."
    ip route add $PUBLIC_NET_SUBNET via $NAT_GATEWAY || echo "⚠️  Route already exists or failed to add"
fi

# Show network configuration
echo "📡 Network Configuration:"
echo "   Hostname: $(hostname)"
echo "   IP Addresses:"
ip addr show | grep "inet " | sed 's/^/     /'

echo "   Routing Table:"
ip route show | sed 's/^/     /'

# Start the peer application
echo "🎬 Starting peer application..."
exec /app/peer
