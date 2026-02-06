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

RUN cat > main.go << 'EOF'
package main

import (
	"crypto/rand"
	"encoding/hex"
	"io"
	"log"
	"net"
	"os"

	"github.com/flynn/noise"
	"github.com/libp2p/go-libp2p/core/crypto"
)

func main() {
	portStr := os.Getenv("LISTEN_PORT")
	if portStr == "" {
		portStr = "4001"
	}

	// Generate Ed25519 identity key
	privKey, _, err := crypto.GenerateEd25519Key(rand.Reader)
	if err != nil {
		log.Fatalf("Failed to generate key: %v", err)
	}
	pubBytes, _ := privKey.GetPublic().Raw()
	log.Printf("Identity public key: %s", hex.EncodeToString(pubBytes))

	// Listen on TCP
	listener, err := net.Listen("tcp", ":"+portStr)
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}
	defer listener.Close()

	log.Printf("Listening on TCP port %s", portStr)
	log.Println("Ready to accept connections")

	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("Accept error: %v", err)
			continue
		}
		go handleConnection(conn)
	}
}

func handleConnection(conn net.Conn) {
	defer conn.Close()
	log.Printf("New connection from %s", conn.RemoteAddr())

	// Read multistream header
	buf := make([]byte, 1024)
	n, err := conn.Read(buf)
	if err != nil {
		log.Printf("Read error: %v", err)
		return
	}
	log.Printf("Received multistream header (%d bytes): %s", n, hex.EncodeToString(buf[:n]))

	// Send multistream header response
	header := "\x13/multistream/1.0.0\n"
	conn.Write([]byte(header))
	log.Printf("Sent multistream header")

	// Read protocol request
	n, err = conn.Read(buf)
	if err != nil {
		log.Printf("Read error: %v", err)
		return
	}
	log.Printf("Received protocol request (%d bytes): %s", n, hex.EncodeToString(buf[:n]))

	// Send protocol confirmation
	noiseProto := "\x07/noise\n"
	conn.Write([]byte(noiseProto))
	log.Printf("Sent /noise confirmation")

	// Now start Noise handshake
	performNoiseHandshake(conn)
}

func performNoiseHandshake(conn net.Conn) {
	// Generate static keypair for Noise
	staticKP, err := noise.DH25519.GenerateKeypair(rand.Reader)
	if err != nil {
		log.Printf("Failed to generate static keypair: %v", err)
		return
	}
	log.Printf("Noise static public key: %s", hex.EncodeToString(staticKP.Public))

	// Configure Noise handshake
	cs := noise.NewCipherSuite(noise.DH25519, noise.CipherChaChaPoly, noise.HashSHA256)
	cfg := noise.Config{
		CipherSuite:   cs,
		Pattern:       noise.HandshakeXX,
		Initiator:     false, // We are responder
		StaticKeypair: staticKP,
	}

	hs, err := noise.NewHandshakeState(cfg)
	if err != nil {
		log.Printf("Failed to create handshake state: %v", err)
		return
	}

	// Read Message A (initiator's ephemeral)
	buf := make([]byte, 1024)
	n, err := conn.Read(buf)
	if err != nil {
		log.Printf("Failed to read Message A: %v", err)
		return
	}
	log.Printf("Received Message A frame (%d bytes): %s", n, hex.EncodeToString(buf[:n]))

	// Parse length prefix
	if n < 2 {
		log.Printf("Message A too short")
		return
	}
	msgLen := int(buf[0])<<8 | int(buf[1])
	log.Printf("Message A length: %d", msgLen)

	messageA := buf[2 : 2+msgLen]
	log.Printf("Message A content: %s", hex.EncodeToString(messageA))

	// Process Message A
	payload, cs1, cs2, err := hs.ReadMessage(nil, messageA)
	if err != nil {
		log.Printf("Failed to process Message A: %v", err)
		return
	}
	log.Printf("Message A payload: %s", hex.EncodeToString(payload))
	log.Printf("Remote ephemeral: %s", hex.EncodeToString(hs.PeerEphemeral()))

	// Check if handshake complete (shouldn't be after just Message A in XX)
	if cs1 != nil || cs2 != nil {
		log.Printf("Unexpected: handshake complete after Message A")
		return
	}

	// Generate Message B
	msgB, cs1, cs2, err := hs.WriteMessage(nil, createDummyPayload())
	if err != nil {
		log.Printf("Failed to generate Message B: %v", err)
		return
	}
	log.Printf("Message B content (%d bytes): %s", len(msgB), hex.EncodeToString(msgB))

	// Extract parts of Message B for debugging
	if len(msgB) >= 32 {
		log.Printf("Message B ephemeral: %s", hex.EncodeToString(msgB[:32]))
	}
	if len(msgB) >= 80 {
		log.Printf("Message B encrypted static: %s", hex.EncodeToString(msgB[32:80]))
	}

	// Send Message B with length prefix
	frameBuf := make([]byte, 2+len(msgB))
	frameBuf[0] = byte(len(msgB) >> 8)
	frameBuf[1] = byte(len(msgB) & 0xff)
	copy(frameBuf[2:], msgB)
	_, err = conn.Write(frameBuf)
	if err != nil {
		log.Printf("Failed to send Message B: %v", err)
		return
	}
	log.Printf("Sent Message B frame (%d bytes)", len(frameBuf))

	// Check if handshake complete
	if cs1 != nil && cs2 != nil {
		log.Printf("Handshake complete after Message B")
		return
	}

	// Read Message C
	n, err = conn.Read(buf)
	if err != nil {
		if err == io.EOF {
			log.Printf("Connection closed before Message C")
		} else {
			log.Printf("Failed to read Message C: %v", err)
		}
		return
	}
	log.Printf("Received Message C frame (%d bytes): %s", n, hex.EncodeToString(buf[:n]))

	log.Printf("Noise handshake test complete")
}

func createDummyPayload() []byte {
	// Create a minimal libp2p noise payload
	// This is just for testing - a real implementation would sign the static key
	return []byte{}
}
EOF

RUN go build -o noise-debug main.go

FROM alpine:3.19
COPY --from=builder /app/noise-debug /usr/local/bin/noise-debug
EXPOSE 4001/tcp
ENTRYPOINT ["/usr/local/bin/noise-debug"]
