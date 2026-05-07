import CoreGraphics
import Foundation

/// Value-type representation of a connected display.
///
/// Cached on disk (UserDefaults) so disabled displays — which disappear from
/// `CGGetOnlineDisplayList` — can still be shown in the menu and re-enabled.
struct Display: Identifiable, Equatable, Codable {
    /// Stable cache key for the built-in panel. The panel's `CGDirectDisplayID`
    /// changes after sleep/wake or framebuffer rebuilds, so we never use the
    /// numeric ID for cache lookups on built-ins.
    static let builtinCacheKey = "builtin-display"

    let id: CGDirectDisplayID
    let cacheKey: String
    let uuid: String
    let name: String
    let isBuiltin: Bool
    let isActive: Bool

    var stableDescription: String {
        isBuiltin ? "\(name) · Built-in" : name
    }

    var detailIdentifier: String {
        isBuiltin ? "Built-in display" : uuid
    }
}
