# Dockerfile for rust-libp2p test node
#
# This creates a simple rust-libp2p node that listens on QUIC
# and supports Identify and Ping protocols.

FROM rust:1.83-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache musl-dev

# Install nightly Rust for edition2024 support
RUN rustup toolchain install nightly && rustup default nightly

# Create a new Rust project
RUN cargo init --name rust-libp2p-test

# Add dependencies to Cargo.toml
RUN cat > Cargo.toml << 'EOF'
[package]
name = "rust-libp2p-test"
version = "0.1.0"
edition = "2021"

[dependencies]
libp2p = { version = "0.56", features = ["quic", "tcp", "noise", "yamux", "ping", "identify", "macros", "tokio"] }
tokio = { version = "1.35", features = ["full"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
futures = "0.3"
EOF

# Create the test server
RUN cat > src/main.rs << 'EOF'
use futures::StreamExt;
use libp2p::{
    identify, ping,
    swarm::{NetworkBehaviour, SwarmEvent},
    Multiaddr, SwarmBuilder,
};
use std::error::Error;
use std::time::Duration;
use tracing::{info, warn};

#[derive(NetworkBehaviour)]
struct Behaviour {
    ping: ping::Behaviour,
    identify: identify::Behaviour,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    // Setup logging with detailed QUIC/TLS traces
    tracing_subscriber::fmt()
        .with_env_filter("info,rust_libp2p_test=trace,libp2p=trace,libp2p_quic=trace,quinn=trace")
        .init();

    // Get port from environment
    let port: u16 = std::env::var("LISTEN_PORT")
        .unwrap_or_else(|_| "4001".to_string())
        .parse()
        .expect("Invalid port");

    // Create swarm using SwarmBuilder
    let mut swarm = SwarmBuilder::with_new_identity()
        .with_tokio()
        .with_quic()
        .with_behaviour(|keypair| {
            let peer_id = keypair.public().to_peer_id();
            info!("Local peer id: {peer_id}");

            Behaviour {
                ping: ping::Behaviour::new(ping::Config::new()),
                identify: identify::Behaviour::new(identify::Config::new(
                    "/ipfs/0.1.0".to_string(),
                    keypair.public(),
                )),
            }
        })
        .expect("Failed to create behaviour")
        .with_swarm_config(|cfg| {
            cfg.with_idle_connection_timeout(Duration::from_secs(60))
        })
        .build();

    // Listen on QUIC
    let listen_addr: Multiaddr = format!("/ip4/0.0.0.0/udp/{port}/quic-v1")
        .parse()
        .expect("Invalid multiaddr");

    swarm.listen_on(listen_addr.clone())?;
    info!("Listening on {listen_addr}");

    loop {
        match swarm.next().await {
            Some(SwarmEvent::NewListenAddr { address, .. }) => {
                let peer_id = swarm.local_peer_id();
                println!("Listen: {}/p2p/{}", address, peer_id);
                println!("Ready to accept connections");
            }
            Some(SwarmEvent::IncomingConnection { local_addr, send_back_addr, .. }) => {
                info!("Incoming connection from {send_back_addr} to {local_addr}");
            }
            Some(SwarmEvent::ConnectionEstablished { peer_id, endpoint, .. }) => {
                info!("Connected: peer={peer_id} endpoint={endpoint:?}");
            }
            Some(SwarmEvent::ConnectionClosed { peer_id, cause, .. }) => {
                info!("Disconnected: peer={peer_id} cause={cause:?}");
            }
            Some(SwarmEvent::IncomingConnectionError { local_addr, send_back_addr, error, .. }) => {
                warn!("Incoming connection error from {send_back_addr} to {local_addr}: {error}");
            }
            Some(SwarmEvent::Behaviour(BehaviourEvent::Ping(event))) => {
                match event.result {
                    Ok(rtt) => info!("Ping: peer={:?} rtt={rtt:?}", event.peer),
                    Err(err) => warn!("Ping failed: peer={:?} error={err}", event.peer),
                }
            }
            Some(SwarmEvent::Behaviour(BehaviourEvent::Identify(identify::Event::Received { peer_id, info, .. }))) => {
                info!("Identify received: peer={peer_id} agent={} protocols={:?}",
                    info.agent_version, info.protocols);
            }
            Some(SwarmEvent::Behaviour(BehaviourEvent::Identify(identify::Event::Sent { peer_id, .. }))) => {
                info!("Identify sent to: peer={peer_id}");
            }
            Some(event) => {
                info!("Other event: {event:?}");
            }
            None => break,
        }
    }
    Ok(())
}
EOF

# Build the application
RUN cargo build --release

# Final image
FROM alpine:3.19

COPY --from=builder /app/target/release/rust-libp2p-test /usr/local/bin/rust-libp2p-test

EXPOSE 4001/udp

ENTRYPOINT ["/usr/local/bin/rust-libp2p-test"]
