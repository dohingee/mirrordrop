import Foundation
import Network

/// Tiny HTTP/1.1 server (GET/HEAD/OPTIONS, keep-alive) for the HLS stream.
/// Only clients with local-network addresses are served.
final class HTTPServer {
    var onReady: ((UInt16) -> Void)?
    var onError: ((String) -> Void)?
    var onRequest: ((HTTPRequest, String, HTTPResponse) -> Void)?

    private let queue = DispatchQueue(label: "com.mirrordrop.http")
    private let router: StreamRouter
    private let snapshot: () -> StreamSnapshot
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private let maxConnections = 16
    private var stopped = false
    private var preferredPort: NWEndpoint.Port = .any
    /// Last port the listener was ready on; a restart tries it first so the stream URL stays the same.
    private var boundPort: NWEndpoint.Port?
    private var retryDelay = HTTPServer.firstRetryDelay
    private var restartAttempts = 0
    private var loggedWaiting = false
    private static let firstRetryDelay = 0.5
    private static let maxRetryDelay = 8.0

    init(router: StreamRouter, snapshot: @escaping () -> StreamSnapshot) {
        self.router = router
        self.snapshot = snapshot
    }

    /// `onReady` can fire again later with a different port if the listener had to be restarted.
    func start(preferredPort: UInt16) {
        queue.async {
            self.preferredPort = NWEndpoint.Port(rawValue: preferredPort) ?? .any
            self.listen(on: self.preferredPort, fallbackToAny: true)
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.listener?.cancel()
            self.listener = nil
            self.connections.values.forEach { $0.close() }
            self.connections.removeAll()
        }
    }

    private func listen(on port: NWEndpoint.Port, fallbackToAny: Bool) {
        guard !stopped else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            onError?("listener create failed: \(error)")
            if fallbackToAny, port != .any, boundPort == nil {
                listen(on: .any, fallbackToAny: false)
            } else {
                scheduleRestart()
            }
            return
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                self.retryDelay = Self.firstRetryDelay
                self.restartAttempts = 0
                self.loggedWaiting = false
                self.boundPort = listener.port
                self.onReady?(listener.port?.rawValue ?? 0)
            case .waiting(let error):
                // Usually no network for the moment; Network.framework retries by itself.
                if !self.loggedWaiting { self.onError?("listener waiting: \(error)") }
                self.loggedWaiting = true
            case .failed(let error):
                self.onError?("listener failed: \(error)")
                listener.cancel()
                self.listener = nil
                if fallbackToAny, port != .any, self.boundPort == nil {
                    // First start and the preferred port is taken: take any port right away.
                    self.listen(on: .any, fallbackToAny: false)
                } else {
                    self.scheduleRestart()
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// A failed listener is reopened (with growing delays) instead of leaving the stream dead,
    /// e.g. after Wi-Fi drops and comes back during a long broadcast. Open connections are kept.
    private func scheduleRestart() {
        guard !stopped, listener == nil else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.listener == nil else { return }
            // Keep the old port for a few tries; if it stays unusable (taken), any port will do
            // (the new port reaches the app through onReady and a new status.url).
            self.restartAttempts += 1
            let port = self.restartAttempts <= 3 ? (self.boundPort ?? self.preferredPort) : .any
            self.listen(on: port, fallbackToAny: false)
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = Self.hostString(connection.endpoint)
        guard NetworkInfo.isPrivate(client) else {
            onError?("rejected non-local client \(client)")
            connection.cancel()
            return
        }
        if connections.count >= maxConnections, let oldest = connections.values.min(by: { $0.createdAt < $1.createdAt }) {
            oldest.close()
        }
        let http = HTTPConnection(connection: connection, client: client, queue: queue) { [weak self] request in
            guard let self else { return HTTPResponse(status: 503) }
            let response = self.router.respond(to: request, snapshot: self.snapshot())
            self.onRequest?(request, client, response)
            return response
        }
        let id = ObjectIdentifier(http)
        http.onClose = { [weak self] in self?.connections[id] = nil }
        connections[id] = http
        http.start()
    }

    static func hostString(_ endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, _) = endpoint {
            switch host {
            case .ipv4(let address): return "\(address)"
            case .ipv6(let address): return "\(address)"
            case .name(let name, _): return name
            @unknown default: return "\(host)"
            }
        }
        return "\(endpoint)"
    }
}

private final class HTTPConnection {
    let createdAt = Date()
    var onClose: (() -> Void)?
    private let connection: NWConnection
    private let client: String
    private let queue: DispatchQueue
    private let handler: (HTTPRequest) -> HTTPResponse
    private var buffer = Data()
    private var closed = false

    init(connection: NWConnection, client: String, queue: DispatchQueue, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.connection = connection
        self.client = client
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
        onClose = nil
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.process()
            }
            if isComplete || error != nil {
                self.close()
            } else if !self.closed {
                self.receive()
            }
        }
    }

    private func process() {
        while !closed {
            switch HTTPParser.parse(buffer) {
            case .incomplete:
                return
            case .invalid:
                let response = HTTPResponse(status: 400, headers: StreamRouter.corsHeaders, body: Data("bad request".utf8))
                send(response.serialized(includeBody: true, keepAlive: false), thenClose: true)
                return
            case let .complete(request, consumed):
                buffer = Data(buffer.dropFirst(consumed))
                let response = handler(request)
                let keepAlive = request.keepAlive
                send(response.serialized(includeBody: request.method != "HEAD", keepAlive: keepAlive), thenClose: !keepAlive)
                if !keepAlive { return }
            }
        }
    }

    private func send(_ data: Data, thenClose: Bool) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if thenClose || error != nil { self?.close() }
        })
    }
}
