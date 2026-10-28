import Foundation

/// Basic facts the TV publishes over plain HTTP at http://<tv>:8001/api/v2/.
struct TVDeviceInfo: Decodable {
    struct Device: Decodable {
        let name: String?
        let modelName: String?
        let frameTVSupport: String?

        enum CodingKeys: String, CodingKey {
            case name
            case modelName
            case frameTVSupport = "FrameTVSupport"
        }
    }

    let name: String?
    let device: Device?

    var displayName: String {
        let raw = device?.name ?? name ?? "Samsung TV"
        // The name comes HTML-escaped, e.g. "[TV] Samsung Frame (55&quot;)".
        return raw
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    var isFrameTV: Bool {
        device?.frameTVSupport?.lowercased() == "true"
    }

    static func fetch(host: String) async throws -> TVDeviceInfo {
        guard let url = URL(string: "http://\(host):8001/api/v2/") else {
            throw FrameTVError.invalidHost(host)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw FrameTVError.connectionLost("no TV answered at \(host): \(error.localizedDescription)")
        }
        return try JSONDecoder().decode(TVDeviceInfo.self, from: data)
    }
}

extension FrameArtClient {
    /// Opens a connection, saving any new pairing token the TV hands out.
    static func connected(to host: String) async throws -> FrameArtClient {
        let client = FrameArtClient(host: host)
        do {
            if let token = try await client.connect(token: TokenStore.token(for: host)) {
                TokenStore.save(token, for: host)
            }
        } catch FrameTVError.unauthorized {
            TokenStore.remove(for: host)
            throw FrameTVError.unauthorized
        }
        return client
    }
}
