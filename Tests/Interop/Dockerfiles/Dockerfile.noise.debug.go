# syntax=docker/dockerfile:1.7
# Debug Dockerfile for go-libp2p Noise handshake
#
# This creates a go-libp2p node with debug logging for Noise handshake

FROM golang:1.23-alpine AS builder

WORKDIR /app

RUN apk add --no-cache git

RUN go mod init go-libp2p-noise-debug

RUN go get github.com/libp2p/go-libp2p@v0.36
RUN go get github.com/libp2p/go-libp2p/p2p/security/noise@v0.36
RUN go get github.com/libp2p/go-libp2p/p2p/transport/tcp@v0.36
RUN go get github.com/libp2p/go-libp2p/p2p/muxer/yamux@v0.36
RUN go get github.com/flynn/noise

COPY Dockerfiles/generated/Dockerfile.noise.debug.go/main.go main.go
RUN go build -o noise-debug main.go

FROM alpine:3.19
COPY --from=builder /app/noise-debug /usr/local/bin/noise-debug
EXPOSE 4001/tcp
ENTRYPOINT ["/usr/local/bin/noise-debug"]
