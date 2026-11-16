import Foundation
import Network

/// Volume of AirPlay receivers that also accept Denon/Marantz network control (TCP 23, "MV?" / "MVnn").
/// For receivers that ignore AirPlay volume. All calls block, so they run off the main thread.
final class ReceiverControl: @unchecked Sendable {
    private struct Receiver {
        let host: NWEndpoint.Host
    }

    private static let port: NWEndpoint.Port = 23
    private static let timeout: TimeInterval = 2
    /// How long a receiver found not to accept control is skipped before being probed again.
    private static let retryAfter: TimeInterval = 60

    private let queue = DispatchQueue(label: "com.morrishoresh.AudioControl.receiver")
    private let lock = NSLock()
    private var receivers: [String: Receiver] = [:]
    private var unsupported: [String: Date] = [:]

    /// Receiver volume as 0–100% of its volume limit (MVMAX), or nil if the receiver does not accept control.
    func volume(airPlayName name: String) -> Int? {
        guard let receiver = receiver(name), let state = query(receiver.host) else { return nil }
        return Int((Double(state.volume) / Double(state.max) * 100).rounded())
    }

    /// Sets the receiver volume to `percent` of its volume limit. Returns false if the receiver does not accept control.
    @discardableResult
    func setVolume(airPlayName name: String, _ percent: Int) -> Bool {
        guard let receiver = receiver(name), let state = query(receiver.host) else { return false }
        let level = Int((Double(state.max) * Double(min(max(percent, 0), 100)) / 100).rounded())
        return send(String(format: "MV%02d", level), to: receiver.host, wait: 0.2) != nil
    }

    // MARK: - Helpers

    /// Current level and volume limit, from the reply to "MV?" ("MV40", "MV405" for 40.5, "MVMAX 60").
    private func query(_ host: NWEndpoint.Host) -> (volume: Double, max: Double)? {
        guard let lines = send("MV?", to: host, wait: 0.4) else { return nil }
        var volume: Double?
        var limit = 98.0
        for line in lines where line.hasPrefix("MV") {
            let value = line.dropFirst(2)
            if value.hasPrefix("MAX") {
                limit = Double(value.dropFirst(3).trimmingCharacters(in: .whitespaces)).map(Self.level) ?? limit
            } else if let raw = Double(value) {
                volume = Self.level(raw)
            }
        }
        guard let volume, limit > 0 else { return nil }
        return (volume, limit)
    }

    /// "405" means 40.5; two-digit values are whole levels.
    private static func level(_ raw: Double) -> Double {
        raw >= 100 ? raw / 10 : raw
    }

    private func receiver(_ name: String) -> Receiver? {
        lock.lock()
        if let receiver = receivers[name] {
            lock.unlock()
            return receiver
        }
        if let since = unsupported[name], Date().timeIntervalSince(since) < Self.retryAfter {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let found = resolve(name).flatMap { host in send("MV?", to: host, wait: 0.4)?.contains { $0.hasPrefix("MV") } == true ? host : nil }
        lock.lock()
        defer { lock.unlock() }
        if let found {
            receivers[name] = Receiver(host: found)
            return receivers[name]
        }
        unsupported[name] = Date()
        return nil
    }

    /// Address of the AirPlay receiver advertised under `name`.
    private func resolve(_ name: String) -> NWEndpoint.Host? {
        let endpoint = NWEndpoint.service(name: name, type: "_airplay._tcp", domain: "local.", interface: nil)
        // Receivers' control port may listen on IPv4 only, so resolve to an IPv4 address.
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        let done = DispatchSemaphore(value: 0)
        var host: NWEndpoint.Host?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case let .hostPort(resolved, _)? = connection.currentPath?.remoteEndpoint {
                    host = resolved
                }
                done.signal()
            case .failed, .cancelled:
                done.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        _ = done.wait(timeout: .now() + Self.timeout)
        connection.cancel()
        return host
    }

    /// Sends `command` and returns the reply lines received within `wait`, or nil if the connection failed.
    private func send(_ command: String, to host: NWEndpoint.Host, wait: TimeInterval) -> [String]? {
        let connection = NWConnection(host: host, port: Self.port, using: .tcp)
        let ready = DispatchSemaphore(value: 0)
        var isReady = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                isReady = true
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        defer { connection.cancel() }
        guard ready.wait(timeout: .now() + Self.timeout) == .success, isReady else { return nil }

        connection.send(content: Data((command + "\r").utf8), completion: .contentProcessed { _ in })
        var received = Data()
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            let chunk = DispatchSemaphore(value: 0)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                if let data { received.append(data) }
                chunk.signal()
            }
            if chunk.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { break }
        }
        return String(decoding: received, as: UTF8.self)
            .split(separator: "\r")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
