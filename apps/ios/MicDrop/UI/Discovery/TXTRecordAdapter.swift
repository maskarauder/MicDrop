// `NWTXTRecord` → untrusted attribute map for `DiscoveryRecord.parse` ("TXT extraction", risk 3).

import Foundation
import Network

/// Converts Bonjour TXT metadata into `[key: value]`, where a `nil` value is a DNS-SD key-only entry
/// (no `=`). Returns nil for absent metadata or a record whose entry count disagrees with its
/// dictionary view (a key-only entry the dictionary might hide), so the service yields no hosts.
enum TXTRecordAdapter {
    /// `NWBrowser.Result.Metadata` → attributes; `.none` (no TXT) → nil (invalid).
    static func attributes(metadata: NWBrowser.Result.Metadata) -> [String: Data?]? {
        switch metadata {
        case .bonjour(let record):
            return attributes(record)
        case .none:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Every key of `record` with its entry: `.none` → nil value, `.empty` → empty data,
    /// `.string(s)` → UTF-8 bytes of `s`, `.data(d)` → `d`.
    static func attributes(_ record: NWTXTRecord) -> [String: Data?]? {
        let keys = Array(record.dictionary.keys)
        guard record.count == keys.count else { return nil }
        var result: [String: Data?] = [:]
        for key in keys {
            guard let entry = record.getEntry(for: key) else { return nil }
            switch entry {
            case .none:
                result.updateValue(nil, forKey: key)
            case .empty:
                result.updateValue(Data(), forKey: key)
            case .string(let text):
                result.updateValue(Data(text.utf8), forKey: key)
            case .data(let data):
                result.updateValue(data, forKey: key)
            @unknown default:
                return nil
            }
        }
        return result
    }
}
