import Foundation

/// The APNs environment this build's provisioning profile grants: `sandbox` for development
/// signing, `production` for ad hoc, TestFlight and App Store builds.
nonisolated enum PushEnvironment {
    static let current: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>"),
              let plist = try? PropertyListSerialization.propertyList(
                  from: Data(text[start.lowerBound..<end.upperBound].utf8), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String
        else {
            // No profile (simulator) or no push entitlement: development is the safe guess.
            return "sandbox"
        }
        return environment == "production" ? "production" : "sandbox"
    }()
}
