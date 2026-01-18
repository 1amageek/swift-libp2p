/// BoringSSL-based TLS 1.3 Provider for QUIC.
///
/// Implements the TLS13Provider protocol using BoringSSL's QUIC-specific API
/// for wire-protocol compatible TLS 1.3 handshakes with rust-libp2p and go-libp2p.
///
/// ## Architecture
///
/// ```
/// BoringSSLTLSProvider (Swift)
///     │
///     ▼
/// CNIOBoringSSL (C/BoringSSL)
///     ├── SSL_QUIC_METHOD callbacks
///     │   ├── set_read_secret()
///     │   ├── set_write_secret()
///     │   ├── add_handshake_data()
///     │   ├── flush_flight()
///     │   └── send_alert()
///     │
///     └── SSL_* functions
///         ├── SSL_CTX_new()
///         ├── SSL_provide_quic_data()
///         ├── SSL_do_handshake()
///         └── SSL_process_quic_post_handshake()
/// ```

import Foundation
import Synchronization
import Crypto
import P2PCore
import QUICCrypto
import QUICCore
@_implementationOnly import CNIOBoringSSL

// MARK: - BoringSSL QUIC TLS Provider

/// TLS 1.3 provider using BoringSSL's native QUIC API.
///
/// This provider uses BoringSSL's `SSL_QUIC_METHOD` to integrate with QUIC transport,
/// providing real TLS 1.3 handshakes that are compatible with other libp2p implementations.
@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, *)
public final class BoringSSLTLSProvider: TLS13Provider, @unchecked Sendable {

    // MARK: - Properties

    /// The local key pair used for libp2p identity.
    private let localKeyPair: KeyPair

    /// The local certificate generated for this connection.
    private let localCertificate: TLSCertificate

    /// Expected remote PeerID (optional, for verification).
    private let expectedRemotePeerID: PeerID?

    /// BoringSSL SSL context.
    private var sslContext: OpaquePointer?

    /// BoringSSL SSL connection.
    private var ssl: OpaquePointer?

    /// QUIC method callbacks.
    private var quicMethod: ssl_quic_method_st

    /// Internal state protected by mutex.
    private let state: Mutex<ProviderState>

    /// Pending secrets for a specific encryption level.
    /// Both read and write secrets must be available before emitting KeysAvailableInfo.
    private struct PendingSecrets: Sendable {
        var readSecret: SymmetricKey?   // For decrypting incoming data
        var writeSecret: SymmetricKey?  // For encrypting outgoing data
    }

    /// State for the TLS provider.
    private struct ProviderState: Sendable {
        var isClient: Bool = false
        var handshakeComplete: Bool = false
        var remotePeerID: PeerID? = nil
        var remoteCertificate: TLSCertificate? = nil
        var localTransportParameters: Data = Data()
        var peerTransportParameters: Data? = nil
        var pendingOutputs: [TLSOutput] = []
        /// Pending secrets per encryption level (waiting for both read and write)
        var pendingSecrets: [EncryptionLevel: PendingSecrets] = [:]
        /// Negotiated ALPN protocol (extracted from BoringSSL after handshake)
        var negotiatedALPN: String? = nil
    }

    // MARK: - Initialization

    /// Creates a new BoringSSL TLS provider.
    ///
    /// - Parameters:
    ///   - localKeyPair: The libp2p identity key pair
    ///   - expectedRemotePeerID: If set, the handshake will fail if the remote
    ///     peer's ID doesn't match (used for dial security)
    /// - Throws: `TLSCertificateError` if certificate generation or SSL context creation fails
    public init(localKeyPair: KeyPair, expectedRemotePeerID: PeerID? = nil) throws {
        self.localKeyPair = localKeyPair
        self.expectedRemotePeerID = expectedRemotePeerID
        self.localCertificate = try TLSCertificate.generate(hostKeyPair: localKeyPair)
        self.state = Mutex(ProviderState())

        // Initialize QUIC method callbacks
        self.quicMethod = ssl_quic_method_st()
        self.quicMethod.set_read_secret = Self.setReadSecretCallback
        self.quicMethod.set_write_secret = Self.setWriteSecretCallback
        self.quicMethod.add_handshake_data = Self.addHandshakeDataCallback
        self.quicMethod.flush_flight = Self.flushFlightCallback
        self.quicMethod.send_alert = Self.sendAlertCallback

        // Create SSL context
        try initializeSSLContext()
    }

    deinit {
        if let ssl = ssl {
            CNIOBoringSSL_SSL_free(ssl)
        }
        if let ctx = sslContext {
            CNIOBoringSSL_SSL_CTX_free(ctx)
        }
    }

    // MARK: - Public Accessors

    /// The local PeerID.
    public var localPeerID: PeerID {
        localKeyPair.peerID
    }

    /// The remote PeerID (available after handshake completes).
    public var remotePeerID: PeerID? {
        state.withLock { $0.remotePeerID }
    }

    /// The remote certificate (available after handshake completes).
    public var remoteCertificate: TLSCertificate? {
        state.withLock { $0.remoteCertificate }
    }

    /// The local certificate used in this connection.
    public var certificate: TLSCertificate {
        localCertificate
    }

    // MARK: - TLS13Provider Protocol

    public func startHandshake(isClient: Bool) async throws -> [TLSOutput] {
        state.withLock { $0.isClient = isClient }

        // Create SSL connection from context
        ssl = CNIOBoringSSL_SSL_new(sslContext)
        guard ssl != nil else {
            throw TLSCertificateError.handshakeFailed(reason: "Failed to create SSL connection")
        }

        // Store self pointer for callbacks
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CNIOBoringSSL_SSL_set_ex_data(ssl, Self.exDataIndex, selfPtr)

        // Set QUIC method on SSL connection
        withUnsafePointer(to: &quicMethod) { methodPtr in
            _ = CNIOBoringSSL_SSL_set_quic_method(ssl, methodPtr)
        }

        // Set local transport parameters
        let transportParams = state.withLock { $0.localTransportParameters }
        if !transportParams.isEmpty {
            transportParams.withUnsafeBytes { ptr in
                _ = CNIOBoringSSL_SSL_set_quic_transport_params(
                    ssl,
                    ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    ptr.count
                )
            }
        }

        // Set client or server mode
        if isClient {
            CNIOBoringSSL_SSL_set_connect_state(ssl)
        } else {
            CNIOBoringSSL_SSL_set_accept_state(ssl)
        }

        // Start handshake
        let result = CNIOBoringSSL_SSL_do_handshake(ssl)

        return collectOutputs(result: result)
    }

    public func processHandshakeData(_ data: Data, at level: EncryptionLevel) async throws -> [TLSOutput] {
        guard let ssl = ssl else {
            throw TLSCertificateError.handshakeFailed(reason: "SSL not initialized")
        }

        let boringLevel = level.toBoringSSL()

        // Provide data to BoringSSL
        let provideResult = data.withUnsafeBytes { ptr -> Int32 in
            CNIOBoringSSL_SSL_provide_quic_data(
                ssl,
                boringLevel,
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                ptr.count
            )
        }

        guard provideResult == 1 else {
            throw TLSCertificateError.handshakeFailed(reason: "Failed to provide QUIC data")
        }

        // Continue handshake
        let result = CNIOBoringSSL_SSL_do_handshake(ssl)

        return collectOutputs(result: result)
    }

    public func getLocalTransportParameters() -> Data {
        state.withLock { $0.localTransportParameters }
    }

    public func setLocalTransportParameters(_ params: Data) throws {
        state.withLock { $0.localTransportParameters = params }
    }

    public func getPeerTransportParameters() -> Data? {
        state.withLock { $0.peerTransportParameters }
    }

    public var isHandshakeComplete: Bool {
        state.withLock { $0.handshakeComplete }
    }

    public var isClient: Bool {
        state.withLock { $0.isClient }
    }

    public var negotiatedALPN: String? {
        // Return negotiated ALPN if handshake is complete, otherwise the expected protocol
        let alpn = state.withLock { $0.negotiatedALPN }
        return alpn ?? TLSCertificate.alpnProtocol
    }

    public func requestKeyUpdate() async throws -> [TLSOutput] {
        // Key updates in QUIC are handled at the QUIC layer, not TLS
        return []
    }

    public func exportKeyingMaterial(label: String, context: Data?, length: Int) throws -> Data {
        guard let ssl = ssl else {
            throw TLSCertificateError.handshakeFailed(reason: "SSL not initialized")
        }

        var output = Data(count: length)
        let result = output.withUnsafeMutableBytes { outPtr -> Int32 in
            let contextPtr = context?.withUnsafeBytes { $0.baseAddress?.assumingMemoryBound(to: UInt8.self) }
            let contextLen = context?.count ?? 0

            return CNIOBoringSSL_SSL_export_keying_material(
                ssl,
                outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                length,
                label,
                label.count,
                contextPtr,
                contextLen,
                context != nil ? 1 : 0
            )
        }

        guard result == 1 else {
            throw TLSCertificateError.handshakeFailed(reason: "Failed to export keying material")
        }

        return output
    }

    // MARK: - Private SSL Context Setup

    private func initializeSSLContext() throws {
        // Create TLS 1.3 context
        sslContext = CNIOBoringSSL_SSL_CTX_new(CNIOBoringSSL_TLS_method())
        guard sslContext != nil else {
            throw TLSCertificateError.handshakeFailed(reason: "Failed to create SSL context")
        }

        // Set minimum TLS version to 1.3
        CNIOBoringSSL_SSL_CTX_set_min_proto_version(sslContext, TLS1_3_VERSION)
        CNIOBoringSSL_SSL_CTX_set_max_proto_version(sslContext, TLS1_3_VERSION)

        // Set QUIC method on context
        withUnsafePointer(to: &quicMethod) { methodPtr in
            _ = CNIOBoringSSL_SSL_CTX_set_quic_method(sslContext, methodPtr)
        }

        // Load certificate
        try loadCertificate()

        // Set ALPN
        setALPN()

        // Set custom certificate verification
        setCustomVerification()
    }

    private func loadCertificate() throws {
        guard let ctx = sslContext else { return }

        // Load certificate from DER
        let certDER = localCertificate.certificateDER
        let x509 = certDER.withUnsafeBytes { ptr -> OpaquePointer? in
            var dataPtr = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return CNIOBoringSSL_d2i_X509(nil, &dataPtr, ptr.count)
        }

        guard let cert = x509 else {
            throw TLSCertificateError.handshakeFailed(reason: "Failed to parse certificate")
        }
        defer { CNIOBoringSSL_X509_free(cert) }

        guard CNIOBoringSSL_SSL_CTX_use_certificate(ctx, cert) == 1 else {
            throw TLSCertificateError.handshakeFailed(reason: "Failed to set certificate")
        }

        // Load private key
        guard let tlsPrivateKey = localCertificate.tlsPrivateKey else {
            throw TLSCertificateError.handshakeFailed(reason: "No private key available")
        }
        let keyDER = tlsPrivateKey.derRepresentation
        let pkey = keyDER.withUnsafeBytes { ptr -> OpaquePointer? in
            var dataPtr = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return CNIOBoringSSL_d2i_PrivateKey(EVP_PKEY_EC, nil, &dataPtr, ptr.count)
        }

        guard let key = pkey else {
            throw TLSCertificateError.handshakeFailed(reason: "Failed to parse private key")
        }
        defer { CNIOBoringSSL_EVP_PKEY_free(key) }

        guard CNIOBoringSSL_SSL_CTX_use_PrivateKey(ctx, key) == 1 else {
            throw TLSCertificateError.handshakeFailed(reason: "Failed to set private key")
        }
    }

    private func setALPN() {
        guard let ctx = sslContext else { return }

        // ALPN protocol: "libp2p"
        let alpn = TLSCertificate.alpnProtocol
        var alpnData = Data([UInt8(alpn.count)])
        alpnData.append(contentsOf: alpn.utf8)

        alpnData.withUnsafeBytes { ptr in
            _ = CNIOBoringSSL_SSL_CTX_set_alpn_protos(
                ctx,
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                ptr.count
            )
        }

        // Set ALPN selection callback for server
        CNIOBoringSSL_SSL_CTX_set_alpn_select_cb(ctx, Self.alpnSelectCallback, nil)
    }

    private func setCustomVerification() {
        guard let ctx = sslContext else { return }

        // Set custom verification mode
        CNIOBoringSSL_SSL_CTX_set_custom_verify(
            ctx,
            SSL_VERIFY_PEER,
            Self.customVerifyCallback
        )
    }

    // MARK: - Output Collection

    private func collectOutputs(result: Int32) -> [TLSOutput] {
        var outputs = state.withLock { s -> [TLSOutput] in
            let pending = s.pendingOutputs
            s.pendingOutputs = []
            return pending
        }

        // Check handshake status
        if result == 1 {
            // Handshake complete
            state.withLock { $0.handshakeComplete = true }

            // Extract peer transport parameters and negotiated ALPN
            if let ssl = ssl {
                var params: UnsafePointer<UInt8>? = nil
                var paramsLen: Int = 0
                CNIOBoringSSL_SSL_get_peer_quic_transport_params(ssl, &params, &paramsLen)
                if let params = params, paramsLen > 0 {
                    let data = Data(bytes: params, count: paramsLen)
                    state.withLock { $0.peerTransportParameters = data }
                }

                // Extract negotiated ALPN from BoringSSL
                var alpnPtr: UnsafePointer<UInt8>? = nil
                var alpnLen: UInt32 = 0
                CNIOBoringSSL_SSL_get0_alpn_selected(ssl, &alpnPtr, &alpnLen)
                if let ptr = alpnPtr, alpnLen > 0 {
                    let alpnData = Data(bytes: ptr, count: Int(alpnLen))
                    let alpn = String(decoding: alpnData, as: UTF8.self)
                    state.withLock { $0.negotiatedALPN = alpn }
                }
            }

            // Use negotiated ALPN if available, otherwise fall back to expected protocol
            let finalALPN = state.withLock { $0.negotiatedALPN } ?? TLSCertificate.alpnProtocol
            outputs.append(.handshakeComplete(HandshakeCompleteInfo(alpn: finalALPN)))
        } else {
            let error = CNIOBoringSSL_SSL_get_error(ssl, result)

            switch error {
            case SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE:
                outputs.append(.needMoreData)

            case SSL_ERROR_SSL:
                // Get error details from BoringSSL error queue
                let errorCode = CNIOBoringSSL_ERR_get_error()
                var reason = "Unknown SSL error"
                if let reasonStr = CNIOBoringSSL_ERR_reason_error_string(errorCode) {
                    reason = String(cString: reasonStr)
                }
                outputs.append(.error(TLSError.handshakeFailed(
                    alert: UInt8(truncatingIfNeeded: errorCode & 0xFF),
                    description: reason
                )))

            case SSL_ERROR_ZERO_RETURN:
                outputs.append(.error(TLSError.handshakeFailed(
                    alert: 0,
                    description: "Connection closed during handshake"
                )))

            case SSL_ERROR_NONE:
                break  // No error, continue

            default:
                outputs.append(.error(TLSError.internalError(
                    "SSL error code: \(error)"
                )))
            }
        }

        return outputs
    }

    // MARK: - Static Callbacks

    /// Index for storing self pointer in SSL ex_data
    private static let exDataIndex: Int32 = {
        CNIOBoringSSL_SSL_get_ex_new_index(0, nil, nil, nil, nil)
    }()

    /// Get self from SSL ex_data
    private static func getSelf(from ssl: OpaquePointer?) -> BoringSSLTLSProvider? {
        guard let ssl = ssl else { return nil }
        guard let ptr = CNIOBoringSSL_SSL_get_ex_data(ssl, exDataIndex) else { return nil }
        return Unmanaged<BoringSSLTLSProvider>.fromOpaque(ptr).takeUnretainedValue()
    }

    /// Callback when BoringSSL derives read secret
    ///
    /// For client: read secret = server traffic secret (decrypt incoming server data)
    /// For server: read secret = client traffic secret (decrypt incoming client data)
    private static let setReadSecretCallback: @convention(c) (
        OpaquePointer?,
        ssl_encryption_level_t,
        OpaquePointer?,
        UnsafePointer<UInt8>?,
        Int
    ) -> Int32 = { ssl, level, cipher, secret, secretLen in
        guard let provider = getSelf(from: ssl),
              let secret = secret else { return 0 }

        let secretData = Data(bytes: secret, count: secretLen)
        let symmetricKey = SymmetricKey(data: secretData)
        let encryptionLevel = EncryptionLevel.from(boringSSL: level)

        provider.state.withLock { s in
            // Store the read secret
            var pending = s.pendingSecrets[encryptionLevel] ?? PendingSecrets()
            pending.readSecret = symmetricKey
            s.pendingSecrets[encryptionLevel] = pending

            // Check if both secrets are now available
            if let readSecret = pending.readSecret, let writeSecret = pending.writeSecret {
                // For client: readSecret = serverSecret, writeSecret = clientSecret
                // For server: readSecret = clientSecret, writeSecret = serverSecret
                let keysInfo: KeysAvailableInfo
                if s.isClient {
                    keysInfo = KeysAvailableInfo(
                        level: encryptionLevel,
                        clientSecret: writeSecret,  // client writes with client secret
                        serverSecret: readSecret    // client reads with server secret
                    )
                } else {
                    keysInfo = KeysAvailableInfo(
                        level: encryptionLevel,
                        clientSecret: readSecret,   // server reads client's data
                        serverSecret: writeSecret   // server writes with server secret
                    )
                }

                s.pendingOutputs.append(.keysAvailable(keysInfo))
                s.pendingSecrets.removeValue(forKey: encryptionLevel)
            }
        }
        return 1
    }

    /// Callback when BoringSSL derives write secret
    ///
    /// For client: write secret = client traffic secret (encrypt outgoing client data)
    /// For server: write secret = server traffic secret (encrypt outgoing server data)
    private static let setWriteSecretCallback: @convention(c) (
        OpaquePointer?,
        ssl_encryption_level_t,
        OpaquePointer?,
        UnsafePointer<UInt8>?,
        Int
    ) -> Int32 = { ssl, level, cipher, secret, secretLen in
        guard let provider = getSelf(from: ssl),
              let secret = secret else { return 0 }

        let secretData = Data(bytes: secret, count: secretLen)
        let symmetricKey = SymmetricKey(data: secretData)
        let encryptionLevel = EncryptionLevel.from(boringSSL: level)

        provider.state.withLock { s in
            // Store the write secret
            var pending = s.pendingSecrets[encryptionLevel] ?? PendingSecrets()
            pending.writeSecret = symmetricKey
            s.pendingSecrets[encryptionLevel] = pending

            // Check if both secrets are now available
            if let readSecret = pending.readSecret, let writeSecret = pending.writeSecret {
                // For client: readSecret = serverSecret, writeSecret = clientSecret
                // For server: readSecret = clientSecret, writeSecret = serverSecret
                let keysInfo: KeysAvailableInfo
                if s.isClient {
                    keysInfo = KeysAvailableInfo(
                        level: encryptionLevel,
                        clientSecret: writeSecret,  // client writes with client secret
                        serverSecret: readSecret    // client reads with server secret
                    )
                } else {
                    keysInfo = KeysAvailableInfo(
                        level: encryptionLevel,
                        clientSecret: readSecret,   // server reads client's data
                        serverSecret: writeSecret   // server writes with server secret
                    )
                }

                s.pendingOutputs.append(.keysAvailable(keysInfo))
                s.pendingSecrets.removeValue(forKey: encryptionLevel)
            }
        }
        return 1
    }

    /// Callback when BoringSSL generates handshake data
    private static let addHandshakeDataCallback: @convention(c) (
        OpaquePointer?,
        ssl_encryption_level_t,
        UnsafePointer<UInt8>?,
        Int
    ) -> Int32 = { ssl, level, data, len in
        guard let provider = getSelf(from: ssl),
              let data = data else { return 0 }

        let handshakeData = Data(bytes: data, count: len)
        let encryptionLevel = EncryptionLevel.from(boringSSL: level)

        provider.state.withLock {
            $0.pendingOutputs.append(.handshakeData(handshakeData, level: encryptionLevel))
        }
        return 1
    }

    /// Callback when handshake flight is complete
    private static let flushFlightCallback: @convention(c) (OpaquePointer?) -> Int32 = { ssl in
        // No action needed - outputs are collected after handshake call
        return 1
    }

    /// Callback when BoringSSL wants to send an alert
    private static let sendAlertCallback: @convention(c) (
        OpaquePointer?,
        ssl_encryption_level_t,
        UInt8
    ) -> Int32 = { ssl, level, alert in
        guard let provider = getSelf(from: ssl) else { return 0 }

        let error = TLSError.handshakeFailed(alert: alert, description: "TLS alert received")

        provider.state.withLock {
            $0.pendingOutputs.append(.error(error))
        }
        return 1
    }

    /// ALPN selection callback for server
    private static let alpnSelectCallback: @convention(c) (
        OpaquePointer?,
        UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
        UnsafeMutablePointer<UInt8>?,
        UnsafePointer<UInt8>?,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32 = { ssl, outPtr, outLen, clientProtos, clientProtosLen, arg in
        // Check if client supports "libp2p"
        let alpn = TLSCertificate.alpnProtocol
        guard let clientProtos = clientProtos else {
            return SSL_TLSEXT_ERR_NOACK
        }

        var offset: UInt32 = 0
        while offset < clientProtosLen {
            let protoLen = Int(clientProtos.advanced(by: Int(offset)).pointee)
            offset += 1

            if offset + UInt32(protoLen) > clientProtosLen { break }

            let protoBytes = UnsafeBufferPointer(
                start: clientProtos.advanced(by: Int(offset)),
                count: protoLen
            )
            let proto = String(decoding: protoBytes, as: UTF8.self)

            if proto == alpn {
                outPtr?.pointee = clientProtos.advanced(by: Int(offset))
                outLen?.pointee = UInt8(protoLen)
                return SSL_TLSEXT_ERR_OK
            }

            offset += UInt32(protoLen)
        }

        return SSL_TLSEXT_ERR_NOACK
    }

    /// Custom certificate verification callback
    private static let customVerifyCallback: @convention(c) (
        OpaquePointer?,
        UnsafeMutablePointer<UInt8>?
    ) -> ssl_verify_result_t = { ssl, outAlert in
        guard let provider = getSelf(from: ssl) else {
            outAlert?.pointee = UInt8(SSL_AD_INTERNAL_ERROR)
            return ssl_verify_invalid
        }

        // Get peer certificate
        guard let peerCert = CNIOBoringSSL_SSL_get_peer_certificate(ssl) else {
            // No peer certificate - fail for mutual TLS
            outAlert?.pointee = UInt8(SSL_AD_CERTIFICATE_REQUIRED)
            return ssl_verify_invalid
        }
        defer { CNIOBoringSSL_X509_free(peerCert) }

        // Extract DER from X509
        var derPtr: UnsafeMutablePointer<UInt8>? = nil
        let derLen = CNIOBoringSSL_i2d_X509(peerCert, &derPtr)
        guard derLen > 0, let der = derPtr else {
            outAlert?.pointee = UInt8(SSL_AD_BAD_CERTIFICATE)
            return ssl_verify_invalid
        }
        defer { CNIOBoringSSL_OPENSSL_free(der) }

        let certData = Data(bytes: der, count: Int(derLen))

        // Parse and verify libp2p certificate
        do {
            let tlsCert = try TLSCertificate.parse(certData)

            // Verify signature
            guard try tlsCert.verify() else {
                outAlert?.pointee = UInt8(SSL_AD_BAD_CERTIFICATE)
                return ssl_verify_invalid
            }

            let remotePeerID = tlsCert.peerID

            // Check expected PeerID if set
            if let expected = provider.expectedRemotePeerID, expected != remotePeerID {
                outAlert?.pointee = UInt8(SSL_AD_BAD_CERTIFICATE)
                return ssl_verify_invalid
            }

            // Store remote info
            provider.state.withLock { s in
                s.remotePeerID = remotePeerID
                s.remoteCertificate = tlsCert
            }

            return ssl_verify_ok
        } catch {
            outAlert?.pointee = UInt8(SSL_AD_BAD_CERTIFICATE)
            return ssl_verify_invalid
        }
    }
}

// MARK: - EncryptionLevel Extension

extension EncryptionLevel {
    /// Convert from BoringSSL encryption level
    static func from(boringSSL level: ssl_encryption_level_t) -> EncryptionLevel {
        switch level {
        case ssl_encryption_initial:
            return .initial
        case ssl_encryption_early_data:
            return .zeroRTT
        case ssl_encryption_handshake:
            return .handshake
        case ssl_encryption_application:
            return .application
        default:
            return .initial
        }
    }

    /// Convert to BoringSSL encryption level
    func toBoringSSL() -> ssl_encryption_level_t {
        switch self {
        case .initial:
            return ssl_encryption_initial
        case .zeroRTT:
            return ssl_encryption_early_data
        case .handshake:
            return ssl_encryption_handshake
        case .application:
            return ssl_encryption_application
        }
    }
}

// MARK: - BoringSSL Constants

private let TLS1_3_VERSION: UInt16 = 0x0304
private let SSL_ERROR_NONE: Int32 = 0
private let SSL_ERROR_SSL: Int32 = 1
private let SSL_ERROR_WANT_READ: Int32 = 2
private let SSL_ERROR_WANT_WRITE: Int32 = 3
private let SSL_ERROR_ZERO_RETURN: Int32 = 6
private let SSL_VERIFY_PEER: Int32 = 1
private let SSL_TLSEXT_ERR_OK: Int32 = 0
private let SSL_TLSEXT_ERR_NOACK: Int32 = 3
private let SSL_AD_INTERNAL_ERROR: Int32 = 80
private let SSL_AD_CERTIFICATE_REQUIRED: Int32 = 116
private let SSL_AD_BAD_CERTIFICATE: Int32 = 42
private let EVP_PKEY_EC: Int32 = 408
