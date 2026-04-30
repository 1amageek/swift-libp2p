# syntax=docker/dockerfile:1.7
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
COPY Dockerfiles/generated/Dockerfile.kad.go/main.go main.go
# Build the application
RUN go build -o go-libp2p-kad-test main.go

# Final image
FROM alpine:3.19

COPY --from=builder /app/go-libp2p-kad-test /usr/local/bin/go-libp2p-kad-test

EXPOSE 4001/udp

ENTRYPOINT ["/usr/local/bin/go-libp2p-kad-test"]
