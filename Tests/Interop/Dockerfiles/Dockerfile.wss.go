# Dockerfile for go-libp2p WSS (Secure WebSocket) test node
#
# This creates a go-libp2p node that listens on WSS (TLS + WebSocket)
# with Noise security and supports Identify and Ping protocols.

FROM golang:1.23-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache git openssl

# Generate self-signed certificate
RUN openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
    -days 365 -nodes -subj "/CN=localhost"

# Initialize Go module
RUN go mod init go-libp2p-wss-test

# Add dependencies
RUN go get github.com/libp2p/go-libp2p@v0.36
RUN go get github.com/libp2p/go-libp2p/p2p/security/noise@v0.36
RUN go get github.com/libp2p/go-libp2p/p2p/transport/websocket@v0.36
RUN go get github.com/libp2p/go-libp2p/p2p/muxer/yamux@v0.36

# Create the test server
RUN cat > main.go << 'EOF'
package main

import (
	"crypto/tls"
	"fmt"
	"log"
	"os"
	"strconv"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/p2p/security/noise"
	"github.com/libp2p/go-libp2p/p2p/transport/websocket"
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

	// Get certificate files
	certFile := os.Getenv("CERT_FILE")
	keyFile := os.Getenv("KEY_FILE")
	if certFile == "" {
		certFile = "/cert.pem"
	}
	if keyFile == "" {
		keyFile = "/key.pem"
	}

	// Load TLS certificate
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		log.Fatalf("Failed to load certificate: %v", err)
	}

	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
	}

	// Create a new libp2p host with WSS transport and Noise security
	h, err := libp2p.New(
		libp2p.ListenAddrStrings(
			fmt.Sprintf("/ip4/0.0.0.0/tcp/%d/wss", port),
		),
		// Disable default transports, use only WebSocket with TLS
		libp2p.NoTransports,
		libp2p.Transport(websocket.New, websocket.WithTLSConfig(tlsConfig)),
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
	log.Printf("Transport: WSS (TLS + WebSocket)")
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
EOF

# Build the application
RUN go build -o go-libp2p-wss-test main.go

# Final image
FROM alpine:3.19

COPY --from=builder /app/go-libp2p-wss-test /usr/local/bin/go-libp2p-wss-test
COPY --from=builder /app/cert.pem /cert.pem
COPY --from=builder /app/key.pem /key.pem

EXPOSE 4001/tcp

ENV CERT_FILE=/cert.pem
ENV KEY_FILE=/key.pem

ENTRYPOINT ["/usr/local/bin/go-libp2p-wss-test"]
