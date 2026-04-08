# Benchmark Report 2026-04-09

## Scope

This document summarizes the recent performance work on hot paths in `P2PCore`,
`GossipSub`, `Identify`, `Kademlia`, and `Yamux`, along with the latest release
benchmark results collected on 2026-04-09 (JST).

The goal of this round was:

- run repeatable release benchmarks
- validate changes with focused tests
- improve hot paths that were allocation-heavy or blocked cross-module
  specialization
- record the current baseline for future work

## Method

Benchmarks were executed with the repository benchmark runner:

```sh
scripts/run-benchmarks.sh --configuration release --suite <SuiteName>
```

Focused validation used timeout-wrapped test runs:

```sh
SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.cache/clang \
scripts/swift-test-timeout.sh 60 --disable-sandbox --filter <SuiteName>
```

Notes:

- Measurements are release-mode only unless noted otherwise.
- Microbenchmarks have normal run-to-run noise. Improvement claims below are
  based on repeated directionally consistent results, not a single sample.
- Some full-suite SwiftPM invocations remain expensive, so results are recorded
  per benchmark suite.

## Recent Optimization Summary

### Core

- `Varint`: reduced temporary allocations, added direct `Data` and `ByteBuffer`
  encode paths, exposed more hot paths as `@inlinable`.
- `Multihash`: cached encoded bytes to avoid rebuilding `code + length + digest`
  on every access.
- `Multihash(bytes:)`: switched decode to 0-based offset varint parsing and
  retained consumed bytes directly instead of rebuilding the multihash payload.
- `Multiaddr`: cached `bytes` and `description`.
- `PublicKey`: switched protobuf decode to 0-based offset varint parsing.
- `Envelope`: switched unmarshal to 0-based offset varint parsing and removed
  avoidable field copies.
- `PeerID`: replaced `matches(publicKey:)` reconstruction with direct multihash
  comparison for identity and SHA-256 cases.

### Protocols

- `KademliaKey`: removed intermediate `Data` in hashing paths and improved
  unaligned loads.
- `CollectionPartialSort`: restored release performance by enabling
  cross-module specialization and using the specialized comparable path in
  Kademlia call sites.
- `Topic`: improved short and long topic initialization and equality/hash paths.
- `MessageID`: reduced extra `Data` creation and duplicate hashing work.
- `YamuxFrame`: rewrote header encode/decode around direct raw byte access and
  added reusable buffer write paths.
- `Identify`, `GossipSub`, `Kademlia`, `IPNS`: added `encode(into:)` style wire
  paths to avoid `Data -> ByteBuffer` restaging and repeated varint allocations.

## Current Release Baselines

### Core Wire Benchmarks

Measured with:

```sh
scripts/run-benchmarks.sh --configuration release --suite CoreWireBenchmarks
```

| Benchmark | Result |
| --- | ---: |
| `Multihash.decode sha256` | `29.03 ns/op` |
| `Multihash.decode sha256 legacy` | `488.08 ns/op` |
| `PublicKey.decode protobuf ed25519` | `379.20 ns/op` |
| `Envelope.unmarshal signed PeerRecord` | `418.35 ns/op` |

Compared with the immediately previous baseline:

- `Multihash.decode sha256`: `485.23 -> 29.03 ns/op`
- `PublicKey.decode protobuf ed25519`: `385.03 -> 379.20 ns/op`
- `Envelope.unmarshal signed PeerRecord`: `441.27 -> 418.35 ns/op`

The `Multihash` benchmark now includes a same-suite legacy implementation for
sanity checking. On the latest run:

- `Multihash.decode sha256`: `29.03 ns/op`
- `Multihash.decode sha256 legacy`: `488.08 ns/op`

### GossipSub Wire Benchmarks

Measured with:

```sh
scripts/run-benchmarks.sh --configuration release --suite GossipSubWireBenchmarks
```

| Benchmark | Result |
| --- | ---: |
| `GossipSubMessage.Builder.sign` | `50333.65 ns/op` |
| `GossipSubMessage.verifySignature` | `30532.12 ns/op` |
| `GossipSubProtobuf.encode publish RPC` | `969.55 ns/op` |
| `GossipSubProtobuf.encode(into:) publish RPC` | `905.03 ns/op` |
| `GossipSubProtobuf.encode control RPC` | `5198.85 ns/op` |
| `GossipSubProtobuf.encode(into:) control RPC` | `5144.26 ns/op` |
| `GossipSub RPC framing publish RPC` | `75.08 ns/op` |

Compared with earlier baselines from this optimization run:

- `GossipSubMessage.verifySignature`: `40792.42 -> 30532.12 ns/op`
- `GossipSubProtobuf.encode publish RPC`: `1246.96 -> 969.55 ns/op`
- `GossipSubProtobuf.encode control RPC`: `5329.00 -> 5198.85 ns/op`
- `GossipSub RPC framing publish RPC`: `80.75 -> 75.08 ns/op`

### Identify Wire Benchmarks

Measured previously with:

```sh
scripts/run-benchmarks.sh --configuration release --suite IdentifyWireBenchmarks
```

| Benchmark | Result |
| --- | ---: |
| `IdentifyProtobuf.encode full info` | `1600.45 ns/op` |
| `IdentifyProtobuf.encode(into:) full info` | `1533.48 ns/op` |
| `IdentifyProtobuf.encode minimal info` | `277.27 ns/op` |
| `IdentifyProtobuf.encode(into:) minimal info` | `214.02 ns/op` |
| `IdentifyProtobuf.decode full info` | `6055.48 ns/op` |
| `IdentifyProtobuf.decode minimal info` | `156.39 ns/op` |

Relevant comparison:

- `IdentifyProtobuf.decode full info`: `6394.41 -> 6055.48 ns/op`

### Kademlia Wire Benchmarks

Measured previously with:

```sh
scripts/run-benchmarks.sh --configuration release --suite KademliaWireBenchmarks
```

| Benchmark | Result |
| --- | ---: |
| `KademliaProtobuf.encode findNodeResponse` | `10010.00 ns/op` |
| `KademliaProtobuf.encode(into:) findNodeResponse` | `4659.17 ns/op` |
| `KademliaProtobuf.encode getValueResponse` | `4475.17 ns/op` |
| `KademliaProtobuf.encode(into:) getValueResponse` | `2180.83 ns/op` |
| `KademliaProtobuf.decode findNodeResponse` | `243615.39 ns/op` |
| `KademliaProtobuf.decode getValueResponse` | `95999.60 ns/op` |

Relevant comparisons from this run:

- `KademliaProtobuf.encode findNodeResponse`: `57913.19 -> 10010.00 ns/op`
- `KademliaProtobuf.encode(into:) findNodeResponse`: `27223.75 -> 4659.17 ns/op`
- `KademliaProtobuf.decode findNodeResponse`: `270158.68 -> 243615.39 ns/op`

### Other Established Baselines

These were measured earlier in the same optimization run and remain useful as
current reference points:

| Benchmark | Result |
| --- | ---: |
| `KademliaKey.init(hashing:)` | `276.45 ns/op` |
| `MessageID.computeFromHash` | `339.02 ns/op` |
| `MessageID.compute(source:sequenceNumber:)` | `592.66 ns/op` |
| `Topic.init short` | `105.49 ns/op` |
| `Varint round-trip x10` | `911.28 ns/op` |
| `YamuxFrame encode headerOnly` | `67.35 ns/op` |
| `YamuxFrame encode(into:) headerOnly` | `13.56 ns/op` |

## Profiling Notes

Sampling with `sample` during release benchmark runs showed:

- `GossipSubMessage.Builder.sign` is dominated by `CryptoKit` signature work.
  This path is cryptography-bound rather than allocation-bound now.
- `GossipSubProtobuf.encode control RPC` still spends time in `Data.append`
  during nested control-message construction. This remains a practical next
  target.

## Tests Run Alongside the Optimizations

Focused validation performed during this benchmark cycle included:

- `EnvelopeTests`
- `MultihashTests`
- `PeerRecordTests`
- `IdentifyProtobufTests`
- `PeerIDTests`
- `MessageSigningTests`
- `P2PKademliaTests.*(RoutingTable|KademliaQuery)`
- `P2PMuxYamuxTests.*YamuxFrame`
- `P2PMuxYamuxTests.*YamuxConnection`

## Conclusions

The biggest wins in this cycle came from:

- removing repeated `Data` materialization in wire encode/decode paths
- enabling cross-module specialization for lightweight generic utilities
- avoiding derived-object reconstruction in validation hot paths
- caching serialized forms for frequently reused core identifiers

At this point:

- `verifySignature` is materially faster and no longer spends unnecessary time
  rebuilding `PeerID` values
- `PublicKey` and `Envelope` decode paths are measurably better
- Kademlia and Identify wire encoding improved substantially, especially on
  `encode(into:)` paths

## Recommended Next Targets

1. `GossipSubProtobuf.encode control RPC`
   Current profiling still shows `Data.append` overhead in nested control
   message assembly.

2. `Multihash(bytes:)` decode
   It still uses slice-style decoding and can likely adopt the same 0-based
   offset pattern used successfully in `PublicKey`, `Envelope`, `Identify`, and
   `Kademlia`.

3. `KademliaProtobuf.decode`
   It improved, but it remains the heaviest decode benchmark by a wide margin.
