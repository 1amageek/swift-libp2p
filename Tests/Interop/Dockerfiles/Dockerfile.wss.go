# syntax=docker/dockerfile:1.7
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
COPY Dockerfiles/generated/Dockerfile.wss.go/main.go main.go
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
