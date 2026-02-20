# Dockerfile for go-libp2p Kademlia DHT test node
#
# This creates a go-libp2p node with Kademlia DHT support.
# Supports FIND_NODE, FIND_PROVIDERS, PROVIDE, PUT_VALUE, GET_VALUE operations.

FROM golang:1.23-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache git

# Initialize Go module
RUN go mod init go-libp2p-kad-test

# Add dependencies
RUN go get github.com/libp2p/go-libp2p@v0.36
RUN go get github.com/libp2p/go-libp2p-kad-dht@v0.27

# Create the test server
RUN cat > main.go << 'EOF'
package main

import (
	"bufio"
	"context"
	"encoding/hex"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/ipfs/go-cid"
	"github.com/libp2p/go-libp2p"
	dht "github.com/libp2p/go-libp2p-kad-dht"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/multiformats/go-multiaddr"
	"github.com/multiformats/go-multihash"
)

var kadDHT *dht.IpfsDHT

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

	// Get DHT mode from environment
	dhtMode := os.Getenv("DHT_MODE")
	if dhtMode == "" {
		dhtMode = "server"
	}

	// Create libp2p host with QUIC transport
	h, err := libp2p.New(
		libp2p.ListenAddrStrings(
			fmt.Sprintf("/ip4/0.0.0.0/udp/%d/quic-v1", port),
		),
		libp2p.Ping(true),
	)
	if err != nil {
		log.Fatalf("Failed to create host: %v", err)
	}
	defer h.Close()

	// Create Kademlia DHT
	var mode dht.ModeOpt
	switch dhtMode {
	case "server":
		mode = dht.ModeServer
	case "client":
		mode = dht.ModeClient
	default:
		mode = dht.ModeAutoServer
	}

	kadDHT, err = dht.New(ctx, h,
		dht.Mode(mode),
		dht.ProtocolPrefix("/ipfs"),
	)
	if err != nil {
		log.Fatalf("Failed to create DHT: %v", err)
	}

	// Bootstrap DHT
	if err = kadDHT.Bootstrap(ctx); err != nil {
		log.Printf("DHT bootstrap warning: %v", err)
	}

	peerID := h.ID()
	log.Printf("Local peer id: %s", peerID.String())
	log.Printf("DHT mode: %s", dhtMode)
	log.Printf("DHT protocol: /ipfs/kad/1.0.0")

	// Print listen addresses
	for _, addr := range h.Addrs() {
		fullAddr := addr.Encapsulate(multiaddr.StringCast("/p2p/" + peerID.String()))
		fmt.Printf("Listen: %s\n", fullAddr.String())
	}
	fmt.Println("Ready to accept connections")

	// Command handler (stdin)
	go handleCommands(ctx)

	// Keep running
	select {}
}

func handleCommands(ctx context.Context) {
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		parts := strings.SplitN(line, " ", 3)

		if len(parts) < 1 {
			continue
		}

		cmd := parts[0]
		switch cmd {
		case "FIND_NODE":
			if len(parts) < 2 {
				log.Printf("FIND_NODE requires peer ID")
				continue
			}
			peerIDStr := parts[1]
			pid, err := peer.Decode(peerIDStr)
			if err != nil {
				log.Printf("Invalid peer ID: %v", err)
				continue
			}

			ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
			peers, err := kadDHT.FindPeer(ctx, pid)
			cancel()

			if err != nil {
				fmt.Printf("FIND_NODE_ERROR: %v\n", err)
			} else {
				fmt.Printf("FIND_NODE_RESULT: %v\n", peers)
			}

			case "FIND_PROVIDERS":
				if len(parts) < 2 {
					log.Printf("FIND_PROVIDERS requires CID")
					continue
				}
				cidStr := parts[1]

				contentCID, err := parseCIDOrMultihash(cidStr)
				if err != nil {
					log.Printf("Invalid CID/multihash: %v", err)
					continue
				}

				ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
				providers := kadDHT.FindProvidersAsync(ctx, contentCID, 10)
				cancel()

			fmt.Printf("PROVIDERS_START: %s\n", cidStr)
			for p := range providers {
				fmt.Printf("PROVIDER: %s %v\n", p.ID, p.Addrs)
			}
			fmt.Printf("PROVIDERS_END: %s\n", cidStr)

			case "PROVIDE":
				if len(parts) < 2 {
					log.Printf("PROVIDE requires CID")
					continue
				}
				cidStr := parts[1]

				contentCID, err := parseCIDOrMultihash(cidStr)
				if err != nil {
					log.Printf("Invalid CID/multihash: %v", err)
					continue
				}

				ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
				err = kadDHT.Provide(ctx, contentCID, true)
				cancel()

			if err != nil {
				fmt.Printf("PROVIDE_ERROR: %v\n", err)
			} else {
				fmt.Printf("PROVIDED: %s\n", cidStr)
			}

		case "PUT_VALUE":
			if len(parts) < 3 {
				log.Printf("PUT_VALUE requires key and value")
				continue
			}
			key := parts[1]
			value := parts[2]

			ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
			err := kadDHT.PutValue(ctx, "/test/"+key, []byte(value))
			cancel()

			if err != nil {
				fmt.Printf("PUT_VALUE_ERROR: %v\n", err)
			} else {
				fmt.Printf("PUT_VALUE_OK: %s\n", key)
			}

		case "GET_VALUE":
			if len(parts) < 2 {
				log.Printf("GET_VALUE requires key")
				continue
			}
			key := parts[1]

			ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
			value, err := kadDHT.GetValue(ctx, "/test/"+key)
			cancel()

			if err != nil {
				fmt.Printf("GET_VALUE_ERROR: %v\n", err)
			} else {
				fmt.Printf("GET_VALUE_OK: %s = %s\n", key, string(value))
			}

		case "ROUTING_TABLE":
			rt := kadDHT.RoutingTable()
			fmt.Printf("ROUTING_TABLE_SIZE: %d\n", rt.Size())
			for _, p := range rt.ListPeers() {
				fmt.Printf("ROUTING_PEER: %s\n", p)
			}
		}
	}
}

func parseCIDOrMultihash(raw string) (cid.Cid, error) {
	parsedCID, err := cid.Parse(raw)
	if err == nil {
		return parsedCID, nil
	}

	mh, mhErr := multihash.FromB58String(raw)
	if mhErr == nil {
		return cid.NewCidV1(cid.Raw, mh), nil
	}

	mhBytes, hexErr := hex.DecodeString(raw)
	if hexErr != nil {
		return cid.Undef, err
	}

	castMH, castErr := multihash.Cast(mhBytes)
	if castErr != nil {
		return cid.Undef, castErr
	}

	return cid.NewCidV1(cid.Raw, castMH), nil
}
EOF

# Build the application
RUN go build -o go-libp2p-kad-test main.go

# Final image
FROM alpine:3.19

COPY --from=builder /app/go-libp2p-kad-test /usr/local/bin/go-libp2p-kad-test

EXPOSE 4001/udp

ENTRYPOINT ["/usr/local/bin/go-libp2p-kad-test"]
