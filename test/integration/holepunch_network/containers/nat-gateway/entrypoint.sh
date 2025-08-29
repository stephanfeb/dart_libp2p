#!/bin/bash
set -e

echo "Starting NAT Gateway (Type: ${NAT_TYPE})"

# Apply sysctl settings
sysctl -p

# Wait for network interfaces to be available
sleep 2

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

# Start packet capture for debugging (optional)
if [ "${DEBUG_PACKETS}" = "true" ]; then
    echo "Starting packet capture..."
    tcpdump -i any -w /tmp/nat-traffic.pcap &
fi

# Display final iptables configuration
echo "Final iptables NAT rules:"
iptables -t nat -L -n -v

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
