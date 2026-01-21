# Dockerfile for go-libp2p test node
#
# This creates a simple go-libp2p node that listens on QUIC
# and supports Identify and Ping protocols.

FROM golang:1.22-alpine AS builder

WORKDIR /app

# Create go.mod
RUN echo 'module go-libp2p-test' > go.mod && \
    echo '' >> go.mod && \
    echo 'go 1.22' >> go.mod && \
    echo '' >> go.mod && \
    echo 'require github.com/libp2p/go-libp2p v0.36.0' >> go.mod

# Create the test server
RUN cat > main.go << 'EOF'
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/p2p/protocol/ping"
	"github.com/libp2p/go-libp2p/p2p/security/noise"
	"github.com/libp2p/go-libp2p/p2p/transport/quic"
	ma "github.com/multiformats/go-multiaddr"
)

func main() {
	port := os.Getenv("LISTEN_PORT")
	if port == "" {
		port = "4001"
	}

	// Create a new libp2p host with QUIC transport
	listenAddr, err := ma.NewMultiaddr(fmt.Sprintf("/ip4/0.0.0.0/udp/%s/quic-v1", port))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create listen address: %v\n", err)
		os.Exit(1)
	}

	host, err := libp2p.New(
		libp2p.ListenAddrs(listenAddr),
		libp2p.Transport(quic.NewTransport),
		libp2p.Security(noise.ID, noise.New),
		libp2p.Ping(true),
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create host: %v\n", err)
		os.Exit(1)
	}
	defer host.Close()

	// Create ping service
	pingService := ping.NewPingService(host)
	_ = pingService

	// Print node info
	fmt.Printf("PeerID: %s\n", host.ID())
	for _, addr := range host.Addrs() {
		fmt.Printf("Listen: %s/p2p/%s\n", addr, host.ID())
	}
	fmt.Println("Ready to accept connections")

	// Wait for shutdown signal
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	select {
	case <-sigChan:
		fmt.Println("Shutting down...")
	case <-ctx.Done():
	}
}
EOF

# Download dependencies and build
RUN go mod tidy && \
    CGO_ENABLED=0 go build -o /go-libp2p-test .

# Final image
FROM alpine:3.19

COPY --from=builder /go-libp2p-test /usr/local/bin/go-libp2p-test

EXPOSE 4001/udp

ENTRYPOINT ["/usr/local/bin/go-libp2p-test"]
