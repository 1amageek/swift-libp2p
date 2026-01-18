# Repository Guidelines

## Project Structure & Module Organization
- `Package.swift` defines SwiftPM targets and products; each module maps to a subfolder under `Sources/`.
- `Sources/Core/P2PCore/` contains core types (PeerID, Multiaddr, keys, varint, multihash).
- `Sources/Transport/`, `Sources/Security/`, `Sources/Mux/`, `Sources/Negotiation/`, `Sources/Discovery/`, and `Sources/Protocols/` hold protocol definitions and implementations (e.g., `TCP`, `Noise`, `Yamux`, `Ping`, `Identify`, `GossipSub`).
- `Sources/Integration/P2P/` is the integration layer (Node, connection orchestration).
- `Tests/` mirrors module layout for unit/integration tests.
- `Examples/PingPongDemo/` contains the runnable demo app.
- `docs/` and design notes (`DESIGN-*.md`) capture protocol and architecture decisions.

## Build, Test, and Development Commands
- `swift build` — build all SwiftPM targets.
- `swift test` — run the full test suite.
- `swift test --filter <SuiteOrTestName>` — run a focused test (see `DESIGN-PHASE1.md` for examples).
- `swift run PingPongDemo server|client` — run the demo app from `Examples/PingPongDemo`.

## Coding Style & Naming Conventions
- Follow Swift API Design Guidelines; prefer `async/await` (avoid `EventLoopFuture`).
- Value types first (`struct` over `class`); use `actor` for user-facing APIs, `class + Mutex` for high-frequency internal state.
- One primary type per file; filename matches the type (e.g., `PeerID.swift` contains `PeerID`).
- Prefer `Sendable` conformance; avoid `@unchecked Sendable` unless unavoidable.
- Use `// MARK: -` sections to organize public/internal/private APIs when files grow.

## Testing Guidelines
- Framework: Swift Testing (`@Suite`, `@Test`).
- Every public API should have unit tests; cover success and error paths.
- Interop testing with Go/Rust libp2p is a priority when touching wire protocols.
- Naming: `@Suite("Feature Tests")` with descriptive `@Test("Behavior description")`.

## Commit & Pull Request Guidelines
- This checkout has no git history; follow any upstream convention if available.
- When unsure, use concise, imperative commit subjects with a subsystem hint (e.g., `Transport: handle half-close`).
- PRs should include: clear description, linked issues (if any), tests run (`swift test` or filtered), and interop notes when protocol behavior changes.

## Repository-Specific Notes
- Before reading code in any module directory, open its `CONTEXT.md` first (e.g., `Sources/Transport/CONTEXT.md`).
- Keep protocol definitions separated from implementations, matching the module layout in `Package.swift`.
