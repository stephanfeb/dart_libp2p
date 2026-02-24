#!/bin/bash
# Convenience runner for the DHT + Relay netem reproduction test.
#
# Usage:
#   ./run_test.sh [profile]
#
# Profiles:
#   baseline    - No network degradation (sanity check)
#   good-4g     - 40ms delay, 10ms jitter, 0.5% loss
#   poor-4g     - 150ms delay, 40ms jitter, 1% loss (default)
#   terrible    - 300ms delay, 80ms jitter, 5% loss
#
# Environment variable overrides:
#   NETEM_DELAY, NETEM_JITTER, NETEM_LOSS - Direct netem params
#   TEST_WAIT_SECS - How long to wait during idle phase (default: 15)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/compose/docker-compose.yml"

PROFILE=${1:-poor-4g}

case $PROFILE in
  baseline)
    DELAY=0ms    JITTER=0ms   LOSS=0%   ;;
  good-4g)
    DELAY=40ms   JITTER=10ms  LOSS=0.5% ;;
  poor-4g)
    DELAY=150ms  JITTER=40ms  LOSS=1%   ;;
  terrible)
    DELAY=300ms  JITTER=80ms  LOSS=5%   ;;
  *)
    echo "Unknown profile: $PROFILE"
    echo "Available: baseline, good-4g, poor-4g, terrible"
    exit 1
    ;;
esac

# Allow env var overrides
NETEM_DELAY=${NETEM_DELAY:-$DELAY}
NETEM_JITTER=${NETEM_JITTER:-$JITTER}
NETEM_LOSS=${NETEM_LOSS:-$LOSS}

echo "=== DHT + Relay Netem Reproduction Test ==="
echo "Profile: $PROFILE"
echo "Netem: delay=${NETEM_DELAY}, jitter=${NETEM_JITTER}, loss=${NETEM_LOSS}"
echo "Wait: ${TEST_WAIT_SECS:-15}s"
echo ""

# Build and run
export NETEM_DELAY NETEM_JITTER NETEM_LOSS

docker compose -f "${COMPOSE_FILE}" up --build --abort-on-container-exit
EXIT_CODE=$?

echo ""
echo "=== Post-Test Analysis ==="

# Check Go server logs for the production failure signature
echo "Go server 'i/o deadline' errors:"
docker logs go-server 2>&1 | grep -c "i/o deadline" || echo "  (none)"

echo "Go server stream-open failures:"
docker logs go-server 2>&1 | grep "failed to open stream" || echo "  (none)"

echo "Go server context deadline errors:"
docker logs go-server 2>&1 | grep "context deadline exceeded" || echo "  (none)"

echo ""
echo "Dart client exit code: $(docker inspect dart-client --format='{{.State.ExitCode}}' 2>/dev/null || echo 'unknown')"

# Cleanup
docker compose -f "${COMPOSE_FILE}" down -v

exit $EXIT_CODE
