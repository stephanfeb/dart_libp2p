#!/bin/bash
set -e

echo "Starting Go DHT + Relay server (UDX transport)"

# Write yamux config from env vars
KEEPALIVE=${YAMUX_KEEPALIVE_INTERVAL:-3}
WRITE_TIMEOUT=${YAMUX_WRITE_TIMEOUT:-10}
PORT=${LISTEN_PORT:-4001}

cat > /tmp/yamux_config.yaml << EOF
yamux:
  keepalive_interval: ${KEEPALIVE}
  connection_write_timeout: ${WRITE_TIMEOUT}
EOF

echo "Yamux config: keepalive=${KEEPALIVE}s, write_timeout=${WRITE_TIMEOUT}s"
echo "Listen port: ${PORT}"

# Apply netem on THIS container's interface for guaranteed network degradation.
# Docker's bridge routing can bypass the nat-gateway container's network stack,
# so we apply netem directly on the endpoints to ensure it actually affects traffic.
# This delays all EGRESS (go→dart) — combined with netem on dart-client (dart→go egress),
# we get true bidirectional network degradation.
if [ -n "$NETEM_DELAY" ] && [ "$NETEM_DELAY" != "0ms" -o "$NETEM_LOSS" != "0%" ]; then
    echo "Applying netem on eth0: delay=${NETEM_DELAY} jitter=${NETEM_JITTER:-0ms} loss=${NETEM_LOSS:-0%}"
    tc qdisc add dev eth0 root netem \
        delay ${NETEM_DELAY} ${NETEM_JITTER:-0ms} \
        loss ${NETEM_LOSS:-0%}
    echo "Netem active:"
    tc qdisc show dev eth0
fi

# Create a FIFO to capture go-peer output while also extracting PeerID
mkfifo /tmp/go-peer-output

# Start go-peer with output going to the FIFO
go-peer --mode=dht-relay-server --transport=udx --port=${PORT} --config=/tmp/yamux_config.yaml > /tmp/go-peer-output 2>&1 &
GO_PID=$!

# Read from the FIFO, display output, and extract PeerID
(while IFS= read -r line; do
    echo "$line"
    if echo "$line" | grep -q "^PeerID:"; then
        PEER_ID=$(echo "$line" | sed 's/PeerID: *//')
        echo "$PEER_ID" > /shared/peer_id
        echo "Wrote PeerID to /shared/peer_id: $PEER_ID" >&2
    fi
done < /tmp/go-peer-output) &
READER_PID=$!

# Wait for PeerID to be written
TIMEOUT=30
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    if [ -f /shared/peer_id ] && [ -s /shared/peer_id ]; then
        echo "Go server ready. PeerID: $(cat /shared/peer_id)"
        break
    fi
    # Check if go-peer exited unexpectedly
    if ! kill -0 $GO_PID 2>/dev/null; then
        echo "ERROR: go-peer exited unexpectedly"
        wait $GO_PID
        exit 1
    fi
    sleep 0.5
    ELAPSED=$((ELAPSED + 1))
done

if [ ! -f /shared/peer_id ]; then
    echo "ERROR: Timed out waiting for Go peer to start"
    exit 1
fi

# Keep container alive — wait for go-peer to exit
trap 'echo "Shutting down Go server..."; kill $GO_PID 2>/dev/null; exit 0' TERM INT
wait $GO_PID
