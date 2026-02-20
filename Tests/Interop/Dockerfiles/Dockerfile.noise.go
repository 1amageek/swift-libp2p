# Dockerfile for go-libp2p Noise-only test node
#
# This creates a go-libp2p node that uses TCP + Noise
# specifically for testing Noise protocol handshake.

FROM golang:1.23-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache git

# Initialize Go module
RUN go mod init go-libp2p-noise-test

# Add dependencies
RUN go get github.com/libp2p/go-libp2p@v0.36
RUN go get github.com/libp2p/go-libp2p/p2p/security/noise@v0.36
RUN go get github.com/libp2p/go-libp2p/p2p/transport/tcp@v0.36
RUN go get github.com/libp2p/go-libp2p/p2p/muxer/yamux@v0.36

# Create the test server
RUN cat > main.go << 'EOF'
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

	// Create a new libp2p host with TCP + Noise (no TLS)
	h, err := libp2p.New(
		libp2p.ListenAddrStrings(
			fmt.Sprintf("/ip4/0.0.0.0/tcp/%d", port),
		),
		// Disable default transports
		libp2p.NoTransports,
		libp2p.Transport(tcp.NewTCPTransport),
		// Noise only - no TLS
		libp2p.Security(noise.ID, noise.New),
		// Yamux muxer
		libp2p.Muxer("/yamux/1.0.0", yamux.DefaultTransport),
		libp2p.Ping(true),
	)
	if err != nil {
		log.Fatalf("Failed to create host: %v", err)
	}
	defer h.Close()

	peerID := h.ID()
	log.Printf("Local peer id: %s", peerID.String())
	log.Printf("Security: Noise (XX pattern)")

	// Print listen addresses
	for _, addr := range h.Addrs() {
		fullAddr := addr.Encapsulate(multiaddr.StringCast("/p2p/" + peerID.String()))
		fmt.Printf("Listen: %s\n", fullAddr.String())
	}
	fmt.Println("Ready to accept connections")

	// Echo handler for testing encrypted communication
	h.SetStreamHandler("/test/echo/1.0.0", func(s network.Stream) {
		log.Printf("Received encrypted stream from %s", s.Conn().RemotePeer())
		defer s.Close()

		buf := make([]byte, 1024)
		for {
			n, err := s.Read(buf)
			if err != nil {
				return
			}
			if n > 0 {
				log.Printf("Echo (encrypted): %d bytes", n)
				s.Write(buf[:n])
			}
		}
	})

	select {}
}
EOF

# Build the application
RUN go build -o go-libp2p-noise-test main.go

# Final image
FROM alpine:3.19

COPY --from=builder /app/go-libp2p-noise-test /usr/local/bin/go-libp2p-noise-test

EXPOSE 4001/tcp

ENTRYPOINT ["/usr/local/bin/go-libp2p-noise-test"]
