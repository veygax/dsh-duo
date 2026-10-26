import Foundation

/// Sealed, self-healing connection from the phone to its dsh Host through the relay.
@MainActor
final class RelayClient {
    enum State: Equatable {
        case idle
        case connecting
        /// Socket open; `host` says whether the dsh process is currently attached.
        case online(host: Bool)
        case failed(String)
    }

    let pairing: Pairing
    private let crypto: DuoCrypto
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var attempt = 0
    private var wanted = false
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var pingTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    var onState: ((State) -> Void)?
    var onEvent: ((JSONValue) -> Void)?

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onState?(state) } }
    }

    init?(pairing: Pairing) {
        guard let crypto = pairing.crypto else { return nil }
        self.pairing = pairing
        self.crypto = crypto
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    var hostOnline: Bool { state == .online(host: true) }

    func connect() {
        wanted = true
        guard task == nil else { return }
        open()
    }

    /// Close the socket so the relay pushes notifications instead of streaming to a suspended app.
    func disconnect() {
        wanted = false
        retryTask?.cancel()
        teardown(reason: "Disconnected")
        state = .idle
    }

    private func socketURL() -> URL? {
        guard var components = URLComponents(url: pairing.relay, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/v1/rooms/\(pairing.roomId)"
        components.queryItems = [
            URLQueryItem(name: "role", value: "device"),
            URLQueryItem(name: "auth", value: crypto.relayAuth),
            URLQueryItem(name: "device", value: pairing.deviceId),
        ]
        return components.url
    }

    private func open() {
        guard let url = socketURL() else {
            state = .failed("The pairing link is invalid")
            return
        }
        generation += 1
        let current = generation
        state = .connecting
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 8 * 1024 * 1024
        self.task = task
        task.resume()
        receive(task, generation: current)
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.generation == current else { return }
                self.sendRaw(["t": "ping"])
            }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, generation current: Int) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                switch result {
                case .success(let message):
                    self.attempt = 0
                    switch message {
                    case .string(let text): self.handle(frame: text)
                    case .data(let data): self.handle(frame: String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                    self.receive(task, generation: current)
                case .failure(let error):
                    self.dropped(error)
                }
            }
        }
    }

    private func dropped(_ error: Error) {
        let closeCode = task?.closeCode
        let status = (task?.response as? HTTPURLResponse)?.statusCode
        teardown(reason: "Connection lost")
        guard wanted else { return }
        if status == 401 || status == 404 {
            state = .failed(status == 401
                ? "This pairing was replaced on \(pairing.hostName). Scan the new QR code."
                : "\(pairing.hostName) has not connected to the relay yet. Start dsh with the duo-remote plugin.")
            if status == 401 { return }
        } else if closeCode?.rawValue == 4000 {
            state = .failed("Another app session took over this connection")
        } else {
            state = .connecting
        }
        let delay = min(30.0, pow(2.0, Double(attempt)))
        attempt += 1
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay * Double.random(in: 0.6...1.0)))
            guard let self, !Task.isCancelled, self.wanted, self.task == nil else { return }
            self.open()
        }
    }

    private func teardown(reason: String) {
        generation += 1
        pingTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        failPending(RemoteError(code: "duo/disconnected", message: reason))
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    private func handle(frame text: String) {
        guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return }
        switch frame["t"]?.string {
        case "host":
            let online = frame["online"]?.bool == true
            state = .online(host: online)
            if !online { failPending(RemoteError(code: "duo/host-offline", message: "dsh is not running on \(pairing.hostName)")) }
        case "msg":
            guard let sealed = frame["d"]?.string, let data = crypto.open(sealed),
                  let message = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
            if let re = message["re"]?.number.map(Int.init) {
                guard let continuation = pending.removeValue(forKey: re) else { return }
                if message["ok"]?.bool == true {
                    continuation.resume(returning: message["value"] ?? .null)
                } else {
                    continuation.resume(throwing: RemoteError(
                        code: message["error"]?["code"]?.string ?? "duo/error",
                        message: message["error"]?["message"]?.string ?? "Request failed"))
                }
            } else {
                onEvent?(message)
            }
        default:
            break
        }
    }

    private func sendRaw(_ frame: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    /// Send one request and await its response.
    func request(_ op: String, _ params: [String: Any] = [:], timeout: Duration = .seconds(45)) async throws -> JSONValue {
        guard task != nil, hostOnline else {
            throw RemoteError(code: "duo/host-offline", message: state == .online(host: false)
                ? "dsh is not running on \(pairing.hostName)" : "Not connected to \(pairing.hostName)")
        }
        let id = nextId
        nextId += 1
        var body = params
        body["id"] = id
        body["op"] = op
        let sealed = try crypto.seal(json: body)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            sendRaw(["t": "msg", "d": sealed])
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let waiting = self.pending.removeValue(forKey: id) else { return }
                waiting.resume(throwing: RemoteError(code: "duo/timeout", message: "\(self.pairing.hostName) did not answer in time"))
            }
        }
    }

    func decode<T: Decodable>(_ op: String, _ params: [String: Any] = [:], as type: T.Type = T.self) async throws -> T {
        try await request(op, params).decode(T.self)
    }

    /// Deliver one fire-and-forget request without a socket, e.g. from a notification reply.
    nonisolated static func post(_ pairing: Pairing, op: String, params: [String: Any]) async throws {
        guard let crypto = pairing.crypto else { throw RemoteError(code: "duo/pairing", message: "Not paired") }
        var body = params
        body["op"] = op
        let sealed = try crypto.seal(json: body)
        var request = URLRequest(url: pairing.relay.appending(path: "v1/rooms/\(pairing.roomId)/send"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(crypto.relayAuth)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["device": pairing.deviceId, "d": sealed])
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 202 else {
            throw RemoteError(code: "duo/post", message: status == 503 ? "dsh is offline" : "Relay refused (\(status))")
        }
    }
}
