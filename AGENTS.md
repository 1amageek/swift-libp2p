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
- `Sources/Integration/P2P/` is the integration layer (Node, ConnectionUpgrader, ResourceManager, Traversal).
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
- `swift test --filter P2PBenchmarks/DataPathBenchmarks` — runtime data-path throughput and connect costs.
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
- `swift test --filter Traversal` — Traversal orchestration tests.
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
- Run static guard first: `scripts/check-sync-shutdown-in-deinit.sh Sources/Transport Tests/Interop/Harnesses`.
- Use `scripts/swift-test-timeout.sh` for all local test runs to enforce timeout.
- Recommended invocation: `SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.cache/clang scripts/swift-test-timeout.sh 30 --disable-sandbox --filter <SuiteOrTestName>`.
- For hang-prone suites, run guarded repeats:
  `SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.cache/clang scripts/swift-test-hang-guard.sh --repeats 3 --timeout 30 --build-timeout 120 -- --disable-sandbox --filter <SuiteOrTestName>`
- `scripts/swift-test-hang-guard.sh` is intentionally serialized (single active run). Do not run multiple hang-guard jobs concurrently.
- Hang-guard logs and diagnostics are stored under `.test-artifacts/hang-guard/<timestamp>/`.
- For production-readiness checks, use `scripts/production-gate.sh`; add `--include-benchmarks` before cutting a release candidate.

## Commit & Pull Request Guidelines
- Use concise, imperative commit subjects with a subsystem hint (e.g., `Transport: handle half-close`).
- PRs should include: clear description, linked issues (if any), tests run (`swift test` or filtered), and interop notes when protocol behavior changes.

## Repository-Specific Notes
- Before reading code in any module directory, open its `CONTEXT.md` first (e.g., `Sources/Transport/CONTEXT.md`).
- Keep protocol definitions separated from implementations, matching the module layout in `Package.swift`.
- Each component directory may have a `README.md` with performance benchmarks and optimization details.

## P2P Facade DSL Design Policy
- The public Node DSL belongs to the `P2P` facade only. Lower-level modules must not expose public DSL helpers such as `service(...)` or `discovery(...)`.
- Prefer a minimal public DSL surface. Reuse should be modeled with `NodeGroup` first; do not add new public protocol layers unless they remove real complexity.
- `init` and modifiers have different responsibilities and must stay separated:
  - `init` is for intrinsic construction of a valid value: required dependencies, immutable configuration, and domain-specific options.
  - modifiers are for composition semantics inside a `Node`: runtime roles, lifecycle participation, capability requirements, weighting, and startup hooks.
- Do not hide composition semantics inside `init` unless the value cannot exist meaningfully without them. If a built-in primitive has default runtime roles, treat those defaults as a separate descriptor-level concern, not as an ad hoc side effect of initialization.
- Built-in primitives in the facade should remain noun-only (`Ping`, `Identify`, `MDNS`, etc.) and should stay thin wrappers over the generic `Service(...)` / `Discovery(...)` primitives.
- Custom composition examples in docs and tests should prefer:
  - `Node { ... }` for direct composition
  - `NodeGroup { ... }` for reusable grouped composition
  - `Service(...)` / `Discovery(...)` for custom expert-level components
- Public custom component authoring should not require callers to understand internal runtime arrays or lower-level resolver plumbing. If a public API exposes `ServiceComponent` / `DiscoveryComponent` details directly, treat that as a design smell and simplify it.

## Production Readiness Policy
- A production composition should be representable as `Node(profile: .production) { ... }` without extra façade-only escape hatches.
- The release path is explicit: strict startup validation first, then the production gate, then benchmark comparison against the checked-in snapshot.
- Runtime-facing copy guards are part of the release contract. Do not relax `DataPathCopyGuardTests` allowances without documenting the adapter boundary and benchmark impact.

## Data Path Policy
- The runtime-facing payload path is `ByteBuffer` only. In `Sources/Protocols/`, `Sources/Integration/`, and `Sources/Transport/` business logic, do not introduce `Data(buffer:)` or `ByteBuffer(bytes:)` on hot paths.
- If a protobuf or wire codec still needs `Data`, keep that conversion inside the codec boundary, not in services, runtime orchestration, or stream handlers.
- Native transport and crypto adapters are the only acceptable boundary for `Data`-based APIs. When a dependency accepts generic byte views (`DataProtocol`, `Collection<UInt8>`, `UnsafeRawBufferPointer>`), pass `ByteBuffer.readableBytesView` or an equivalent zero-copy view instead of materializing `Data`.
- When a dependency returns `Data` and no zero-copy API exists, convert once at the adapter boundary and document that boundary in tests or comments if it affects benchmark-sensitive paths.
