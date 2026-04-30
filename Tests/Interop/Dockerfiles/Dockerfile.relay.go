# syntax=docker/dockerfile:1.7
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
COPY Dockerfiles/generated/Dockerfile.relay.go/main.go main.go
# Build the application
RUN go build -o go-libp2p-relay-test main.go

# Final image
FROM alpine:3.19

COPY --from=builder /app/go-libp2p-relay-test /usr/local/bin/go-libp2p-relay-test

EXPOSE 4001/udp

ENTRYPOINT ["/usr/local/bin/go-libp2p-relay-test"]
