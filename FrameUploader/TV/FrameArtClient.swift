import Foundation
import Network
import os

enum FrameTVError: LocalizedError {
    case invalidHost(String)
    case notConnected
    case unauthorized
    case connectionLost(String)
    case timeout(String)
    case tvError(request: String, code: String)
    case badResponse(String)
    /// The photo was sent, but the TV never said it had saved it.
    case uploadNotConfirmed

    var errorDescription: String? {
        switch self {
        case .invalidHost(let host):
            return "“\(host)” isn't a valid TV address."
        case .notConnected:
            return "Not connected to the TV."
        case .unauthorized:
            return "The TV refused the connection. Try again and select Allow on the TV when it asks."
        case .connectionLost(let reason):
            return "Lost the connection to the TV (\(reason)). Make sure the TV is on or in Art Mode."
        case .timeout(let what):
            return "The TV didn't respond in time (\(what))."
        case .tvError("send_image", let code):
            return "The TV refused this photo (Samsung error \(code)). Its photo storage may be full. Try deleting some photos from My Photos on the TV, then upload again."
        case .tvError("change_matte", let code):
            return "The TV couldn't apply the mat to this photo (Samsung error \(code))."
        case .tvError(let request, let code):
            return "The TV rejected the “\(request)” request (Samsung error \(code))."
        case .badResponse(let what):
            return "Unexpected response from the TV (\(what))."
        case .uploadNotConfirmed:
            return "The photo was sent, but the TV never confirmed it saved it. The TV may have gone to sleep or been busy. Try uploading it again."
        }
    }

    /// The TV didn't answer at all, as opposed to answering with a refusal.
    var isUnreachable: Bool {
        switch self {
        case .connectionLost, .timeout: return true
        default: return false
        }
    }

    /// The connection dropped, which a fresh connection can fix (unlike a refusal or a bad address).
    var isConnectionDrop: Bool {
        switch self {
        case .notConnected, .connectionLost: return true
        default: return false
        }
    }

    /// Errors that mean the connection itself is unusable, so the rest of a batch should stop.
    var isConnectionFatal: Bool {
        switch self {
        case .invalidHost, .notConnected, .unauthorized, .connectionLost: return true
        case .timeout, .tvError, .badResponse, .uploadNotConfirmed: return false
        }
    }
}

/// One JSON frame received from the TV's websocket.
struct TVMessage: @unchecked Sendable {
    let json: [String: Any]

    var event: String? { json["event"] as? String }

    /// Art-app replies arrive as `d2d_service_message` events whose `data` is itself a JSON string.
    var d2d: [String: Any]? {
        guard event == "d2d_service_message" else { return nil }
        if let dict = json["data"] as? [String: Any] { return dict }
        guard let text = json["data"] as? String else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    static func parse(_ data: Data) -> TVMessage? {
        if let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return TVMessage(json: dict)
        }
        // Some firmware appends binary data after the JSON object; keep just the object.
        let bytes = [UInt8](data)
        guard let start = bytes.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        var depth = 0
        for index in start..<bytes.count {
            if bytes[index] == UInt8(ascii: "{") { depth += 1 }
            if bytes[index] == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 {
                    let slice = Data(bytes[start...index])
                    guard let dict = (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any] else { return nil }
                    return TVMessage(json: dict)
                }
            }
        }
        return nil
    }
}

/// Talks to the Art Mode service of a 2022-or-newer Samsung Frame TV.
///
/// Protocol: a websocket on wss://<tv>:8002/api/v2/channels/com.samsung.art-app carries JSON requests
/// (`art_app_request`) and replies (`d2d_service_message`). Image bytes go over a separate TCP socket
/// that the TV opens for each upload.
actor FrameArtClient {
    static let myPhotosCategory = "MY-C0002"
    private static let log = Logger(subsystem: "com.kay2ventures.FrameUploader", category: "tv")

    let host: String
    private let clientName = "Frame Uploader"
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var waiters: [Waiter] = []

    init(host: String) {
        self.host = host
    }

    // MARK: - Connection

    /// Connects (pairing on first use) and returns a new token when the TV issues one.
    /// The first time, the TV shows an "Allow" prompt; this waits up to a minute for it.
    func connect(token: String?) async throws -> String? {
        guard !host.isEmpty, !host.contains(" ") else { throw FrameTVError.invalidHost(host) }

        let name = Data(clientName.utf8).base64EncodedString()
        var query = "name=\(Self.percentEncode(name))"
        if let token, !token.isEmpty {
            query += "&token=\(Self.percentEncode(token))"
        }
        guard let url = URL(string: "wss://\(host):8002/api/v2/channels/com.samsung.art-app?\(query)") else {
            throw FrameTVError.invalidHost(host)
        }

        let session = URLSession(
            configuration: .ephemeral,
            delegate: LocalTVTrustDelegate(host: host),
            delegateQueue: nil
        )
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 64 * 1024 * 1024
        self.session = session
        self.socket = socket

        let connected = register { message in
            switch message.event ?? "" {
            case "ms.channel.connect":
                return true
            case "ms.channel.unauthorized":
                throw FrameTVError.unauthorized
            case "ms.error":
                let detail = (message.json["data"] as? [String: Any])?["message"] as? String
                throw FrameTVError.connectionLost(detail ?? "TV reported an error")
            default:
                return false
            }
        }
        let ready = register { $0.event == "ms.channel.ready" }

        socket.resume()
        startReceiving(socket)

        do {
            let message = try await wait(for: connected, timeout: .seconds(60), label: "waiting for the TV to allow the connection")
            // Most firmware follows up with "ready"; tolerate ones that don't.
            _ = try? await wait(for: ready, timeout: .seconds(5), label: "art channel")
            return (message.json["data"] as? [String: Any])?["token"] as? String
        } catch {
            resolve(ready, with: .failure(CancellationError()))
            disconnect()
            throw error
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        failAllWaiters(FrameTVError.notConnected)
    }

    // MARK: - Art Mode API

    func apiVersion() async throws -> String {
        let reply: [String: Any]
        do {
            reply = try await request("api_version")
        } catch FrameTVError.tvError {
            reply = try await request("get_api_version")
        }
        return reply["version"] as? String ?? "unknown"
    }

    /// Content IDs of the photos in a category ("My Photos" by default).
    func contentIDs(category: String = FrameArtClient.myPhotosCategory) async throws -> [String] {
        let reply = try await request("get_content_list", ["category": category])
        let items = try Self.decodeList(reply["content_list"], what: "content list")
        return items
            .filter { ($0["category_id"] as? String).map { $0 == category } ?? true }
            .compactMap { $0["content_id"] as? String }
    }

    /// Uploads a JPEG and returns the TV's content ID for it.
    func upload(jpeg: Data, matteID: String) async throws -> String {
        let clock = ContinuousClock()
        let started = clock.now
        let uploadID = UUID().uuidString.lowercased()
        let ready = try await request(
            "send_image",
            [
                "file_type": "jpg",
                "file_size": jpeg.count,
                "image_date": Self.imageDateFormatter.string(from: Date()),
                "matte_id": matteID,
                "portrait_matte_id": matteID,
                "conn_info": [
                    "d2d_mode": "socket",
                    "connection_id": Int.random(in: 0..<4_294_967_296),
                    "id": uploadID,
                ] as [String: Any],
            ],
            id: uploadID,
            waitFor: "ready_to_use",
            timeout: .seconds(30)
        )
        let readyAt = clock.now

        let info = try Self.decodeObject(ready["conn_info"], what: "upload connection info")
        guard let ip = info["ip"] as? String,
              let port = (info["port"] as? Int) ?? Int(info["port"] as? String ?? ""),
              let key = info["key"] as? String
        else {
            throw FrameTVError.badResponse("upload connection info is incomplete")
        }
        let secured = (info["secured"] as? Bool) ?? ((info["secured"] as? String)?.lowercased() == "true")

        let header: [String: Any] = [
            "num": 0,
            "total": 1,
            "fileLength": jpeg.count,
            "fileName": "image",
            "fileType": "jpg",
            "secKey": key,
            "version": "0.0.1",
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header)
        var packet = Data()
        var headerLength = UInt32(headerData.count).bigEndian
        withUnsafeBytes(of: &headerLength) { packet.append(contentsOf: $0) }
        packet.append(headerData)
        packet.append(jpeg)

        // Listen for the confirmation before sending, so a quick reply can't be missed.
        let added = register { message in
            guard let reply = message.d2d else { return false }
            let event = reply["event"] as? String
            let replyID = reply["request_id"] as? String ?? reply["id"] as? String
            // Some firmware reports transfer errors without an ID; only one upload runs at a time, so it's ours.
            if event == "error", replyID == nil || replyID == uploadID {
                Self.log.error("TV reported an upload error: \(String(describing: reply), privacy: .public)")
                throw FrameTVError.tvError(request: "send_image", code: "\(reply["error_code"] ?? "unknown")")
            }
            return event == "image_added"
        }

        let connection: NWConnection
        do {
            connection = try await D2DSocket.open(host: ip, port: port, secured: secured)
        } catch {
            resolve(added, with: .failure(error))
            throw error
        }
        do {
            try await D2DSocket.send(packet, over: connection)
        } catch {
            connection.cancel()
            resolve(added, with: .failure(error))
            throw error
        }
        // Our side is already closed (the send ended the stream). Let the TV finish reading before the
        // socket is torn down; cancelling straight away could cut off the end of a large photo.
        D2DSocket.closeAfterPeerFinishes(connection)
        let sentAt = clock.now

        let reply: TVMessage
        do {
            reply = try await wait(for: added, timeout: .seconds(120), label: "TV saving the photo")
        } catch FrameTVError.timeout {
            throw FrameTVError.uploadNotConfirmed
        }
        guard let contentID = reply.d2d?["content_id"] as? String else {
            throw FrameTVError.badResponse("no content ID for the uploaded photo")
        }
        let kilobytes = jpeg.count / 1024
        let timing = "TV ready after \(readyAt - started), transfer \(sentAt - readyAt), TV saved after \(clock.now - sentAt)"
        Self.log.info("Uploaded \(kilobytes) KB. \(timing, privacy: .public)")
        return contentID
    }

    func delete(contentIDs: [String]) async throws {
        // Small batches keep each request well within what the TV accepts.
        for start in stride(from: 0, to: contentIDs.count, by: 25) {
            let chunk = contentIDs[start..<min(start + 25, contentIDs.count)]
            try await request(
                "delete_image_list",
                ["content_id_list": chunk.map { ["content_id": $0] }],
                timeout: .seconds(30)
            )
        }
    }

    func changeMatte(contentID: String, matteID: String) async throws {
        try await request("change_matte", [
            "content_id": contentID,
            "matte_id": matteID,
            "portrait_matte_id": matteID,
        ])
    }

    func selectImage(contentID: String) async throws {
        try await request("select_image", [
            "category_id": NSNull(),
            "content_id": contentID,
            "show": true,
        ])
    }

    /// Turns on the Art Mode slideshow for a category. `minutes` of 0 turns it off.
    func setSlideshow(minutes: Int, shuffle: Bool, category: String = FrameArtClient.myPhotosCategory) async throws {
        let params: [String: Any] = [
            "value": minutes > 0 ? String(minutes) : "off",
            "category_id": category,
            "type": shuffle ? "shuffleslideshow" : "slideshow",
        ]
        do {
            try await request("set_slideshow_status", params)
        } catch FrameTVError.tvError {
            // Some firmware still uses the older name for the same setting.
            try await request("set_auto_rotation_status", params)
        }
    }

    /// Mat styles and colors the TV supports.
    func matteOptions() async throws -> (types: [String], colors: [String]) {
        let reply = try await request("get_matte_list")
        let types = try Self.decodeList(reply["matte_type_list"] ?? reply["matte_list"], what: "mat styles")
            .compactMap { $0["matte_type"] as? String ?? Self.firstString(in: $0) }
        let colors = ((try? Self.decodeList(reply["matte_color_list"], what: "mat colors")) ?? [])
            .compactMap { $0["color"] as? String ?? Self.firstString(in: $0) }
        return (types, colors)
    }

    // MARK: - Requests

    @discardableResult
    private func request(
        _ name: String,
        _ params: [String: Any] = [:],
        id: String = UUID().uuidString.lowercased(),
        waitFor subEvent: String? = nil,
        timeout: Duration = .seconds(20)
    ) async throws -> [String: Any] {
        var payload = params
        payload["request"] = name
        payload["id"] = id
        payload["request_id"] = id

        let waiter = register { message in
            guard let reply = message.d2d else { return false }
            guard (reply["request_id"] as? String ?? reply["id"] as? String) == id else { return false }
            let event = reply["event"] as? String
            if event == "error" {
                throw FrameTVError.tvError(request: name, code: "\(reply["error_code"] ?? "unknown")")
            }
            return subEvent == nil || event == subEvent
        }

        do {
            try await emit(payload)
        } catch {
            resolve(waiter, with: .failure(error))
            throw error
        }
        let reply = try await wait(for: waiter, timeout: timeout, label: name)
        return reply.d2d ?? [:]
    }

    private func emit(_ payload: [String: Any]) async throws {
        guard let socket else { throw FrameTVError.notConnected }
        let inner = try JSONSerialization.data(withJSONObject: payload)
        let frame: [String: Any] = [
            "method": "ms.channel.emit",
            "params": [
                "event": "art_app_request",
                "to": "host",
                "data": String(decoding: inner, as: UTF8.self),
            ] as [String: Any],
        ]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
        try await socket.send(.string(text))
    }

    // MARK: - Receiving

    private func startReceiving(_ socket: URLSessionWebSocketTask) {
        receiveTask = Task {
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    self.handle(message)
                } catch {
                    self.connectionClosed(error)
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        guard let parsed = TVMessage.parse(data) else { return }

        for waiter in waiters {
            do {
                if try waiter.matches(parsed) {
                    resolve(waiter, with: .success(parsed))
                    return
                }
            } catch {
                resolve(waiter, with: .failure(error))
                return
            }
        }
    }

    private func connectionClosed(_ error: Error) {
        guard socket != nil else { return }
        socket = nil
        failAllWaiters(FrameTVError.connectionLost(error.localizedDescription))
    }

    // MARK: - Waiting for replies

    /// A pending expectation of a message from the TV. Register before sending so fast replies aren't lost.
    private final class Waiter: @unchecked Sendable {
        let matches: (TVMessage) throws -> Bool
        var result: Result<TVMessage, Error>?
        var continuation: CheckedContinuation<TVMessage, Error>?
        var isResolved = false

        init(matches: @escaping (TVMessage) throws -> Bool) {
            self.matches = matches
        }
    }

    private func register(_ matches: @escaping (TVMessage) throws -> Bool) -> Waiter {
        let waiter = Waiter(matches: matches)
        waiters.append(waiter)
        return waiter
    }

    private func resolve(_ waiter: Waiter, with result: Result<TVMessage, Error>) {
        guard !waiter.isResolved else { return }
        waiter.isResolved = true
        waiters.removeAll { $0 === waiter }
        if let continuation = waiter.continuation {
            waiter.continuation = nil
            continuation.resume(with: result)
        } else {
            waiter.result = result
        }
    }

    private func failAllWaiters(_ error: Error) {
        for waiter in waiters {
            resolve(waiter, with: .failure(error))
        }
    }

    private func wait(for waiter: Waiter, timeout: Duration, label: String) async throws -> TVMessage {
        if let result = waiter.result {
            return try result.get()
        }
        let timer = Task {
            try await Task.sleep(for: timeout)
            self.resolve(waiter, with: .failure(FrameTVError.timeout(label)))
        }
        defer { timer.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result = waiter.result {
                    continuation.resume(with: result)
                } else {
                    waiter.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.resolve(waiter, with: .failure(CancellationError())) }
        }
    }

    // MARK: - Helpers

    private static let imageDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    /// The TV sends nested JSON either as real objects or as JSON-encoded strings.
    private static func decodeJSON(_ value: Any?) -> Any? {
        if let text = value as? String {
            return try? JSONSerialization.jsonObject(with: Data(text.utf8))
        }
        return value
    }

    private static func decodeList(_ value: Any?, what: String) throws -> [[String: Any]] {
        guard let list = decodeJSON(value) as? [[String: Any]] else { throw FrameTVError.badResponse(what) }
        return list
    }

    private static func decodeObject(_ value: Any?, what: String) throws -> [String: Any] {
        guard let object = decodeJSON(value) as? [String: Any] else { throw FrameTVError.badResponse(what) }
        return object
    }

    private static func firstString(in dict: [String: Any]) -> String? {
        dict.values.lazy.compactMap { $0 as? String }.first
    }
}

/// The TV uses a self-signed certificate, so trust it — but only for the TV's own address.
private final class LocalTVTrustDelegate: NSObject, URLSessionDelegate {
    let host: String

    init(host: String) {
        self.host = host
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           space.host == host,
           let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
