#!/bin/bash
set -e

echo "Starting NAT Gateway"
echo "  NAT Type: ${NAT_TYPE:-cone}"

# Apply sysctl settings
sysctl -p

# Wait for network interfaces to be available
sleep 2

EXTERNAL_IF=${EXTERNAL_INTERFACE:-eth0}
INTERNAL_IF=${INTERNAL_INTERFACE:-eth1}
INTERNAL_SUBNET=${INTERNAL_SUBNET:-192.168.1.0/24}

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
        echo "Unknown NAT_TYPE: ${NAT_TYPE}, defaulting to cone"
        /usr/local/bin/setup-cone-nat.sh
        ;;
esac

# NOTE: netem is applied directly on the endpoint containers (dart-client, go-server)
# rather than here, because Docker's bridge routing can bypass this container's
# network stack entirely. The NAT gateway still handles iptables MASQUERADE.

# Display final iptables configuration
echo "Final iptables NAT rules:"
iptables -t nat -L -n -v

echo ""
echo "Final iptables FILTER rules (FORWARD chain):"
iptables -L FORWARD -n -v --line-numbers

# Write ready marker for healthcheck
touch /tmp/gateway-ready

echo "NAT Gateway ready — keeping container alive..."

# Keep container running and handle signals
trap 'echo "Shutting down NAT Gateway..."; exit 0' TERM INT

while true; do
    sleep 30
done
