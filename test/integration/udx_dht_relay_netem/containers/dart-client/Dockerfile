# Dart client for DHT + relay netem test
# Build context must be the agentic/ root directory to include path dependencies

FROM dart:3.6

# Install system dependencies
RUN apt-get update && apt-get install -y \
    iproute2 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy dart-libp2p project
COPY dart-libp2p/ ./

# Copy sibling path dependencies (matching mobile app's pubspec.yaml)
COPY dart-udx/ ../dart-udx/
COPY dart-libp2p-kad-dht/ ../dart-libp2p-kad-dht/

# Override dependency_overrides to use local path for both dart_udx and dart_libp2p_kad_dht
# Remove existing dependency_overrides section and append our own
RUN sed -i '/^dependency_overrides:/,$ d' pubspec.yaml && \
    printf '\ndependency_overrides:\n  dart_udx:\n    path: ../dart-udx\n  dart_libp2p_kad_dht:\n    path: ../dart-libp2p-kad-dht\n' >> pubspec.yaml

# Install dependencies
RUN dart pub get

# Compile the netem test binary
RUN dart compile exe bin/dht_relay_netem_test.dart -o /app/test_binary

# Copy entrypoint script
COPY dart-libp2p/test/integration/udx_dht_relay_netem/containers/dart-client/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
