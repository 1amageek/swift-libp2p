# syntax=docker/dockerfile:1.7
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
COPY Dockerfiles/generated/Dockerfile.gossipsub.go/main.go main.go
# Build the application
RUN go build -o go-libp2p-gossipsub-test main.go

# Final image
FROM alpine:3.19

COPY --from=builder /app/go-libp2p-gossipsub-test /usr/local/bin/go-libp2p-gossipsub-test

EXPOSE 4001/udp

ENTRYPOINT ["/usr/local/bin/go-libp2p-gossipsub-test"]
