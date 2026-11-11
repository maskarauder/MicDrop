import Foundation
import MicDropCore
import Security

/// One HTTPS `GET <rendezvous>/v1/ice` (`RemoteIceFetching`). Production: `URLSessionRemoteIceFetcher`; tests: a fake.
///
/// Contract: exactly one `Authorization` header with the given value (`Bearer <43-char token>`, 50 bytes), no body, no
/// query, no `Origin`, no cookies, no caches, no redirects (a 3xx arrives as the response status). For status 200 the
/// body is read with a hard cap of `RemoteICEParser.maxBodyBytes` (16384) bytes — one more byte throws
/// `ControlIOError(.iceUnavailable(.tooLarge))`; for any other status the body is not read and `body` is empty. Task
/// cancellation cancels the request. Errors are mapped per (`URLSessionRemoteIceFetcher.mapError`).
protocol RemoteIceFetching: Sendable {
    func fetchICE(url: URL, authorization: String) async throws -> (status: Int, body: Data)
    func fetchICE(url: URL, authorization: String, timeoutMs: Int) async throws -> (status: Int, body: Data)
}

extension RemoteIceFetching {
    func fetchICE(url: URL, authorization: String, timeoutMs: Int) async throws -> (status: Int, body: Data) {
        try await fetchICE(url: url, authorization: authorization)
    }
}

/// `URLSession` implementation of `RemoteIceFetching` (table; Android `HttpsURLConnection` with
/// `instanceFollowRedirects = false`, `useCaches = false`, connect/read timeouts 8000 ms, `RemoteIce.kt:29-36`).
///
/// System trust for the outer HTTPS (ATS applies; TLS 1.3 minimum, the rendezvous requires 1.3).
/// URL, token and response bytes are private data and never logged.
final class URLSessionRemoteIceFetcher: NSObject, RemoteIceFetching, URLSessionTaskDelegate, @unchecked Sendable {
    /// Idle timeout ≈ Android read timeout (8000 ms).
    static let requestTimeoutSeconds: TimeInterval = 8
    /// ≈ Android connect 8 s + read 8 s.
    static let resourceTimeoutSeconds: TimeInterval = 16

    private var session: URLSession!

    /// The session keeps a strong reference to its delegate (this object) until invalidated; the
    /// fetcher lives for the process (`RemoteICEService.shared`).
    init(configuration: URLSessionConfiguration = URLSessionRemoteIceFetcher.makeConfiguration()) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Ephemeral, cache-free, cookie-free, credential-store-free configuration.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        configuration.timeoutIntervalForRequest = requestTimeoutSeconds
        configuration.timeoutIntervalForResource = resourceTimeoutSeconds
        configuration.waitsForConnectivity = false
        return configuration
    }

    /// The `GET` request: single `Authorization` header, no body.
    static func makeRequest(url: URL, authorization: String, timeoutMs: Int = 8_000) -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: Double(timeoutMs) / 1_000)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    func fetchICE(url: URL, authorization: String) async throws -> (status: Int, body: Data) {
        try await fetchICE(url: url, authorization: authorization, timeoutMs: 8_000)
    }

    func fetchICE(url: URL, authorization: String, timeoutMs: Int) async throws -> (status: Int, body: Data) {
        guard (1...30_000).contains(timeoutMs) else { throw ControlResponseError(.invalidReply) }
        let client: URLSession
        if timeoutMs == 8_000 {
            client = session
        } else {
            let configuration = session.configuration
            configuration.timeoutIntervalForRequest = Double(timeoutMs) / 1_000
            configuration.timeoutIntervalForResource = Double(timeoutMs) / 500
            client = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        }
        defer { if client !== session { client.finishTasksAndInvalidate() } }
        do {
            // `self` is also the task delegate so the redirect refusal applies to this async task regardless of how the
            // session routes task-level callbacks.
            let (bytes, response) = try await client.bytes(
                for: Self.makeRequest(url: url, authorization: authorization, timeoutMs: timeoutMs),
                delegate: self)
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw ControlIOError(.iceServiceUnavailable)
            }
            guard http.statusCode == 200 else {
                bytes.task.cancel()
                return (status: http.statusCode, body: Data())
            }
            var body = Data()
            for try await byte in bytes {
                if body.count >= RemoteICEParser.maxBodyBytes {
                    bytes.task.cancel()
                    throw ControlIOError(.iceUnavailable(.tooLarge))
                }
                body.append(byte)
            }
            return (status: 200, body: body)
        } catch {
            throw Self.mapError(error)
        }
    }

    /// error mapping. Already-classified errors pass through unchanged.
    /// - bad date / not yet valid → `SignalingTLSFailure(.iceService, .certificateTime)`;
    /// - untrusted / unknown root → `(.iceService, .identity)`;
    /// - secure connection failed, client certificate rejected/required → `(.iceService, .handshake)`;
    /// - cancelled / `CancellationError` → `SessionStopped`;
    /// - timed out → `ControlIOError(.timedOut)`;
    /// - every other `URLError` or unknown error → `ControlIOError(.iceServiceUnavailable)`
    /// (generic `NETWORK_IO`, never "Cannot reach Windows").
    static func mapError(_ error: Error) -> Error {
        switch error {
        case is HTTPFailure, is SignalingTLSFailure, is ControlIOError, is ControlResponseError,
            is SessionStopped, is ICEProtocolError:
            return error
        case is CancellationError:
            return SessionStopped()
        case let urlError as URLError:
            switch urlError.code {
            case .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                return SignalingTLSFailure(layer: .iceService, problem: .certificateTime)
            case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
                return SignalingTLSFailure(layer: .iceService, problem: .identity)
            case .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired:
                return SignalingTLSFailure(layer: .iceService, problem: .handshake)
            case .cancelled:
                return SessionStopped()
            case .timedOut:
                return ControlIOError(.timedOut)
            default:
                return ControlIOError(.iceServiceUnavailable)
            }
        default:
            return ControlIOError(.iceServiceUnavailable)
        }
    }

    // MARK: - URLSessionTaskDelegate

    /// Never follow redirects (`instanceFollowRedirects = false`): the 3xx response itself is
    /// delivered and becomes `HTTPFailure(status)`. The explicit selector guarantees the runtime
    /// finds the method even if a `@Sendable` annotation difference made the witness match fuzzy.
    @objc(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
