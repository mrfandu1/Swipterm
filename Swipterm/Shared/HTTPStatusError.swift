import Foundation

nonisolated struct HTTPStatusError: LocalizedError {
    let url: URL?
    let statusCode: Int

    var errorDescription: String? {
        let status = "HTTP \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode))"
        guard let url else { return status }
        return "\(url.absoluteString): \(status)"
    }
}

nonisolated extension HTTPURLResponse {
    func requireSuccess() throws {
        guard (200 ..< 300).contains(statusCode) else {
            throw HTTPStatusError(url: url, statusCode: statusCode)
        }
    }
}
