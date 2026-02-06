# Dockerfile for go-libp2p GossipSub test node
#
# This creates a go-libp2p node with GossipSub pub/sub support.
# Supports subscribing to topics and publishing/receiving messages.

FROM golang:1.23-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache git

# Initialize Go module
RUN go mod init go-libp2p-gossipsub-test

# Add dependencies
RUN go get github.com/libp2p/go-libp2p@v0.36
RUN go get github.com/libp2p/go-libp2p-pubsub@v0.11

# Create the test server
RUN cat > main.go << 'EOF'
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/libp2p/go-libp2p"
	pubsub "github.com/libp2p/go-libp2p-pubsub"
	"github.com/multiformats/go-multiaddr"
)

type Message struct {
	Topic   string `json:"topic"`
	From    string `json:"from"`
	Data    string `json:"data"`
	SeqNo   string `json:"seqno"`
}

var (
	topics    = make(map[string]*pubsub.Topic)
	subs      = make(map[string]*pubsub.Subscription)
	topicsMu  sync.RWMutex
	ps        *pubsub.PubSub
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

	// Get default topic from environment (optional)
	defaultTopic := os.Getenv("DEFAULT_TOPIC")

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

	// Create GossipSub
	ps, err = pubsub.NewGossipSub(ctx, h,
		pubsub.WithPeerExchange(true),
		pubsub.WithFloodPublish(true),
	)
	if err != nil {
		log.Fatalf("Failed to create GossipSub: %v", err)
	}

	peerID := h.ID()
	log.Printf("Local peer id: %s", peerID.String())
	log.Printf("GossipSub enabled")

	// Print listen addresses
	for _, addr := range h.Addrs() {
		fullAddr := addr.Encapsulate(multiaddr.StringCast("/p2p/" + peerID.String()))
		fmt.Printf("Listen: %s\n", fullAddr.String())
	}
	fmt.Println("Ready to accept connections")

	// Subscribe to default topic if specified
	if defaultTopic != "" {
		if err := subscribe(ctx, defaultTopic); err != nil {
			log.Printf("Failed to subscribe to default topic: %v", err)
		} else {
			log.Printf("Subscribed to default topic: %s", defaultTopic)
		}
	}

	// Command handler (stdin)
	go handleCommands(ctx)

	// Keep running
	select {}
}

func subscribe(ctx context.Context, topicName string) error {
	topicsMu.Lock()
	defer topicsMu.Unlock()

	if _, exists := topics[topicName]; exists {
		return nil // Already subscribed
	}

	topic, err := ps.Join(topicName)
	if err != nil {
		return fmt.Errorf("join topic: %w", err)
	}

	sub, err := topic.Subscribe()
	if err != nil {
		return fmt.Errorf("subscribe: %w", err)
	}

	topics[topicName] = topic
	subs[topicName] = sub

	// Start message handler
	go handleMessages(ctx, topicName, sub)

	return nil
}

func handleMessages(ctx context.Context, topicName string, sub *pubsub.Subscription) {
	for {
		msg, err := sub.Next(ctx)
		if err != nil {
			log.Printf("Error receiving message on %s: %v", topicName, err)
			return
		}

		// Print received message as JSON
		m := Message{
			Topic:  topicName,
			From:   msg.GetFrom().String(),
			Data:   string(msg.Data),
			SeqNo:  fmt.Sprintf("%x", msg.GetSeqno()),
		}
		jsonBytes, _ := json.Marshal(m)
		fmt.Printf("MSG: %s\n", string(jsonBytes))
	}
}

func publish(topicName string, data string) error {
	topicsMu.RLock()
	topic, exists := topics[topicName]
	topicsMu.RUnlock()

	if !exists {
		return fmt.Errorf("not subscribed to topic: %s", topicName)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	return topic.Publish(ctx, []byte(data))
}

func handleCommands(ctx context.Context) {
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		parts := strings.SplitN(line, " ", 3)

		if len(parts) < 2 {
			continue
		}

		cmd := parts[0]
		switch cmd {
		case "SUB":
			topicName := parts[1]
			if err := subscribe(ctx, topicName); err != nil {
				log.Printf("Subscribe error: %v", err)
			} else {
				fmt.Printf("SUBSCRIBED: %s\n", topicName)
			}

		case "PUB":
			if len(parts) < 3 {
				log.Printf("PUB requires topic and message")
				continue
			}
			topicName := parts[1]
			message := parts[2]
			if err := publish(topicName, message); err != nil {
				log.Printf("Publish error: %v", err)
			} else {
				fmt.Printf("PUBLISHED: %s\n", topicName)
			}

		case "PEERS":
			topicName := parts[1]
			topicsMu.RLock()
			topic, exists := topics[topicName]
			topicsMu.RUnlock()
			if exists {
				peers := topic.ListPeers()
				fmt.Printf("PEERS %s: %v\n", topicName, peers)
			}
		}
	}
}
EOF

# Build the application
RUN go build -o go-libp2p-gossipsub-test main.go

# Final image
FROM alpine:3.19

COPY --from=builder /app/go-libp2p-gossipsub-test /usr/local/bin/go-libp2p-gossipsub-test

EXPOSE 4001/udp

ENTRYPOINT ["/usr/local/bin/go-libp2p-gossipsub-test"]
