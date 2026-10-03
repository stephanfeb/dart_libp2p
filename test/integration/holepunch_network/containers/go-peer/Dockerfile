# go-libp2p DCUtR peer / circuit relay v2 for the holepunch harness.
# Build context is the parent of dart-libp2p (the go-udx and
# go-libp2p-udx-transport checkouts sit next to it), as for dart-peer.
FROM golang:1.25 AS build
WORKDIR /src
COPY go-udx/ go-udx/
COPY go-libp2p-udx-transport/ go-libp2p-udx-transport/
COPY dart-libp2p/test/integration/holepunch_network/containers/go-peer/ gopeer/
WORKDIR /src/gopeer
RUN go mod tidy && CGO_ENABLED=0 go build -o /dcutr-peer .

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y iproute2 curl && rm -rf /var/lib/apt/lists/*
COPY --from=build /dcutr-peer /dcutr-peer
# Peers route the public net through their NAT gateway; the relay has no
# NAT_GATEWAY and skips the route.
ENTRYPOINT ["/bin/sh", "-c", "[ -n \"$NAT_GATEWAY\" ] && ip route add $PUBLIC_NET_SUBNET via $NAT_GATEWAY; exec /dcutr-peer"]
