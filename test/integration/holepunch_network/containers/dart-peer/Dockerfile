FROM dart:3.2

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    netcat-traditional \
    iproute2 \
    tcpdump \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy the entire dart-libp2p project
COPY . .

# Install dependencies
RUN dart pub get

# Compile the integration test peer application
RUN dart compile exe test/integration/holepunch_network/containers/dart-peer/peer_main.dart -o /app/peer

# Create config directory
RUN mkdir -p /app/config

# Copy peer configuration
COPY test/integration/holepunch_network/containers/dart-peer/config/ /app/config/

# Expose common libp2p ports
EXPOSE 4001 4002

# Set executable permissions
RUN chmod +x /app/peer

# Copy entrypoint script
COPY test/integration/holepunch_network/containers/dart-peer/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
