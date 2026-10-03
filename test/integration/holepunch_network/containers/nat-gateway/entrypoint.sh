#!/bin/bash
set -e

echo "Starting NAT Gateway (Type: ${NAT_TYPE})"

# Check if we're in debug mode (simplified networking)
if [ "${DEBUG_MODE}" = "true" ]; then
    echo "🐛 DEBUG MODE: Skipping NAT configuration - running as simple router"
    echo "   This mode is for testing container startup without complex networking"
    echo "   External Interface: ${EXTERNAL_INTERFACE:-eth0}"
    echo "   Internal Interface: ${INTERNAL_INTERFACE:-eth1}" 
    echo "   Internal Subnet: ${INTERNAL_SUBNET:-192.168.1.0/24}"
else
    # Apply sysctl settings
    sysctl -p

    # Wait for network interfaces to be available
    sleep 2

    # Docker does not guarantee interface order, so find the internal
    # interface by INTERNAL_SUBNET (assumed /24) and take the other one as
    # external. With the two swapped, MASQUERADE never matches and packets
    # leave with their private source address.
    INTERNAL_PREFIX="${INTERNAL_SUBNET%.*}."
    DETECTED_INTERNAL=$(ip -o -4 addr show | awk -v p="$INTERNAL_PREFIX" 'index($4, p) == 1 {print $2; exit}')
    DETECTED_EXTERNAL=$(ip -o -4 addr show | awk -v i="$DETECTED_INTERNAL" '$2 ~ /^eth/ && $2 != i {print $2; exit}')
    if [ -n "$DETECTED_INTERNAL" ] && [ -n "$DETECTED_EXTERNAL" ]; then
        export INTERNAL_INTERFACE="$DETECTED_INTERNAL"
        export EXTERNAL_INTERFACE="$DETECTED_EXTERNAL"
    fi
    echo "Internal interface: ${INTERNAL_INTERFACE} (${INTERNAL_SUBNET}), external interface: ${EXTERNAL_INTERFACE}"

    # Simulated WAN latency on the way out. Docker's bridge has almost none,
    # so one peer's punch packet would always reach the other NAT before
    # that peer's own punch leaves it; the NAT then records the inbound flow
    # and gives the outbound punch a different port. DCUtR's timing assumes
    # a real one-way delay; set WAN_DELAY=0 to disable.
    WAN_DELAY=${WAN_DELAY:-50ms}
    if [ "$WAN_DELAY" != "0" ]; then
        tc qdisc add dev "$EXTERNAL_INTERFACE" root netem delay "$WAN_DELAY" \
            && echo "WAN delay: $WAN_DELAY on $EXTERNAL_INTERFACE" \
            || echo "⚠️  Could not add WAN delay (netem unavailable?)"
    fi

    # Configure NAT rules based on NAT_TYPE
    case "${NAT_TYPE}" in
        "cone")
            echo "Configuring Cone NAT behavior..."
            /usr/local/bin/setup-cone-nat.sh
            ;;
        "symmetric")  
            echo "Configuring Symmetric NAT behavior..."
            /usr/local/bin/setup-symmetric-nat.sh
            ;;
        "port-restricted")
            echo "Configuring Port-Restricted NAT behavior..."
            /usr/local/bin/setup-port-restricted-nat.sh
            ;;
        *)
            echo "Unknown NAT_TYPE: ${NAT_TYPE}"
            exit 1
            ;;
    esac
fi

# Start packet capture for debugging (optional)
if [ "${DEBUG_PACKETS}" = "true" ]; then
    echo "Starting packet capture..."
    tcpdump -i any -w /tmp/nat-traffic.pcap &
fi

# Display final iptables configuration (only if not in debug mode)
if [ "${DEBUG_MODE}" != "true" ]; then
    echo "Final iptables NAT rules:"
    iptables -t nat -L -n -v
    
    echo ""
    echo "Final iptables FILTER rules (FORWARD chain):"
    iptables -L FORWARD -n -v --line-numbers
    
    echo ""
    echo "Full filter table:"
    iptables -L -n -v
fi

echo "✅ NAT Gateway ready - keeping container alive..."

# Keep container running and handle signals
trap 'echo "🛑 Shutting down NAT Gateway..."; exit 0' TERM INT

# Tail logs or keep alive
if [ -f /var/log/nat-gateway.log ]; then
    tail -f /var/log/nat-gateway.log &
fi

while true; do
    sleep 30
done
