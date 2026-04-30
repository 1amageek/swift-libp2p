package main

import (
	"fmt"
	"log"
	"os"
	"strconv"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/p2p/security/noise"
	"github.com/libp2p/go-libp2p/p2p/transport/tcp"
	"github.com/libp2p/go-libp2p/p2p/muxer/yamux"
	"github.com/multiformats/go-multiaddr"
)

func main() {
	// Get port from environment
	portStr := os.Getenv("LISTEN_PORT")
	if portStr == "" {
		portStr = "4001"
	}
	port, err := strconv.Atoi(portStr)
	if err != nil {
		log.Fatalf("Invalid port: %v", err)
	}

	// Create a new libp2p host with TCP transport and Noise security
	h, err := libp2p.New(
		libp2p.ListenAddrStrings(
			fmt.Sprintf("/ip4/0.0.0.0/tcp/%d", port),
		),
		// Disable QUIC, use only TCP
		libp2p.NoTransports,
		libp2p.Transport(tcp.NewTCPTransport),
		// Use Noise for security
		libp2p.Security(noise.ID, noise.New),
		// Use Yamux for muxing
		libp2p.Muxer("/yamux/1.0.0", yamux.DefaultTransport),
		libp2p.Ping(true), // Enable ping protocol
	)
	if err != nil {
		log.Fatalf("Failed to create host: %v", err)
	}
	defer h.Close()

	// Get the host's peer ID
	peerID := h.ID()
	log.Printf("Local peer id: %s", peerID.String())
	log.Printf("Transport: TCP")
	log.Printf("Security: Noise")
	log.Printf("Muxer: Yamux")

	// Print listen addresses
	for _, addr := range h.Addrs() {
		fullAddr := addr.Encapsulate(multiaddr.StringCast("/p2p/" + peerID.String()))
		fmt.Printf("Listen: %s\n", fullAddr.String())
	}
	fmt.Println("Ready to accept connections")

	// Set up stream handler for custom protocols
	h.SetStreamHandler("/test/echo/1.0.0", func(s network.Stream) {
		log.Printf("Received stream from %s", s.Conn().RemotePeer())
		defer s.Close()

		// Echo back whatever is received
		buf := make([]byte, 1024)
		for {
			n, err := s.Read(buf)
			if err != nil {
				return
			}
			if n > 0 {
				log.Printf("Echo: %d bytes", n)
				s.Write(buf[:n])
			}
		}
	})

	// Keep the process running
	select {}
}
