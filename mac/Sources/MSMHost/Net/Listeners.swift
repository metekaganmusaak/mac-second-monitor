import Foundation
import MSMProtocol
import Network

/// TCP listener for native clients, advertised over Bonjour.
public final class NativeListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.macsecondmonitor.listener.native")
    public var onChannel: (@Sendable (MessageChannel) -> Void)?
    public var onStateChange: (@Sendable (NWListener.State) -> Void)?

    public init(port: UInt16, webPort: UInt16, serviceName: String?, advertise: Bool) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NWError.posix(.EINVAL)
        }
        listener = try NWListener(using: NetworkParameters.tcp(), on: nwPort)
        if advertise {
            let txt = NWTXTRecord(["v": "\(MSMProtocolInfo.version)", "web": "\(webPort)"])
            listener.service = NWListener.Service(name: serviceName, type: MSMProtocolInfo.bonjourServiceType, txtRecord: txt)
        }
    }

    public func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                Log.net.error("Native listener failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.onStateChange?(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.onChannel?(TCPMessageChannel(connection: connection))
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }
}

/// Serves the web client (static files) and upgrades `/ws` to a WebSocket session.
public final class WebServer: @unchecked Sendable {
    private let listener: NWListener
    private let root: URL?
    private let extraOrigins: Set<String>
    public var onChannel: (@Sendable (MessageChannel) -> Void)?
    public var onStateChange: (@Sendable (NWListener.State) -> Void)?

    /// - Parameters:
    ///   - root: directory with the built web client; nil serves a placeholder page.
    ///   - extraOrigins: origins besides the server's own allowed to open the WebSocket
    ///     (e.g. `http://localhost:5173` for the Vite dev server).
    public init(port: UInt16, root: URL?, extraOrigins: Set<String> = []) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NWError.posix(.EINVAL)
        }
        listener = try NWListener(using: NetworkParameters.tcp(), on: nwPort)
        self.root = root?.standardizedFileURL
        self.extraOrigins = extraOrigins
    }

    /// Browsers send `Origin` with every WebSocket handshake. Accepting only our own page stops
    /// any other website open on a device from opening a session (cross-site WebSocket hijacking).
    static func isAllowedOrigin(_ origin: String?, host: String?, extra: Set<String>) -> Bool {
        guard let origin, !origin.isEmpty else { return false }
        if extra.contains(origin) { return true }
        guard let host, !host.isEmpty else { return false }
        return origin == "http://\(host)" || origin == "https://\(host)"
    }

    public func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                Log.net.error("Web server failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.onStateChange?(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: DispatchQueue(label: "com.macsecondmonitor.listener.web"))
    }

    public func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        let queue = DispatchQueue(label: "com.macsecondmonitor.web.connection")
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = buffer[buffer.startIndex..<end.lowerBound]
                let leftover = Data(buffer[end.upperBound...])
                self.handle(String(decoding: head, as: UTF8.self), leftover: leftover, connection: connection)
            } else if error != nil || isComplete || buffer.count > 16 * 1024 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ head: String, leftover: Data, connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else {
            respond(connection, status: "400 Bad Request", type: "text/plain", body: Data())
            return
        }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "/")
        if path == "/ws", headers["upgrade"]?.lowercased() == "websocket" {
            guard let key = headers["sec-websocket-key"],
                  Self.isAllowedOrigin(headers["origin"], host: headers["host"], extra: extraOrigins)
            else {
                Log.net.notice("Rejected WebSocket from origin \(headers["origin"] ?? "none", privacy: .public)")
                respond(connection, status: "403 Forbidden", type: "text/plain", body: Data())
                return
            }
            let response = "HTTP/1.1 101 Switching Protocols\r\n"
                + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(WebSocketMessageChannel.acceptKey(for: key))\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
                self?.onChannel?(WebSocketMessageChannel(connection: connection, leftover: leftover))
            })
            return
        }

        guard method == "GET" || method == "HEAD" else {
            respond(connection, status: "405 Method Not Allowed", type: "text/plain", body: Data())
            return
        }
        guard let (body, type) = file(for: path) else {
            respond(connection, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
            return
        }
        respond(connection, status: "200 OK", type: type, body: method == "HEAD" ? Data() : body, contentLength: body.count)
    }

    private func file(for path: String) -> (Data, String)? {
        guard let root else {
            let html = "<!doctype html><meta charset=utf-8><title>Mac Second Monitor</title><p>Web client not bundled. Build it with <code>npm run build</code> in <code>web/</code>.</p>"
            return path == "/" ? (Data(html.utf8), "text/html; charset=utf-8") : nil
        }
        let relative = path == "/" ? "index.html" : String(path.drop(while: { $0 == "/" }))
        guard let decoded = relative.removingPercentEncoding else { return nil }
        let url = root.appendingPathComponent(decoded).standardizedFileURL
        // Refuse anything that escapes the web root.
        guard url.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: url) else { return nil }
        return (data, Self.contentType(for: url.pathExtension))
    }

    static func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "webmanifest": "application/manifest+json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "ico": "image/x-icon"
        case "wasm": "application/wasm"
        default: "application/octet-stream"
        }
    }

    private func respond(_ connection: NWConnection, status: String, type: String, body: Data, contentLength: Int? = nil) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(contentLength ?? body.count)\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
