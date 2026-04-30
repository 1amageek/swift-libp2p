# syntax=docker/dockerfile:1.7
# Dockerfile for go-libp2p Yamux test node
#
# This creates a go-libp2p node that uses TCP + Noise + Yamux
# specifically for testing Yamux multiplexing.

FROM golang:1.23-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache git

# Initialize Go module
RUN go mod init go-libp2p-yamux-test

# Add dependencies
RUN go get github.com/libp2p/go-libp2p@v0.36
RUN go get github.com/libp2p/go-libp2p/p2p/security/noise@v0.36
RUN go get github.com/libp2p/go-libp2p/p2p/transport/tcp@v0.36
RUN go get github.com/libp2p/go-libp2p/p2p/muxer/yamux@v0.36

# Create the test server
COPY Dockerfiles/generated/Dockerfile.yamux.go/main.go main.go
# Build the application
RUN go build -o go-libp2p-yamux-test main.go

# Final image
FROM alpine:3.19

COPY --from=builder /app/go-libp2p-yamux-test /usr/local/bin/go-libp2p-yamux-test

EXPOSE 4001/tcp

ENTRYPOINT ["/usr/local/bin/go-libp2p-yamux-test"]
