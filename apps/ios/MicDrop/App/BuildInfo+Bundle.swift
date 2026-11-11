import Foundation
import MicDropCore

extension BuildInfo {
    /// This app's build identity: `MicDropVersionName` and `MicDropRevision` from `Bundle.main`. CI sets
    /// `MICDROP_REVISION` to the 12-character commit prefix; local builds report `local`.
    public static let current = BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
}
