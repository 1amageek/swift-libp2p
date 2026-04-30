# syntax=docker/dockerfile:1.7
# Dockerfile for go-libp2p TCP + Noise test node
#
# This creates a go-libp2p node that listens on TCP with Noise security
# and supports Identify and Ping protocols.

FROM golang:1.23-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache git

# Initialize Go module
RUN go mod init go-libp2p-tcp-test

# Add dependencies
RUN go get github.com/libp2p/go-libp2p@v0.36
RUN go get github.com/libp2p/go-libp2p/p2p/security/noise@v0.36
RUN go get github.com/libp2p/go-libp2p/p2p/transport/tcp@v0.36
RUN go get github.com/libp2p/go-libp2p/p2p/muxer/yamux@v0.36

# Create the test server
COPY Dockerfiles/generated/Dockerfile.tcp.go/main.go main.go
# Build the application
RUN go build -o go-libp2p-tcp-test main.go

# Final image
FROM alpine:3.19

COPY --from=builder /app/go-libp2p-tcp-test /usr/local/bin/go-libp2p-tcp-test

EXPOSE 4001/tcp

ENTRYPOINT ["/usr/local/bin/go-libp2p-tcp-test"]
