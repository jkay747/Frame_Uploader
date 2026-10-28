import Foundation
import Network

/// The raw TCP socket the TV opens for each image transfer ("device to device").
enum D2DSocket {
    private static let queue = DispatchQueue(label: "FrameUploader.D2DSocket")

    static func open(host: String, port: Int, secured: Bool) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw FrameTVError.badResponse("invalid upload port \(port)")
        }

        let parameters: NWParameters
        if secured {
            let tls = NWProtocolTLS.Options()
            // The TV's certificate is self-signed; this socket only ever goes to the address the TV gave us.
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
                complete(true)
            }, queue)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let once = ResumeOnce()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    once.run { continuation.resume(throwing: FrameTVError.connectionLost(error.localizedDescription)) }
                    connection.cancel()
                case .cancelled:
                    once.run { continuation.resume(throwing: FrameTVError.timeout("opening the upload connection")) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) {
                if !once.hasRun { connection.cancel() }
            }
        }
        connection.stateUpdateHandler = nil
        return connection
    }

    static func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: FrameTVError.connectionLost(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

/// Makes sure a continuation is resumed exactly once when several callbacks race.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    var hasRun: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func run(_ body: () -> Void) {
        lock.lock()
        let shouldRun = !done
        done = true
        lock.unlock()
        if shouldRun { body() }
    }
}
