# Multi-stage Go build for the DHT + relay server
# Build context must be the agentic/ root directory to include path dependencies

FROM golang:1.24 AS builder

WORKDIR /build

# Copy Go UDX transport and its dependency (path deps in go.mod)
COPY go-udx/ ./go-udx/
COPY go-libp2p-udx-transport/ ./go-libp2p-udx-transport/

# Copy the Go peer application
COPY dart-libp2p/interop/go-peer/ ./go-peer/

WORKDIR /build/go-peer

# Fixup go.mod replace directives for Docker build context layout
# In-repo: ../../../go-udx → Docker: ../../go-udx
RUN sed -i 's|=> ../../../go-libp2p-udx-transport|=> ../go-libp2p-udx-transport|' go.mod && \
    sed -i 's|=> ../../../go-udx|=> ../go-udx|' go.mod

RUN go mod download
RUN CGO_ENABLED=0 go build -o /go-peer .

# Runtime image
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y iproute2 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /go-peer /usr/local/bin/go-peer
COPY dart-libp2p/test/integration/udx_dht_relay_netem/containers/go-server/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 4001/udp

ENTRYPOINT ["/entrypoint.sh"]
