/// `[UInt8]` <-> `Data` equality bridges.
///
/// The Embedded-clean core (``LibP2PCore``) stores byte fields as `[UInt8]`.
/// These overloads let existing call sites (and tests) compare those fields
/// directly against Foundation `Data` values without an explicit conversion,
/// preserving the historical behaviour where the same fields were `Data`.

import Foundation

public func == (lhs: [UInt8], rhs: Data) -> Bool { lhs == [UInt8](rhs) }
public func == (lhs: Data, rhs: [UInt8]) -> Bool { [UInt8](lhs) == rhs }
public func != (lhs: [UInt8], rhs: Data) -> Bool { !(lhs == rhs) }
public func != (lhs: Data, rhs: [UInt8]) -> Bool { !(lhs == rhs) }

// Optional forms.
public func == (lhs: [UInt8]?, rhs: Data) -> Bool { lhs.map { $0 == rhs } ?? false }
public func == (lhs: Data, rhs: [UInt8]?) -> Bool { rhs.map { lhs == $0 } ?? false }
public func != (lhs: [UInt8]?, rhs: Data) -> Bool { !(lhs == rhs) }
public func != (lhs: Data, rhs: [UInt8]?) -> Bool { !(lhs == rhs) }

public func == (lhs: [UInt8], rhs: Data?) -> Bool { rhs.map { lhs == $0 } ?? false }
public func == (lhs: Data?, rhs: [UInt8]) -> Bool { lhs.map { $0 == rhs } ?? false }
public func != (lhs: [UInt8], rhs: Data?) -> Bool { !(lhs == rhs) }
public func != (lhs: Data?, rhs: [UInt8]) -> Bool { !(lhs == rhs) }
