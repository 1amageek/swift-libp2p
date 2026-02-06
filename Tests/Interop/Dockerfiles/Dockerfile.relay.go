# Dockerfile for go-libp2p Circuit Relay v2 test node
#
# This creates a go-libp2p node with Circuit Relay v2 support.
# Acts as a relay server that other nodes can use to relay connections.

FROM golang:1.23-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache git

# Initialize Go module
RUN go mod init go-libp2p-relay-test

# Add dependencies
RUN go get github.com/libp2p/go-libp2p@v0.36

# Create the test server
RUN cat > main.go << 'EOF'
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"strconv"
	"time"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/relay"
	"github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/client"
	"github.com/multiformats/go-multiaddr"
)

func main() {
	ctx := context.Background()

	// Get port from environment
	portStr := os.Getenv("LISTEN_PORT")
	if portStr == "" {
		portStr = "4001"
	}
	port, err := strconv.Atoi(portStr)
	if err != nil {
		log.Fatalf("Invalid port: %v", err)
	}

	// Get relay mode from environment
	relayMode := os.Getenv("RELAY_MODE")
	if relayMode == "" {
		relayMode = "server"
	}

	// Create libp2p host with QUIC transport
	opts := []libp2p.Option{
		libp2p.ListenAddrStrings(
			fmt.Sprintf("/ip4/0.0.0.0/udp/%d/quic-v1", port),
		),
		libp2p.Ping(true),
		libp2p.EnableHolePunching(),
	}

	// Enable relay client for all modes
	opts = append(opts, libp2p.EnableRelay())

	h, err := libp2p.New(opts...)
	if err != nil {
		log.Fatalf("Failed to create host: %v", err)
	}
	defer h.Close()

	peerID := h.ID()
	log.Printf("Local peer id: %s", peerID.String())
	log.Printf("Relay mode: %s", relayMode)

	// Set up relay based on mode
	if relayMode == "server" {
		// Create relay service with default resources
		relayService, err := relay.New(h,
			relay.WithResources(relay.Resources{
				Limit: &relay.RelayLimit{
					Duration: 2 * time.Minute,
					Data:     1 << 17, // 128KB
				},
				MaxReservations:        128,
				MaxCircuits:           16,
				BufferSize:            4096,
				MaxReservationsPerPeer: 4,
				MaxReservationsPerIP:   8,
			}),
		)
		if err != nil {
			log.Fatalf("Failed to create relay: %v", err)
		}
		_ = relayService

		log.Printf("Relay server started")
		log.Printf("Protocol: /libp2p/circuit/relay/0.2.0/hop")

		// Print relay address
		for _, addr := range h.Addrs() {
			relayAddr := addr.Encapsulate(multiaddr.StringCast("/p2p/" + peerID.String() + "/p2p-circuit"))
			fmt.Printf("RelayAddr: %s\n", relayAddr.String())
		}
	} else {
		// Client mode - can reserve slots and use relays
		log.Printf("Relay client mode")
	}

	// Print listen addresses
	for _, addr := range h.Addrs() {
		fullAddr := addr.Encapsulate(multiaddr.StringCast("/p2p/" + peerID.String()))
		fmt.Printf("Listen: %s\n", fullAddr.String())
	}
	fmt.Println("Ready to accept connections")

	// Handle incoming relay connections
	h.SetStreamHandler("/libp2p/circuit/relay/0.2.0/stop", func(s network.Stream) {
		log.Printf("Incoming relay connection from %s", s.Conn().RemotePeer())
		// The relay library handles this automatically
	})

	// Monitor connection events
	h.Network().Notify(&network.NotifyBundle{
		ConnectedF: func(n network.Network, c network.Conn) {
			log.Printf("Connected: %s via %s", c.RemotePeer(), c.RemoteMultiaddr())

			// Check if this is a relayed connection
			if _, err := c.RemoteMultiaddr().ValueForProtocol(multiaddr.P_CIRCUIT); err == nil {
				log.Printf("Connection is relayed!")
			}
		},
		DisconnectedF: func(n network.Network, c network.Conn) {
			log.Printf("Disconnected: %s", c.RemotePeer())
		},
	})

	// If running as client, try to reserve a slot on the relay
	if relayMode == "client" {
		relayAddrStr := os.Getenv("RELAY_ADDR")
		if relayAddrStr != "" {
			relayAddr, err := multiaddr.NewMultiaddr(relayAddrStr)
			if err != nil {
				log.Printf("Invalid relay address: %v", err)
			} else {
				// Extract peer ID from relay address
				relayInfo, err := peer.AddrInfoFromP2pAddr(relayAddr)
				if err != nil {
					log.Printf("Failed to parse relay info: %v", err)
				} else {
					// Connect to relay
					if err := h.Connect(ctx, *relayInfo); err != nil {
						log.Printf("Failed to connect to relay: %v", err)
					} else {
						log.Printf("Connected to relay: %s", relayInfo.ID)

						// Reserve a slot
						reservation, err := client.Reserve(ctx, h, *relayInfo)
						if err != nil {
							log.Printf("Failed to reserve: %v", err)
						} else {
							log.Printf("Reserved slot on relay")
							log.Printf("Reservation expires: %v", reservation.Expiration)
							for _, addr := range reservation.Addrs {
								fmt.Printf("RelayedAddr: %s\n", addr.String())
							}
						}
					}
				}
			}
		}
	}

	// Keep running
	select {}
}
EOF

# Build the application
RUN go build -o go-libp2p-relay-test main.go

# Final image
FROM alpine:3.19

COPY --from=builder /app/go-libp2p-relay-test /usr/local/bin/go-libp2p-relay-test

EXPOSE 4001/udp

ENTRYPOINT ["/usr/local/bin/go-libp2p-relay-test"]
