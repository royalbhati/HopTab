import Foundation

/// Central feature gate — checks whether Pro is loaded and licensed.
/// Used throughout the open-source app to enforce free-tier limits.
@MainActor
enum ProFeatureGate {
    static let freeProfileLimit = 3

    static var isProAvailable: Bool {
        ProServiceRegistry.shared.isProAvailable
    }

    static var isLicensed: Bool {
        ProServiceRegistry.shared.isLicensed
    }

    static let freeWindowRuleLimit = 2

    static func canCreateProfile(currentCount: Int) -> Bool {
        if isLicensed { return true }
        return currentCount < freeProfileLimit
    }

    static func canCreateWindowRule(currentCount: Int) -> Bool {
        if isLicensed { return true }
        return currentCount < freeWindowRuleLimit
    }
}
