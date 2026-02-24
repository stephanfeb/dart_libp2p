#!/bin/bash
set -e

echo "Starting Dart DHT + Relay netem test client"

# Configure routing through NAT gateway to reach public network
if [ -n "$PUBLIC_NET_SUBNET" ] && [ -n "$NAT_GATEWAY" ]; then
    echo "Configuring route to $PUBLIC_NET_SUBNET via NAT gateway $NAT_GATEWAY..."
    ip route add $PUBLIC_NET_SUBNET via $NAT_GATEWAY || echo "Route already exists or failed to add"
    # Delete Docker's default route to prevent traffic from bypassing NAT gateway
    # This forces ALL external traffic through our NAT gateway (matching mobile production behavior)
    ip route del default 2>/dev/null || true
fi

# Apply netem on THIS container's interface for guaranteed network degradation.
# Docker's bridge routing can bypass the nat-gateway container's network stack,
# so we apply netem directly on the endpoints to ensure it actually affects traffic.
# This delays all EGRESS (dart→go) — combined with netem on go-server (go→dart egress),
# we get true bidirectional network degradation.
if [ -n "$NETEM_DELAY" ] && [ "$NETEM_DELAY" != "0ms" -o "$NETEM_LOSS" != "0%" ]; then
    echo "Applying netem on eth0: delay=${NETEM_DELAY} jitter=${NETEM_JITTER:-0ms} loss=${NETEM_LOSS:-0%}"
    tc qdisc add dev eth0 root netem \
        delay ${NETEM_DELAY} ${NETEM_JITTER:-0ms} \
        loss ${NETEM_LOSS:-0%}
    echo "Netem active:"
    tc qdisc show dev eth0
fi

# Show network configuration
echo "Network Configuration:"
echo "  Hostname: $(hostname)"
echo "  IP Addresses:"
ip addr show | grep "inet " | sed 's/^/     /'
echo "  Routing Table:"
ip route show | sed 's/^/     /'

# Read Go server peer ID from shared volume
GO_SERVER_ADDR=${GO_SERVER_ADDR:-10.10.3.10}
GO_SERVER_PORT=${GO_SERVER_PORT:-4001}

echo "Waiting for Go server peer ID..."
TIMEOUT=60
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    if [ -f /shared/peer_id ] && [ -s /shared/peer_id ]; then
        GO_PEER_ID=$(cat /shared/peer_id)
        echo "Go server PeerID: $GO_PEER_ID"
        break
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

if [ -z "$GO_PEER_ID" ]; then
    echo "ERROR: Timed out waiting for Go server peer ID"
    exit 1
fi

# Construct the full multiaddr
TARGET_ADDR="/ip4/${GO_SERVER_ADDR}/udp/${GO_SERVER_PORT}/udx/p2p/${GO_PEER_ID}"
echo "Target: $TARGET_ADDR"

# Run the test
echo "Starting test..."
exec /app/test_binary "$TARGET_ADDR" "${TEST_WAIT_SECS:-15}"
