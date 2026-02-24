#!/bin/bash
set -e

echo "Starting Ricochet server (production binary, UDX transport)"

PORT=${LISTEN_PORT:-55223}
PG_HOST=${PG_HOST:-10.10.2.10}
PG_PORT=${PG_PORT:-5432}
PG_DB=${PG_DB:-ricochet_test}
PG_USER=${PG_USER:-ricochet}
PG_PASS=${PG_PASS:-ricochet_test}
EXTERNAL_IP=${EXTERNAL_IP:-10.10.3.10}

echo "Listen port: ${PORT}"
echo "PostgreSQL: ${PG_HOST}:${PG_PORT}/${PG_DB}"

# Apply netem on THIS container's interface for guaranteed network degradation.
if [ -n "$NETEM_DELAY" ] && [ "$NETEM_DELAY" != "0ms" -o "$NETEM_LOSS" != "0%" ]; then
    echo "Applying netem on eth0: delay=${NETEM_DELAY} jitter=${NETEM_JITTER:-0ms} loss=${NETEM_LOSS:-0%}"
    tc qdisc add dev eth0 root netem \
        delay ${NETEM_DELAY} ${NETEM_JITTER:-0ms} \
        loss ${NETEM_LOSS:-0%}
    echo "Netem active:"
    tc qdisc show dev eth0
fi

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL..."
TIMEOUT=30
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    if pg_isready -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
        echo "PostgreSQL is ready"
        break
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "ERROR: Timed out waiting for PostgreSQL"
    exit 1
fi

# Create a FIFO to capture output while extracting PeerID
mkfifo /tmp/server-output

# Start ricochet-server
/opt/ricochet/ricochet_server \
    --development \
    --port ${PORT} \
    --data-dir /var/lib/ricochet/sf_storage \
    --pg-host ${PG_HOST} \
    --pg-port ${PG_PORT} \
    --pg-database ${PG_DB} \
    --pg-username ${PG_USER} \
    --pg-password ${PG_PASS} \
    --pg-sslmode disable \
    --external-addrs /ip4/${EXTERNAL_IP}/udp/${PORT}/udx \
    --debug-dht \
    > /tmp/server-output 2>&1 &
SERVER_PID=$!

# Read from the FIFO, display output, and extract PeerID
(while IFS= read -r line; do
    echo "$line"
    # Match: "Ricochet server running. Peer ID: <id>"
    if echo "$line" | grep -q "Peer ID:"; then
        PEER_ID=$(echo "$line" | sed 's/.*Peer ID: *//')
        echo "$PEER_ID" > /shared/peer_id
        echo "Wrote PeerID to /shared/peer_id: $PEER_ID" >&2
    fi
done < /tmp/server-output) &
READER_PID=$!

# Wait for PeerID to be written
TIMEOUT=60
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    if [ -f /shared/peer_id ] && [ -s /shared/peer_id ]; then
        echo "Ricochet server ready. PeerID: $(cat /shared/peer_id)"
        break
    fi
    # Check if server exited unexpectedly
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo "ERROR: ricochet-server exited unexpectedly"
        wait $SERVER_PID
        exit 1
    fi
    sleep 0.5
    ELAPSED=$((ELAPSED + 1))
done

if [ ! -f /shared/peer_id ]; then
    echo "ERROR: Timed out waiting for Ricochet server to start"
    exit 1
fi

# Keep container alive — wait for server to exit
trap 'echo "Shutting down Ricochet server..."; kill $SERVER_PID 2>/dev/null; exit 0' TERM INT
wait $SERVER_PID
