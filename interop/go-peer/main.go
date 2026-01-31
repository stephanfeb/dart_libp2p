package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/core/protocol"
	"github.com/libp2p/go-libp2p/p2p/security/noise"
	yamux "github.com/libp2p/go-libp2p/p2p/muxer/yamux"
	"github.com/libp2p/go-libp2p/p2p/transport/tcp"
	"github.com/multiformats/go-multiaddr"
)

const echoProtocol = "/echo/1.0.0"

func main() {
	mode := flag.String("mode", "server", "Mode: server, client, ping, echo-server, echo-client, push-test")
	port := flag.Int("port", 0, "Listen port (0 for random)")
	target := flag.String("target", "", "Target multiaddr for client/ping modes")
	message := flag.String("message", "hello from go-libp2p", "Message to send in echo-client mode")
	flag.Parse()

	switch *mode {
	case "server":
		runServer(*port)
	case "client":
		runClient(*target)
	case "ping":
		runPing(*target)
	case "echo-server":
		runEchoServer(*port)
	case "echo-client":
		runEchoClient(*target, *message)
	case "push-test":
		runPushTest(*target)
	default:
		fmt.Fprintf(os.Stderr, "Unknown mode: %s\n", *mode)
		os.Exit(1)
	}
}

func createHost(port int) (host.Host, error) {
	priv, _, err := crypto.GenerateEd25519Key(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generate key: %w", err)
	}

	return libp2p.New(
		libp2p.Identity(priv),
		libp2p.ListenAddrStrings(fmt.Sprintf("/ip4/0.0.0.0/tcp/%d", port)),
		libp2p.Transport(tcp.NewTCPTransport),
		libp2p.Security(noise.ID, noise.New),
		libp2p.Muxer("/yamux/1.0.0", yamux.DefaultTransport),
		libp2p.DisableRelay(),
	)
}

func printHostInfo(h host.Host) {
	fmt.Printf("PeerID: %s\n", h.ID())
	for _, addr := range h.Addrs() {
		fmt.Printf("Listening: %s/p2p/%s\n", addr, h.ID())
	}
	fmt.Println("Ready")
}

func parseTarget(targetStr string) (*peer.AddrInfo, error) {
	maddr, err := multiaddr.NewMultiaddr(targetStr)
	if err != nil {
		return nil, fmt.Errorf("parse multiaddr: %w", err)
	}
	return peer.AddrInfoFromP2pAddr(maddr)
}

func waitForShutdown() {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	<-ch
	fmt.Println("Shutting down")
}

// server mode: listen and accept connections, handle ping and identify automatically
func runServer(port int) {
	h, err := createHost(port)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	defer h.Close()

	printHostInfo(h)

	// Also handle echo protocol
	h.SetStreamHandler(protocol.ID(echoProtocol), func(s network.Stream) {
		defer s.Close()
		buf := make([]byte, 64*1024)
		for {
			n, err := s.Read(buf)
			if err != nil {
				if err != io.EOF {
					fmt.Fprintf(os.Stderr, "Echo read error: %v\n", err)
				}
				return
			}
			if _, err := s.Write(buf[:n]); err != nil {
				fmt.Fprintf(os.Stderr, "Echo write error: %v\n", err)
				return
			}
		}
	})

	// Listen for commands on stdin
	go func() {
		scanner := bufio.NewScanner(os.Stdin)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "quit" || line == "exit" {
				os.Exit(0)
			}
		}
	}()

	waitForShutdown()
}

// client mode: connect to target peer
func runClient(targetStr string) {
	if targetStr == "" {
		fmt.Fprintln(os.Stderr, "Error: --target required")
		os.Exit(1)
	}

	h, err := createHost(0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	defer h.Close()

	info, err := parseTarget(targetStr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := h.Connect(ctx, *info); err != nil {
		fmt.Fprintf(os.Stderr, "Connection failed: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Connected: %s\n", info.ID)
}

// ping mode: connect and send pings
func runPing(targetStr string) {
	if targetStr == "" {
		fmt.Fprintln(os.Stderr, "Error: --target required")
		os.Exit(1)
	}

	h, err := createHost(0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	defer h.Close()

	info, err := parseTarget(targetStr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := h.Connect(ctx, *info); err != nil {
		fmt.Fprintf(os.Stderr, "Connection failed: %v\n", err)
		os.Exit(1)
	}

	// Use the built-in ping protocol
	s, err := h.NewStream(ctx, info.ID, "/ipfs/ping/1.0.0")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Ping stream failed: %v\n", err)
		os.Exit(1)
	}
	defer s.Close()

	pingData := make([]byte, 32)
	rand.Read(pingData)

	start := time.Now()
	if _, err := s.Write(pingData); err != nil {
		fmt.Fprintf(os.Stderr, "Ping write failed: %v\n", err)
		os.Exit(1)
	}

	resp := make([]byte, 32)
	if _, err := io.ReadFull(s, resp); err != nil {
		fmt.Fprintf(os.Stderr, "Ping read failed: %v\n", err)
		os.Exit(1)
	}
	rtt := time.Since(start)

	match := true
	for i := range pingData {
		if pingData[i] != resp[i] {
			match = false
			break
		}
	}

	if match {
		fmt.Printf("Ping successful: rtt=%v\n", rtt)
	} else {
		fmt.Fprintln(os.Stderr, "Ping failed: data mismatch")
		os.Exit(1)
	}
}

// echo-server mode: listen and echo data back
func runEchoServer(port int) {
	h, err := createHost(port)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	defer h.Close()

	h.SetStreamHandler(protocol.ID(echoProtocol), func(s network.Stream) {
		defer s.Close()
		buf := make([]byte, 64*1024)
		for {
			n, err := s.Read(buf)
			if err != nil {
				if err != io.EOF {
					fmt.Fprintf(os.Stderr, "Echo read error: %v\n", err)
				}
				return
			}
			fmt.Printf("Echo: received %d bytes\n", n)
			if _, err := s.Write(buf[:n]); err != nil {
				fmt.Fprintf(os.Stderr, "Echo write error: %v\n", err)
				return
			}
		}
	})

	printHostInfo(h)
	waitForShutdown()
}

// push-test mode: connect to target, wait for identify, then register a new
// protocol handler to trigger an identify push notification to the remote peer.
func runPushTest(targetStr string) {
	if targetStr == "" {
		fmt.Fprintln(os.Stderr, "Error: --target required")
		os.Exit(1)
	}

	h, err := createHost(0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	defer h.Close()

	info, err := parseTarget(targetStr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := h.Connect(ctx, *info); err != nil {
		fmt.Fprintf(os.Stderr, "Connection failed: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("PeerID: %s\n", h.ID())
	fmt.Println("Connected")

	// Wait for identify to complete
	time.Sleep(2 * time.Second)

	// Register a new protocol handler — this triggers identify push
	const pushTestProto = "/test/push-verify/1.0.0"
	h.SetStreamHandler(protocol.ID(pushTestProto), func(s network.Stream) {
		s.Close()
	})
	fmt.Printf("Registered protocol: %s\n", pushTestProto)

	// Give the push time to propagate
	time.Sleep(3 * time.Second)
	fmt.Println("Push test complete")
}

// echo-client mode: connect and send a message
func runEchoClient(targetStr, message string) {
	if targetStr == "" {
		fmt.Fprintln(os.Stderr, "Error: --target required")
		os.Exit(1)
	}

	h, err := createHost(0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	defer h.Close()

	info, err := parseTarget(targetStr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := h.Connect(ctx, *info); err != nil {
		fmt.Fprintf(os.Stderr, "Connection failed: %v\n", err)
		os.Exit(1)
	}

	s, err := h.NewStream(ctx, info.ID, protocol.ID(echoProtocol))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Stream failed: %v\n", err)
		os.Exit(1)
	}
	defer s.Close()

	data := []byte(message)
	if _, err := s.Write(data); err != nil {
		fmt.Fprintf(os.Stderr, "Write failed: %v\n", err)
		os.Exit(1)
	}
	s.CloseWrite()

	resp, err := io.ReadAll(s)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Read failed: %v\n", err)
		os.Exit(1)
	}

	if string(resp) == message {
		fmt.Printf("Echo successful: %q\n", string(resp))
	} else {
		fmt.Fprintf(os.Stderr, "Echo mismatch: sent %q, got %q\n", message, string(resp))
		os.Exit(1)
	}
}
