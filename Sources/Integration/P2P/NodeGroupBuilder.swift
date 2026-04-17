import P2PCore
import P2PDiscovery
import P2PMux
import P2PProtocols
import P2PRuntime
import P2PSecurity
import P2PTransport

public protocol NodeComponent: Sendable {
    associatedtype Body: NodeComponent
    var body: Body { get }
}

extension Never: NodeComponent {
    public typealias Body = Never

    public var body: Never {
        switch self {}
    }
}

protocol _NodePrimitiveComponent: NodeComponent where Body == Never {
    func _resolvePrimitive(
        into services: inout [ServiceComponent],
        discovery: inout [DiscoveryComponent]
    ) throws
}

extension _NodePrimitiveComponent {
    public var body: Never {
        fatalError("Primitive node components do not expose a composite body.")
    }
}

struct _AnyNodeComponent: Sendable {
    private let resolver: @Sendable (
        Set<String>,
        inout [ServiceComponent],
        inout [DiscoveryComponent]
    ) throws -> Void

    init<Component: NodeComponent>(_ component: Component) {
        // NodeGroup: iterate children, propagating `visited` unchanged so
        // siblings see the same inherited set. Siblings of the same type are
        // not a cycle; cycles arise only along a single `body` expansion chain.
        if let group = component as? NodeGroup {
            self.resolver = { visited, services, discovery in
                for child in group.components {
                    try child.resolve(visited: visited, into: &services, discovery: &discovery)
                }
            }
            return
        }

        // Other primitives are terminal — they append themselves and stop.
        if let primitive = component as? any _NodePrimitiveComponent {
            self.resolver = { _, services, discovery in
                try primitive._resolvePrimitive(into: &services, discovery: &discovery)
            }
            return
        }

        // Non-primitive: expand `body`, detecting cycles by type name.
        let componentTypeName = String(reflecting: Component.self)
        self.resolver = { visited, services, discovery in
            guard !visited.contains(componentTypeName) else {
                throw NodeCompositionError.recursionCycleDetected(componentType: componentTypeName)
            }
            var next = visited
            next.insert(componentTypeName)
            try _AnyNodeComponent(component.body).resolve(
                visited: next,
                into: &services,
                discovery: &discovery
            )
        }
    }

    func resolve(
        visited: Set<String> = [],
        into services: inout [ServiceComponent],
        discovery: inout [DiscoveryComponent]
    ) throws {
        try resolver(visited, &services, &discovery)
    }
}

private func eraseNodeComponent(_ component: some NodeComponent) -> _AnyNodeComponent {
    _AnyNodeComponent(component)
}

public struct NodeGroup: _NodePrimitiveComponent {
    public typealias Body = Never

    fileprivate let components: [_AnyNodeComponent]

    public init() {
        self.components = []
    }

    fileprivate init(components: [_AnyNodeComponent]) {
        self.components = components
    }

    public init(@NodeGroupBuilder _ content: () -> NodeGroup) {
        self.components = content().components
    }

    func _resolvePrimitive(
        into services: inout [ServiceComponent],
        discovery: inout [DiscoveryComponent]
    ) throws {
        for component in components {
            try component.resolve(into: &services, discovery: &discovery)
        }
    }
}

extension ServiceComponent: _NodePrimitiveComponent {
    public typealias Body = Never

    func _resolvePrimitive(
        into services: inout [ServiceComponent],
        discovery: inout [DiscoveryComponent]
    ) {
        services.append(self)
    }
}

extension DiscoveryComponent: _NodePrimitiveComponent {
    public typealias Body = Never

    func _resolvePrimitive(
        into services: inout [ServiceComponent],
        discovery: inout [DiscoveryComponent]
    ) {
        discovery.append(self)
    }
}

@resultBuilder
public enum NodeGroupBuilder {
    public static func buildBlock() -> NodeGroup {
        NodeGroup()
    }

    public static func buildBlock(_ components: NodeGroup...) -> NodeGroup {
        NodeGroup(components: components.flatMap(\.components))
    }

    public static func buildArray(_ components: [NodeGroup]) -> NodeGroup {
        NodeGroup(components: components.flatMap(\.components))
    }

    public static func buildEither(first component: NodeGroup) -> NodeGroup {
        component
    }

    public static func buildEither(second component: NodeGroup) -> NodeGroup {
        component
    }

    public static func buildOptional(_ component: NodeGroup?) -> NodeGroup {
        component ?? NodeGroup()
    }

    public static func buildExpression<Component: NodeComponent>(
        _ component: Component
    ) -> NodeGroup {
        NodeGroup(components: [_AnyNodeComponent(component)])
    }

    public static func buildExpression(_ components: [any NodeComponent]) -> NodeGroup {
        NodeGroup(components: components.map { eraseNodeComponent($0) })
    }

    public static func buildExpression(_ components: [ServiceComponent]) -> NodeGroup {
        NodeGroup(components: components.map(_AnyNodeComponent.init))
    }

    public static func buildExpression(_ components: [DiscoveryComponent]) -> NodeGroup {
        NodeGroup(components: components.map(_AnyNodeComponent.init))
    }
}

struct ResolvedNodeComponents: Sendable {
    let services: [ServiceComponent]
    let discovery: [DiscoveryComponent]

    static let empty = ResolvedNodeComponents(services: [], discovery: [])

    func servicePipeline() -> ServicePipeline {
        ServicePipeline {
            services
        }
    }

    func discoveryPipeline(localPeerID: PeerID) -> DiscoveryPipeline? {
        guard !discovery.isEmpty else {
            return nil
        }

        return DiscoveryPipeline(localPeerID: localPeerID) {
            discovery
        }
    }
}

extension NodeComponent {
    func resolveNodeComponents() throws -> ResolvedNodeComponents {
        var services: [ServiceComponent] = []
        var discovery: [DiscoveryComponent] = []
        try _AnyNodeComponent(self).resolve(into: &services, discovery: &discovery)
        return ResolvedNodeComponents(services: services, discovery: discovery)
    }
}
