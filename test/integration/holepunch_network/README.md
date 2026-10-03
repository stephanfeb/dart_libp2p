# Holepunch Network Integration Tests

This directory contains comprehensive integration tests for the dart-libp2p holepunch (DCUtR) functionality using real Docker containers to simulate various network topologies and NAT behaviors.

## 🏗️ Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                    TEST ORCHESTRATOR                                 │
│                    (Dart Test Suite)                                 │
│               Uses localhost:808x for control APIs                   │
└──────────────────────────────────────────────────────────────────────┘
                          │ HTTP Control API
                          ▼ (host port mappings: 8081, 8082, 8083)
┌──────────────────────────────────────────────────────────────────────┐
│                  CONTAINER NETWORK TOPOLOGY                          │
│                        (4 Isolated Docker Networks)                  │
│                                                                      │
│  PUBLIC NETWORK (100.70.0.0/16) - Relay, STUN, NAT Gateways          │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐             │
│  │   NAT-A     │    │ RELAY SERVER│    │   NAT-B     │             │
│  │ 100.70.1.10  │    │ 100.70.3.10  │    │ 100.70.1.20  │             │
│  │ (Gateway)   │    └─────┬───────┘    │ (Gateway)   │             │
│  └─────┬───────┘          │            └─────┬───────┘             │
│        │                  │                  │                      │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐             │
│  │ STUN SERVER │    │             │    │             │             │
│  │ 100.70.2.10  │    │             │    │             │             │
│  └─────────────┘    │             │    │             │             │
│                     │             │    │             │             │
│  PRIVATE NETWORK A (192.168.1.0/24) - Isolated                      │
│  ┌──────────────────┴─────────┐   │    │             │             │
│  │        PEER-A              │   │    │             │             │
│  │     192.168.1.100          │   │    │             │             │
│  │  (NAT-isolated from B)     │   │    │             │             │
│  └────────────────────────────┘   │    │             │             │
│                                    │    │             │             │
│  PRIVATE NETWORK B (192.168.2.0/24) - Isolated                      │
│  ┌────────────────────────────────┴────┴─────────┐                 │
│  │                  PEER-B                       │                 │
│  │               192.168.2.100                   │                 │
│  │          (NAT-isolated from A)                │                 │
│  └───────────────────────────────────────────────┘                 │
│                                                                      │
│  CONTROL NETWORK (172.25.0.0/16) - Test Orchestration Only          │
│  ┌──────────────────────────────────────────────────────┐           │
│  │  RELAY: 172.25.0.12   PEER-A: 172.25.0.10           │           │
│  │                       PEER-B: 172.25.0.11           │           │
│  │  (HTTP Control APIs bound to this network)          │           │
│  └──────────────────────────────────────────────────────┘           │
└──────────────────────────────────────────────────────────────────────┘

Key:  
- :XXXX→:YYYY = Host port XXXX mapped to container port YYYY
- Peers are ISOLATED from public_net - cannot reach each other directly
- All libp2p traffic goes through NAT gateways
- Control API uses separate control_net for test orchestration
```

## 🧩 Components

### NAT Gateways
- **Cone NAT**: Same external port for all destinations, allows inbound to mapped ports
- **Symmetric NAT**: Different external ports per destination, strict filtering
- **Port-Restricted NAT**: Same external port but port-dependent filtering

### Infrastructure Services  
- **STUN Server**: **INTERNAL** address discovery (coturn-based at 100.70.2.10:3478)
- **Relay Server**: Circuit relay for initial connectivity
- **Control APIs**: HTTP endpoints for test coordination (exposed via host port mappings)

### 🔒 **Network Isolation & NAT Enforcement**
- **No External STUN**: Uses internal STUN server (100.70.2.10:3478), NOT stun.google.com
- **True NAT Isolation**: Peers ONLY have access to their private networks + control_net
- **No Direct Peer-to-Peer**: Peers cannot reach each other directly - must use NAT traversal
- **Separate Control Network**: Test orchestration uses dedicated control_net (172.25.0.0/16)
- **libp2p Traffic Isolation**: All libp2p communication goes through NAT gateways
- **Host Port Mappings**: Control APIs exposed on host ports 8081-8083 for test orchestration only
- **Deterministic Results**: Tests are immune to external services and enforce realistic NAT scenarios

### 🏠 **Local Network Adaptations**
This test setup simulates real-world NAT scenarios within a local Docker environment. Key adaptations:

1. **Simulated public addresses**: the "internet" is `100.70.0.0/16` (carrier-grade NAT space, never routed on the real internet). RFC 1918 ranges such as `10.0.0.0/8` would not work: `MultiAddr.isPublic()` rejects them, so DCUtR would have no addresses to exchange.
2. **Operator-supplied external addresses**: each peer is told its NAT gateway's public address through `EXTERNAL_ADDRS` (added to `host.addrs` with an `addrsFactory`). The cone NAT keeps the source port, so the UDX listener's port 4001 maps to port 4001 on the gateway.
3. **Interface detection**: Docker does not guarantee interface order, so the NAT gateway finds its internal interface by `INTERNAL_SUBNET` and treats the other as external.
4. **Relay reservation via `/reserve`**: peers reserve on the relay through the control API, because AutoRelay does not yet pick the relay up on its own (beads `dart-libp2p-52c`).
5. **Host-Mapped Control APIs**: Test orchestration requires host port mappings to coordinate scenarios.
6. **Container Warmup Time**: Infrastructure needs 15-20 seconds to establish NAT rules and relay connections on cold starts.

### Test Scenarios
- **Cone-to-Cone**: Should succeed with direct holepunch
- **Symmetric-to-Symmetric**: Should fail but maintain relay connectivity  
- **Mixed NAT Types**: Should handle gracefully with fallback

## 🚀 Prerequisites

### System Requirements
- Docker & Docker Compose installed
- Minimum 4GB RAM available for containers
- Network permissions for container management
- Dart SDK 3.0+ for running tests

### Docker Installation
```bash
# Install Docker (Ubuntu/Debian)
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Install Docker Compose
sudo apt-get install docker-compose-plugin

# Add user to docker group (logout/login required)
sudo usermod -aG docker $USER
```

## 🎬 Usage

### Running Tests

#### Basic Integration Test
```bash
# From dart-libp2p root directory
dart test test/integration/holepunch_network/holepunch_network_integration_test.dart
```

#### Run Specific Scenario
```bash
dart test test/integration/holepunch_network/holepunch_network_integration_test.dart --plain-name "Cone-to-Cone"
```

#### With Custom Configuration
```bash
# Copy environment template
cp test/integration/holepunch_network/compose/environment-example.txt test/integration/holepunch_network/compose/.env

# Edit .env file to configure NAT types
export NAT_A_TYPE=cone
export NAT_B_TYPE=symmetric

dart test test/integration/holepunch_network/holepunch_network_integration_test.dart
```

### DCUtR Scenario Script (UDX, cone-to-cone)

`scripts/run_dcutr_scenario.sh` builds the containers, reserves both peers on the relay, opens a relayed connection from peer-a to peer-b, runs DCUtR and checks whether peer-a ends up with a **direct (non-`/p2p-circuit`) connection** to peer-b. It exits 0 only in that case, and writes container logs, the NAT gateways' UDP packet captures and the control API responses to an output directory.

```bash
# Dart <-> Dart (compose/docker-compose.yml)
test/integration/holepunch_network/scripts/run_dcutr_scenario.sh /tmp/dcutr-dart

# Dart <-> go-libp2p, with a go-libp2p relay (compose/docker-compose.go.yml)
test/integration/holepunch_network/scripts/run_dcutr_scenario.sh --go /tmp/dcutr-go
```

The go variant uses `11.70.0.0/16` as its simulated internet, because go-libp2p only hole punches from addresses it considers public and treats `100.64.0.0/10` as private. Its relay is go-libp2p because go clients cannot yet reserve on a Dart relay (beads `dart-libp2p-6qi`).

Peer containers accept `DEBUG_LOGGERS` (comma-separated logger names, e.g. `p2p-holepunch,UDXTransport`) to raise those loggers to `ALL`, and expose `GET /conns` listing every connection with a `relayed` flag.

**Known issue:** the direct connection does not yet form. The remote's punch packet reaches the local NAT about a second before the local punch dial leaves, so the NAT has already used the 4001↔4001 mapping and rewrites the local source port (visible in `nat-gateway-*.pcap.txt`). Tracked in beads `dart-libp2p-021`.

### Manual Container Management

#### Start Infrastructure
```bash
cd test/integration/holepunch_network/compose
docker-compose up -d
```

#### Monitor Logs
```bash
# All services
docker-compose logs -f

# Specific service
docker-compose logs -f peer-a
docker-compose logs -f nat-gateway-a
```

#### Test Control APIs
```bash
# Get peer status (using host port mappings)
curl http://localhost:8081/status  # peer-a
curl http://localhost:8082/status  # peer-b
curl http://localhost:8083/status  # relay-server

# Initiate holepunch from peer-a to peer-b
curl -X POST http://localhost:8081/holepunch \
  -H "Content-Type: application/json" \
  -d '{"peer_id": "PEER_B_ID_HERE"}'

# Connect peers before holepunch (required)
curl -X POST http://localhost:8081/connect \
  -H "Content-Type: application/json" \
  -d '{"peer_id": "PEER_B_ID", "addrs": ["PEER_B_ADDRS"]}'
```

#### Clean Up
```bash
docker-compose down -v --remove-orphans
```

## 🔧 Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NAT_A_TYPE` | `cone` | NAT type for gateway A: `cone`, `symmetric`, `port-restricted` |
| `NAT_B_TYPE` | `cone` | NAT type for gateway B |
| `DEBUG_PACKETS` | `false` | Enable tcpdump packet capture |
| `VERBOSE_LOGGING` | `false` | Enable detailed logging |
| `PEER_STARTUP_TIMEOUT` | `30` | Peer startup timeout (seconds) |
| `HOLEPUNCH_TIMEOUT` | `60` | Holepunch attempt timeout (seconds) |

### Port Mappings (Fixed)

| Container | Host Port | Container Port | Control Network IP | Purpose |
|-----------|-----------|----------------|-------------------|---------|
| `peer-a` | 8081 | 8080 | 172.25.0.10 | Control API for test orchestration |
| `peer-b` | 8082 | 8080 | 172.25.0.11 | Control API for test orchestration |
| `relay-server` | 8083 | 8080 | 172.25.0.12 | Control API for test orchestration |

**Note**: Control APIs bind to the control_net (172.25.0.0/16) which is separate from libp2p traffic networks. This ensures:
- Test orchestrator can coordinate scenarios via HTTP
- Peers remain isolated from each other for libp2p traffic
- NAT traversal is properly enforced

### NAT Types Explained

#### Cone NAT
- **Mapping**: Same external port for all destinations
- **Filtering**: Allows inbound from any source to mapped port
- **Holepunch**: ✅ Compatible (with other cone NATs)

#### Symmetric NAT  
- **Mapping**: Different external port per destination
- **Filtering**: Only allows exact connection tuple matches
- **Holepunch**: ❌ Not compatible

#### Port-Restricted NAT
- **Mapping**: Same external port for all destinations  
- **Filtering**: Only allows inbound from contacted IP:port pairs
- **Holepunch**: ⚠️  Limited compatibility

## 🧪 Test Scenarios

### Cone-to-Cone Success
```bash
export NAT_A_TYPE=cone NAT_B_TYPE=cone
dart test --plain-name "Cone-to-Cone"
```
**Expected Result**: Direct holepunch succeeds, peers connect directly

### Symmetric Failure
```bash  
export NAT_A_TYPE=symmetric NAT_B_TYPE=symmetric
dart test --plain-name "Symmetric-to-Symmetric"
```
**Expected Result**: Holepunch fails gracefully, relay connectivity maintained

### Mixed NAT Handling
```bash
export NAT_A_TYPE=cone NAT_B_TYPE=symmetric  
dart test --plain-name "Mixed NAT"
```
**Expected Result**: Holepunch fails, graceful fallback to relay

## 🔍 Debugging

### Container Logs
```bash
# NAT gateway iptables rules
docker exec nat-gateway-a iptables -t nat -L -n -v

# Peer connectivity
docker exec peer-a netstat -tuln
docker exec peer-a ip route show

# STUN server
docker logs stun-server
```

### Network Analysis
```bash
# Enable packet capture (set DEBUG_PACKETS=true)
docker exec nat-gateway-a tcpdump -i any -w /tmp/nat-traffic.pcap

# Copy packet capture for analysis
docker cp nat-gateway-a:/tmp/nat-traffic.pcap ./nat-traffic.pcap
```

### Manual Testing
```bash
# Connect to peer container
docker exec -it peer-a bash

# Test connectivity
nc -zv relay-server 4001
nc -zv stun-server 3478
```

## ⏰ **Infrastructure Timing & Test Behavior**

### Test Execution Patterns

#### **Standalone Test Failures vs. Suite Successes**
A common pattern: individual cone-to-cone tests fail, but the same scenario passes in the complete suite. **Root Cause**: Infrastructure warmup timing.

- **Standalone Test (Often Fails)**:
  1. Fresh orchestrator start from cold state
  2. 10-second warmup insufficient for NAT rules + relay connections
  3. Holepunch attempts before infrastructure is ready

- **Suite Test (Usually Passes)**:
  1. Infrastructure already warmed by previous scenarios  
  2. NAT gateways, STUN discovery, and relay connections established
  3. Holepunch succeeds on stable infrastructure

#### **Warmup Timing Requirements**
- **Fresh Infrastructure**: Requires 15-20 seconds for complete initialization
- **Established Infrastructure**: Only needs 5-10 seconds between scenarios
- **NAT Gateway Setup**: ~5-8 seconds for iptables rules to take effect
- **Relay Connection Discovery**: ~10-15 seconds for circuit establishment

### **Timing Best Practices**
1. **Run Complete Suite**: More reliable than individual tests
2. **Allow Extra Warmup**: If running standalone tests, increase delays in scenario setup
3. **Check Container Logs**: Monitor startup progression if tests timeout
4. **Sequential Execution**: Use `--concurrency=1` to avoid resource contention

## 🐛 Troubleshooting

### Common Issues

#### Docker Permission Denied
```bash
sudo usermod -aG docker $USER
# Logout and login again
```

#### Port Conflicts
```bash
# Find conflicting processes
sudo netstat -tulpn | grep :3478
sudo netstat -tulpn | grep :4001

# Or use different ports in docker-compose.yml
```

#### Container Startup Failures
```bash
# Check Docker daemon
sudo systemctl status docker

# Check available resources
docker system df
docker system prune
```

#### NAT Rules Not Applied
```bash
# Verify privileged containers
docker inspect nat-gateway-a | grep Privileged

# Check iptables support
docker run --rm --privileged alpine iptables -t nat -L
```

### Test Failures

#### Infrastructure Setup Failure
- Verify Docker is running and accessible
- Check available disk space and memory
- Ensure no port conflicts

#### Scenario Timeout
- Increase timeout values in environment
- Check container resource limits
- Monitor container logs during execution

#### Holepunch Failure (Unexpected)
- **Check Infrastructure Timing**: Most failures are due to insufficient warmup time
- **Verify Relay Connections**: Ensure peers can connect via relay first (`/connect` endpoint)
- **NAT Gateway Status**: Verify iptables rules are applied (`docker exec nat-gateway-a iptables -t nat -L`)
- **Peer Discovery**: Check that peers have discovered each other's addresses
- **Container Resource Limits**: Ensure adequate CPU/memory for all containers

#### Standalone Test Fails, Suite Passes
This indicates infrastructure timing issues:
1. **Solution**: Run the complete test suite instead of individual scenarios
2. **Debug**: Check container startup logs for slow initialization
3. **Workaround**: Increase warmup delays in `ConeToConeSucessScenario.setup()` from 10 to 20+ seconds

#### "Container orchestrator is already started" Errors
- **Cause**: Test harness attempting to start orchestrator multiple times
- **Solution**: Ensure proper `setUp`/`tearDown` methods in test groups
- **Fixed**: Integration tests now include proper orchestrator lifecycle management

## 📊 Performance Considerations

### Resource Usage
- Each test scenario uses 6+ containers
- RAM usage: ~1-2GB total  
- Startup time: 30-60 seconds per scenario (15-20s for infrastructure warmup)
- Test duration: 2-5 minutes per scenario

### Optimization Tips
- Use `docker system prune` between test runs
- Increase Docker daemon memory limits if needed
- Run tests sequentially (`--concurrency=1`) to avoid resource contention
- Consider using faster storage (SSD) for better performance
- **Run complete suite rather than individual tests** for better reliability

## 🔧 **Local Network Testing Implementation**

### Public Address Simulation
The library has no testing fallback for public addresses. Peers get their public address from `EXTERNAL_ADDRS` (see Local Network Adaptations), which is how an operator would configure a host behind a NAT with a known port mapping.

### Why This Works
- **NAT Simulation**: Docker NAT gateways simulate real NAT behavior using iptables
- **Address Discovery**: STUN server helps peers discover their "external" (NAT gateway) addresses
- **Relay Bootstrap**: Circuit relay provides initial connectivity for holepunch coordination
- **Direct Connection**: Once holepunch succeeds, peers connect directly through NAT mappings

### Limitations of Local Testing
- **No Real Internet Connectivity**: Cannot test true public internet scenarios
- **Docker Network Constraints**: Limited to Docker's networking capabilities  
- **Timing Dependencies**: More sensitive to infrastructure warmup than real networks
- **Resource Contention**: All containers share host resources

## 🤝 Contributing

### Adding New Scenarios
1. Create scenario class in `scenarios/holepunch_scenarios.dart`
2. Extend `HolePunchScenario` base class
3. Implement `setup()`, `execute()`, and `teardown()` methods
4. Add test case to `holepunch_network_integration_test.dart`

### Adding New NAT Types  
1. Create setup script in `containers/nat-gateway/scripts/`
2. Add case to `containers/nat-gateway/entrypoint.sh`
3. Update docker-compose.yml build args
4. Document behavior in this README

### Container Modifications
- Modify Dockerfiles in `containers/` directory
- Update docker-compose.yml service definitions
- Test changes with `docker-compose build --no-cache`

## 📚 References

- [libp2p DCUtR Specification](https://github.com/libp2p/specs/blob/master/relay/DCUtR.md)
- [NAT Traversal Techniques](https://tools.ietf.org/html/rfc5128)
- [STUN Protocol](https://tools.ietf.org/html/rfc5389)
- [Docker Compose Networking](https://docs.docker.com/compose/networking/)
- [Testcontainers Documentation](https://www.testcontainers.org/)
