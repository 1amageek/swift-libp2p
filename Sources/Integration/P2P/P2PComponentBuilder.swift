import P2PCore
import P2PDiscovery
import P2PMux
import P2PProtocols
import P2PRuntime
import P2PSecurity
import P2PTransport

public protocol NodeComponent: Sendable {
    var nodeGroup: NodeGroup { get }
}

public struct NodeGroup: NodeComponent {
    fileprivate let components: [any NodeComponent]

    public init() {
        self.components = []
    }

    fileprivate init(components: [any NodeComponent]) {
        self.components = components
    }

    public init(@P2PComponentBuilder _ content: () -> NodeGroup) {
        self.components = content().components
    }

    public var nodeGroup: NodeGroup {
        self
    }

    package func resolve(into services: inout [ServiceComponent], discovery: inout [DiscoveryComponent]) {
        for component in components {
            if let serviceComponent = component as? ServiceComponent {
                services.append(serviceComponent)
                continue
            }
            if let discoveryComponent = component as? DiscoveryComponent {
                discovery.append(discoveryComponent)
                continue
            }
            component.nodeGroup.resolve(into: &services, discovery: &discovery)
        }
    }
}

extension ServiceComponent: NodeComponent {
    public var nodeGroup: NodeGroup {
        NodeGroup(components: [self])
    }
}

extension DiscoveryComponent: NodeComponent {
    public var nodeGroup: NodeGroup {
        NodeGroup(components: [self])
    }
}

@resultBuilder
public enum P2PComponentBuilder {
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
        component.nodeGroup
    }

    public static func buildExpression(_ components: [any NodeComponent]) -> NodeGroup {
        NodeGroup(components: components.flatMap { $0.nodeGroup.components })
    }

    public static func buildExpression(_ components: [ServiceComponent]) -> NodeGroup {
        NodeGroup(components: components.map { $0 as any NodeComponent })
    }

    public static func buildExpression(_ components: [DiscoveryComponent]) -> NodeGroup {
        NodeGroup(components: components.map { $0 as any NodeComponent })
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
    func resolveNodeComponents() -> ResolvedNodeComponents {
        var services: [ServiceComponent] = []
        var discovery: [DiscoveryComponent] = []
        nodeGroup.resolve(into: &services, discovery: &discovery)
        return ResolvedNodeComponents(services: services, discovery: discovery)
    }
}
