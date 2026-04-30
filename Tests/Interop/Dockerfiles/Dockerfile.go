# syntax=docker/dockerfile:1.7
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
COPY Dockerfiles/generated/Dockerfile.go/main.go main.go
# Build the application
RUN go build -o go-libp2p-test main.go

# Final image
FROM alpine:3.19

COPY --from=builder /app/go-libp2p-test /usr/local/bin/go-libp2p-test

EXPOSE 4001/udp

ENTRYPOINT ["/usr/local/bin/go-libp2p-test"]
