// EmbeddedLogShim.swift
// A no-op logging shim for the Embedded node. swift-log's `Logger` pulls in
// Foundation and an `any`-typed metadata bag, neither of which is available under
// Embedded. The Embedded data path emits no logs; this shim gives call sites a
// uniform sink that the optimiser elides entirely (the methods are empty inlinable
// no-ops). It is NOT a silent error fallback — every failure on the data path is a
// typed throw; logging is purely diagnostic.

/// A no-op logger for the Embedded data path.
///
/// All methods are empty `@inlinable` no-ops; under `-c release` + `-wmo` the
/// optimiser removes every call. This keeps the Embedded surface free of swift-log
/// (Foundation + `any` metadata) while letting code read naturally.
public struct EmbeddedLog: Sendable {
    @inlinable
    public init() {}

    @inlinable
    public func trace(_ message: @autoclosure () -> StaticString) {}

    @inlinable
    public func debug(_ message: @autoclosure () -> StaticString) {}

    @inlinable
    public func info(_ message: @autoclosure () -> StaticString) {}

    @inlinable
    public func warning(_ message: @autoclosure () -> StaticString) {}

    @inlinable
    public func error(_ message: @autoclosure () -> StaticString) {}
}
