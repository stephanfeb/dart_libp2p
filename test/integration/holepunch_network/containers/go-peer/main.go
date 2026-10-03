// go-libp2p side of the holepunch harness (compose/docker-compose.go.yml).
//
// With ROLE=relay it runs a circuit relay v2 with a fixed identity. Otherwise
// it is a DCUtR peer behind a NAT: it reserves on the relay, advertises
// EXTERNAL_ADDRS, and starts DCUtR itself when it accepts a relayed
// connection, as go-libp2p does. Either way it serves a small control API on
// CONTROL_BIND_IP:8080 compatible with scripts/run_dcutr_scenario.sh.
package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/p2p/net/connmgr"
	relayv2client "github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/client"
	relayv2 "github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/relay"
	"github.com/libp2p/go-libp2p/p2p/protocol/holepunch"
	"github.com/libp2p/go-libp2p/p2p/security/noise"
	"github.com/libp2p/go-libp2p/p2p/transport/tcp"
	ma "github.com/multiformats/go-multiaddr"
	udxtransport "github.com/stephanfeb/go-libp2p-udx-transport"
)

type tracer struct{}

func (tracer) Trace(e *holepunch.Event) {
	b, _ := json.Marshal(e.Evt)
	fmt.Printf("DCUTR-EVENT %s remote=%s %s\n", e.Type, e.Remote, b)
}

// runRelay serves circuit relay v2. The key is derived from a fixed seed so
// the relay's peer ID (12D3KooWKZA9C2aY5vhvmNGHapv4aXXKUHTz3TpQGhmGNwRgQh9P)
// can be configured in RELAY_SERVERS.
func runRelay() {
	seed := make([]byte, 32)
	copy(seed, []byte("dart-libp2p-dcutr-scratch-relay"))
	priv, _, _ := crypto.GenerateEd25519Key(bytesReader(seed))
	h, err := libp2p.New(libp2p.Identity(priv), libp2p.ListenAddrStrings("/ip4/0.0.0.0/tcp/4001"),
		libp2p.Security(noise.ID, noise.New), libp2p.Transport(tcp.NewTCPTransport), libp2p.ForceReachabilityPublic())
	if err != nil {
		panic(err)
	}
	if _, err := relayv2.New(h); err != nil {
		panic(err)
	}
	fmt.Println("RELAY PeerID:", h.ID())
	http.HandleFunc("/status", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"peer_id": h.ID().String()})
	})
	panic(http.ListenAndServe(os.Getenv("CONTROL_BIND_IP")+":8080", nil))
}

type fixedReader struct{ b []byte }

func (r *fixedReader) Read(p []byte) (int, error) { n := copy(p, r.b); r.b = r.b[n:]; return n, nil }
func bytesReader(b []byte) *fixedReader         { return &fixedReader{b: append([]byte{}, b...)} }

func main() {
	if os.Getenv("ROLE") == "relay" {
		runRelay()
		return
	}
	listenUDX := os.Getenv("LISTEN_UDX")       // e.g. /ip4/192.168.2.100/udp/4001/udx
	external := os.Getenv("EXTERNAL_ADDRS")    // e.g. /ip4/11.70.1.20/udp/4001/udx
	relayStr := strings.Split(os.Getenv("RELAY_SERVERS"), ",")[0]

	priv, _, _ := crypto.GenerateEd25519Key(rand.Reader)
	var extAddrs []ma.Multiaddr
	for _, s := range strings.Split(external, ",") {
		if s = strings.TrimSpace(s); s != "" {
			extAddrs = append(extAddrs, ma.StringCast(s))
		}
	}
	cm, _ := connmgr.NewConnManager(10, 100)
	h, err := libp2p.New(
		libp2p.Identity(priv),
		libp2p.Security(noise.ID, noise.New),
		libp2p.Transport(tcp.NewTCPTransport),
		libp2p.Transport(udxtransport.NewTransport),
		libp2p.ListenAddrStrings(listenUDX),
		libp2p.EnableRelay(),
		libp2p.EnableHolePunching(holepunch.WithTracer(tracer{})),
		libp2p.ConnectionManager(cm),
		libp2p.AddrsFactory(func(addrs []ma.Multiaddr) []ma.Multiaddr { return append(addrs, extAddrs...) }),
	)
	if err != nil {
		panic(err)
	}
	fmt.Println("PeerID:", h.ID())

	h.Network().Notify(&network.NotifyBundle{
		ConnectedF: func(_ network.Network, c network.Conn) {
			fmt.Printf("CONN-OPEN %s dir=%s remote=%s limited=%v\n", c.RemotePeer(), c.Stat().Direction, c.RemoteMultiaddr(), c.Stat().Limited)
		},
		DisconnectedF: func(_ network.Network, c network.Conn) {
			fmt.Printf("CONN-CLOSE %s remote=%s\n", c.RemotePeer(), c.RemoteMultiaddr())
		},
	})

	relayMA := ma.StringCast(relayStr)
	relayInfo, _ := peer.AddrInfoFromP2pAddr(relayMA)
	var circuit string
	for i := 0; ; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		err = h.Connect(ctx, *relayInfo)
		if err == nil {
			_, err = relayv2client.Reserve(ctx, h, *relayInfo)
		}
		cancel()
		if err == nil {
			break
		}
		fmt.Println("relay connect/reserve failed, retrying:", err)
		time.Sleep(2 * time.Second)
	}
	circuit = fmt.Sprintf("%s/p2p-circuit/p2p/%s", relayMA, h.ID())
	fmt.Println("RESERVE ok circuit=", circuit)

	http.HandleFunc("/status", func(w http.ResponseWriter, _ *http.Request) {
		var addrs []string
		for _, a := range h.Addrs() {
			addrs = append(addrs, a.String())
		}
		json.NewEncoder(w).Encode(map[string]any{"peer_id": h.ID().String(), "addresses": addrs})
	})
	http.HandleFunc("/reserve", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"success": true, "circuit": circuit})
	})
	http.HandleFunc("/conns", func(w http.ResponseWriter, _ *http.Request) {
		var out []string
		for _, c := range h.Network().Conns() {
			out = append(out, fmt.Sprintf("%s %s", c.RemotePeer(), c.RemoteMultiaddr()))
		}
		json.NewEncoder(w).Encode(out)
	})
	panic(http.ListenAndServe(os.Getenv("CONTROL_BIND_IP")+":8080", nil))
}
