#!/bin/bash
# Runs the cone-to-cone DCUtR scenario over UDX and reports whether peer A
# ended up with a direct (non-relayed) connection to peer B.
#
# usage: scripts/run_dcutr_scenario.sh [--go] [output-dir]
#
#   default  peer-a and peer-b are Dart, relay is Dart (compose/docker-compose.yml)
#   --go     peer-a is Dart, peer-b and the relay are go-libp2p
#            (compose/docker-compose.go.yml)
#
# Run from anywhere; needs Docker with Compose v2. Exit status is 0 only when
# a direct connection was established. Container logs, NAT packet captures and
# the control API responses are written to the output directory.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
COMPOSE=$HERE/compose/docker-compose.yml
PROJECT=holepunch
if [ "${1:-}" = "--go" ]; then
  COMPOSE=$HERE/compose/docker-compose.go.yml
  PROJECT=holepunch-go
  shift
fi
OUT=${1:-$(mktemp -d -t dcutr-scenario)}
mkdir -p "$OUT"
DC="docker compose -p $PROJECT -f $COMPOSE"

json() { python3 -c "import sys,json; d=json.loads(sys.argv[1]); print($1)" "$2"; }

# Calls a peer's control API from inside its container. Through the
# published host port (8081/8082), Docker Desktop sometimes never delivered
# the requests to a peer on two networks, and the run failed with "peers did
# not come up" (dart-libp2p-1pg).
#   api <container> <timeout-seconds> <method> <path> [json-body]
api() {
  local c=$1 t=$2 m=$3 path=$4
  if [ $# -ge 5 ]; then
    docker exec "$c" curl -s -m "$t" -X "$m" "localhost:8080$path" -d "$5"
  else
    docker exec "$c" curl -s -m "$t" -X "$m" "localhost:8080$path"
  fi
}
status() {
  for _ in $(seq 1 40); do
    r=$(api "$1" 5 GET /status 2>/dev/null) && [[ "$r" == *peer_id* ]] && { echo "$r"; return; }
    sleep 3
  done
}

cleanup() { $DC down -v --remove-orphans >/dev/null 2>&1; }
collect_logs() {
  for c in peer-a peer-b relay-server nat-gateway-a nat-gateway-b; do docker logs $c >"$OUT/$c.log" 2>&1; done
}
trap 'collect_logs; cleanup' EXIT

echo "Building and starting containers ($PROJECT)..."
cleanup
$DC up -d --build >"$OUT/compose-up.log" 2>&1 || { echo "compose up failed, see $OUT/compose-up.log"; exit 2; }

A=$(status peer-a); B=$(status peer-b)
[ -n "$A" ] && [ -n "$B" ] || { echo "peers did not come up"; exit 2; }
sleep 10 # let the NAT gateways and relay connections settle
AID=$(json 'd["peer_id"]' "$A"); BID=$(json 'd["peer_id"]' "$B")
echo "peer-a $AID"; echo "peer-b $BID"

# Reserve on the relay and introduce each peer to the other with its
# external address and circuit address.
RA=$(api peer-a 30 POST /reserve); RB=$(api peer-b 30 POST /reserve)
echo "reserve A: $RA" >"$OUT/reserve.txt"; echo "reserve B: $RB" >>"$OUT/reserve.txt"
addrs() { python3 -c 'import sys,json; s=json.loads(sys.argv[1]); r=json.loads(sys.argv[2]); print(json.dumps([a for a in s["addresses"] if "p2p-circuit" not in a] + [r["circuit"]]))' "$1" "$2"; }
AADDRS=$(addrs "$A" "$RA"); BADDRS=$(addrs "$B" "$RB")
api peer-a 30 POST /connect "{\"peer_id\":\"$BID\",\"addrs\":$BADDRS}" >/dev/null
api peer-b 30 POST /connect "{\"peer_id\":\"$AID\",\"addrs\":$AADDRS}" >/dev/null 2>&1 || true

for g in a b; do
  docker exec -d nat-gateway-$g sh -c "timeout 60 tcpdump -n -i any -w /tmp/dcutr.pcap udp and not port 3478 2>/dev/null"
done
sleep 1

# A relayed ping opens the relayed connection. A go-libp2p peer-b starts
# DCUtR on its own when it accepts it; for Dart peers, A starts it.
echo "ping over relay: $(api peer-a 20 POST /ping "{\"peer_id\":\"$BID\"}" | cut -c1-120)"
if [ "$PROJECT" = "holepunch" ]; then
  echo "holepunch: $(api peer-a 45 POST /holepunch "{\"peer_id\":\"$BID\"}" | cut -c1-200)"
fi
sleep 25

CONNS=$(api peer-a 5 GET /conns)
echo "$CONNS" >"$OUT/peer-a-conns.json"
for g in a b; do docker exec nat-gateway-$g sh -c "tcpdump -n -r /tmp/dcutr.pcap 2>/dev/null" >"$OUT/nat-gateway-$g.pcap.txt" 2>/dev/null; done

DIRECT=$(python3 -c 'import sys,json; print("\n".join(c["remote_addr"] for c in json.loads(sys.argv[1]) if c["peer_id"]==sys.argv[2] and not c["relayed"]))' "$CONNS" "$BID")
echo "logs: $OUT"
if [ -n "$DIRECT" ]; then
  echo "PASS: direct connection to peer-b via $DIRECT"
  exit 0
fi
echo "FAIL: no direct connection to peer-b (connections: $CONNS)"
exit 1
