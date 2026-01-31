# Repository Guidelines

## Project Structure & Module Organization
- `Package.swift` defines SwiftPM targets and products; each module maps to a subfolder under `Sources/`.
- `Sources/Core/P2PCore/` contains core types (PeerID, Multiaddr, keys, varint, multihash).
- `Sources/Transport/` — Transport protocol definitions and implementations (TCP, QUIC, WebRTC, WebSocket, Memory).
- `Sources/Security/` — Security protocol definitions and implementations (Noise, TLS, Plaintext, Certificate).
- `Sources/Mux/` — Mux protocol definitions and implementations (Yamux, Mplex).
- `Sources/Negotiation/` — multistream-select.
- `Sources/Discovery/` — Discovery protocol definitions and implementations (SWIM, mDNS, CYCLON).
- `Sources/NAT/` — NAT traversal (P2PNAT, UPnP, NATPMP).
- `Sources/Protocols/` — Application protocol definitions and implementations (Ping, Identify, GossipSub, Kademlia, CircuitRelay, DCUtR, AutoNAT, Plumtree).
- `Sources/Integration/P2P/` is the integration layer (Node, ConnectionUpgrader, ResourceManager).
- `Tests/` mirrors module layout for unit/integration tests.
- `Benchmarks/P2PBenchmarks/` contains performance benchmarks.
- `Examples/PingPongDemo/` contains the runnable demo app.
- `docs/` and design notes (`DESIGN-*.md`) capture protocol and architecture decisions.

## Build, Test, and Development Commands
- `swift build` — build all SwiftPM targets.
- `swift test` — run the full test suite.
- `swift test --filter <SuiteOrTestName>` — run a focused test.
- `swift run PingPongDemo server|client` — run the demo app.

### Benchmark Commands
- `swift test --filter P2PBenchmarks` — run all benchmarks.
- `swift test --filter P2PBenchmarks/KademliaKeyBenchmarks` — KademliaKey benchmarks.
- `swift test --filter P2PBenchmarks/VarintBenchmarks` — Varint benchmarks.
- `swift test --filter P2PBenchmarks/MessageIDBenchmarks` — MessageID benchmarks.
- `swift test --filter P2PBenchmarks/TopicBenchmarks` — Topic benchmarks.
- `swift test --filter P2PBenchmarks/YamuxFrameBenchmarks` — YamuxFrame benchmarks.
- `swift test --filter P2PBenchmarks/NoiseCryptoBenchmarks` — NoiseCryptoState benchmarks.

### Module-Specific Test Commands
- `swift test --filter P2PCoreTests` — Core tests.
- `swift test --filter P2PTransportTests` — TCP/Memory transport tests.
- `swift test --filter QUICTests` — QUIC E2E tests.
- `swift test --filter WebRTCTests` — WebRTC E2E tests.
- `swift test --filter WebSocketTests` — WebSocket tests.
- `swift test --filter NoiseTests` — Noise integration tests.
- `swift test --filter TLSTests` — TLS tests.
- `swift test --filter P2PMuxYamuxTests` — Yamux tests.
- `swift test --filter P2PMuxMplexTests` — Mplex tests.
- `swift test --filter PingTests` — Ping E2E tests.
- `swift test --filter IdentifyTests` — Identify E2E tests.
- `swift test --filter GossipSubTests` — GossipSub tests.
- `swift test --filter KademliaTests` — Kademlia tests.
- `swift test --filter CircuitRelayTests` — CircuitRelay tests.
- `swift test --filter DCUtRTests` — DCUtR tests.
- `swift test --filter AutoNATTests` — AutoNAT tests.
- `swift test --filter P2PTests` — Integration/Node E2E tests.
- `swift test --filter GoInteropTests` — Go interop tests.

## Coding Style & Naming Conventions
- Follow Swift API Design Guidelines; prefer `async/await` (avoid `EventLoopFuture`).
- Value types first (`struct` over `class`); use `actor` for user-facing APIs, `class + Mutex` for high-frequency internal state.
- One primary type per file; filename matches the type (e.g., `PeerID.swift` contains `PeerID`).
- Prefer `Sendable` conformance; avoid `@unchecked Sendable` (use `Mutex<T>` instead).
- Use `// MARK: -` sections to organize public/internal/private APIs when files grow.

## Testing Guidelines
- Framework: Swift Testing (`@Suite`, `@Test`).
- Every public API should have unit tests; cover success and error paths.
- Interop testing with Go/Rust libp2p is a priority when touching wire protocols.
- Naming: `@Suite("Feature Tests")` with descriptive `@Test("Behavior description")`.
- Always set timeouts for test commands to prevent hanging (recommended: 30s).

## Commit & Pull Request Guidelines
- Use concise, imperative commit subjects with a subsystem hint (e.g., `Transport: handle half-close`).
- PRs should include: clear description, linked issues (if any), tests run (`swift test` or filtered), and interop notes when protocol behavior changes.

## Repository-Specific Notes
- Before reading code in any module directory, open its `CONTEXT.md` first (e.g., `Sources/Transport/CONTEXT.md`).
- Keep protocol definitions separated from implementations, matching the module layout in `Package.swift`.
- Each component directory may have a `README.md` with performance benchmarks and optimization details.
