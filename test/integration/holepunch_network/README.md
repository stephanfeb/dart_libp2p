# Holepunch Network Integration Tests

This directory contains comprehensive integration tests for the dart-libp2p holepunch (DCUtR) functionality using real Docker containers to simulate various network topologies and NAT behaviors.

## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    TEST ORCHESTRATOR                            │
│                    (Dart Test Suite)                            │
└─────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                  CONTAINER NETWORK TOPOLOGY                     │
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐          │
│  │   NAT-A     │    │ RELAY SERVER│    │   NAT-B     │          │
│  │ (Gateway)   │    │ (Public IP) │    │ (Gateway)   │          │
│  └─────────────┘    └─────────────┘    └─────────────┘          │
│         │                  │                  │                 │
│         ▼                  │                  ▼                 │
│  ┌─────────────┐           │           ┌─────────────┐          │
│  │   PEER-A    │           │           │   PEER-B    │          │
│  │ (Behind NAT)│ ◄─────────┼─────────► │ (Behind NAT)│          │
│  └─────────────┘           │           └─────────────┘          │
│                            │                                    │
│                      ┌─────────────┐                            │
│                      │ STUN SERVER │                            │
│                      │ (External)  │                            │
│                      └─────────────┘                            │
└─────────────────────────────────────────────────────────────────┘
```

## 🧩 Components

### NAT Gateways
- **Cone NAT**: Same external port for all destinations, allows inbound to mapped ports
- **Symmetric NAT**: Different external ports per destination, strict filtering
- **Port-Restricted NAT**: Same external port but port-dependent filtering

### Infrastructure Services  
- **STUN Server**: **INTERNAL** address discovery (coturn-based at 10.10.2.10:3478)
- **Relay Server**: Circuit relay for initial connectivity
- **Control APIs**: HTTP endpoints for test coordination

### 🔒 **Perfect Network Isolation**
- **Zero External Dependencies**: All services use internal container addresses only
- **No External STUN**: Uses internal STUN server (10.10.2.10:3478), NOT stun.google.com
- **No Host Port Mappings**: Containers communicate only via internal Docker networks
- **Deterministic Results**: Tests are immune to host network configuration or external services

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
# Get peer status
curl http://$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' peer-a):8080/status

# Initiate holepunch
curl -X POST http://$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' peer-a):8080/holepunch \
  -H "Content-Type: application/json" \
  -d '{"peer_id": "PEER_B_ID_HERE"}'
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
- Verify NAT gateway configuration
- Check peer control API responses  
- Analyze packet captures if enabled

## 📊 Performance Considerations

### Resource Usage
- Each test scenario uses 6+ containers
- RAM usage: ~1-2GB total
- Startup time: 30-60 seconds per scenario
- Test duration: 2-5 minutes per scenario

### Optimization Tips
- Use `docker system prune` between test runs
- Increase Docker daemon memory limits if needed
- Run tests sequentially to avoid resource contention
- Consider using faster storage (SSD) for better performance

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
