# Dockerfile for go-libp2p test node
#
# This creates a simple go-libp2p node that listens on QUIC
# and supports Identify and Ping protocols.

FROM golang:1.23-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache git

# Initialize Go module
RUN go mod init go-libp2p-test

# Add dependencies
RUN go get github.com/libp2p/go-libp2p@v0.36
RUN go get github.com/libp2p/go-libp2p/p2p/protocol/ping@v0.36
RUN go get github.com/libp2p/go-libp2p/p2p/protocol/identify@v0.36

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

	// Create a new libp2p host with QUIC transport
	h, err := libp2p.New(
		libp2p.ListenAddrStrings(
			fmt.Sprintf("/ip4/0.0.0.0/udp/%d/quic-v1", port),
		),
		libp2p.Ping(true), // Enable ping protocol
	)
	if err != nil {
		log.Fatalf("Failed to create host: %v", err)
	}
	defer h.Close()

	// Get the host's peer ID
	peerID := h.ID()
	log.Printf("Local peer id: %s", peerID.String())

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
EOF

# Build the application
RUN go build -o go-libp2p-test main.go

# Final image
FROM alpine:3.19

COPY --from=builder /app/go-libp2p-test /usr/local/bin/go-libp2p-test

EXPOSE 4001/udp

ENTRYPOINT ["/usr/local/bin/go-libp2p-test"]
