/// Errors that can occur while resolving a ``NodeComponent`` DSL into its
/// concrete service and discovery pipelines.
public enum NodeCompositionError: Error, Sendable, CustomStringConvertible {
    /// A NodeComponent's body expansion produced a cycle.
    ///
    /// The component identified by `componentType` appeared recursively in its
    /// own body expansion chain, either directly (its `body` returns itself)
    /// or transitively (through another component's `body`).
    case recursionCycleDetected(componentType: String)

    public var description: String {
        switch self {
        case .recursionCycleDetected(let type):
            return "NodeComponent body expansion detected a cycle: \(type) appears recursively in its own body. This usually indicates a NodeComponent whose `body` returns itself directly or transitively."
        }
    }
}
