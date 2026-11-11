import Foundation

/// Reads repository fixtures in place, where the Go and Android tests already read them.
///
/// Nothing is copied into the package: SwiftPM resources cannot live outside the package root. Known fixtures:
/// `internal/identity/testdata/host_public_key_v1.json`, `internal/identity/testdata/host_certificates_v1.json`,
/// `apps/windows-host/testdata/pairing-qr.txt` and
/// `apps/android/pairing-check/src/androidTest/assets/public-test-tls.json` (a public test key; never bundle it).
public enum RepositoryFixtures {
    /// Errors name the path that was tried so a CI log shows a wrong root immediately.
    public enum FixtureError: Error, Equatable, CustomStringConvertible {
        /// `go.mod` was not found at the computed root.
        case repositoryRootNotFound(String)
        case fixtureMissing(String)
        case notUTF8(String)

        public var description: String {
            switch self {
            case .repositoryRootNotFound(let path):
                return "Repository root not found (no go.mod at \(path)); set MICDROP_REPOSITORY_ROOT"
            case .fixtureMissing(let path):
                return "Repository fixture missing: \(path)"
            case .notUTF8(let path):
                return "Repository fixture is not UTF-8: \(path)"
            }
        }
    }

    /// Repository root: `MICDROP_REPOSITORY_ROOT` if set and non-empty, else six levels above this file
    /// (`<root>/apps/ios/MicDropKit/Tests/MicDropTestSupport/RepositoryFixtures.swift`).
    public static let root: URL = {
        if let override = ProcessInfo.processInfo.environment["MICDROP_REPOSITORY_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()

    /// The fixture's location under `root`; `relativePath` uses `/` separators.
    public static func url(_ relativePath: String) -> URL {
        relativePath.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    /// Throws if the root is wrong (`go.mod` must exist) or the fixture is missing.
    public static func data(_ relativePath: String) throws -> Data {
        let marker = root.appendingPathComponent("go.mod")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw FixtureError.repositoryRootNotFound(root.path)
        }
        let file = url(relativePath)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw FixtureError.fixtureMissing(file.path)
        }
        return try Data(contentsOf: file)
    }

    /// UTF-8 text with `"\r\n"` normalized to `"\n"` (like `apps/windows-host/pairing_qr_test.go:22`), so a
    /// Windows checkout with CRLF line endings gives the same text as Linux.
    public static func text(_ relativePath: String) throws -> String {
        let bytes = try data(relativePath)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw FixtureError.notUTF8(url(relativePath).path)
        }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }
}
