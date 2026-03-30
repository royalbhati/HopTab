import Foundation

/// Runtime registry where the closed-source HopTabPro module registers itself.
/// The open-source app queries this to check Pro availability and access features.
@MainActor
final class ProServiceRegistry {
    static let shared = ProServiceRegistry()

    private(set) var provider: HopTabProProvider?

    func register(_ provider: HopTabProProvider) {
        self.provider = provider
    }

    var isProAvailable: Bool { provider != nil }
    var isLicensed: Bool { provider?.isLicensed ?? false }
}
