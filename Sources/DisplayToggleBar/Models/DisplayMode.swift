import CoreGraphics
import Foundation

/// A `CGDisplayMode` exposed as a value type for UI consumption.
///
/// We retain the underlying `CGDisplayMode` reference because it's required
/// when calling `CGConfigureDisplayWithDisplayMode`. Equality / identity is
/// based on `IODisplayModeID`, which is stable across enumerations.
struct DisplayMode: Identifiable, Equatable {
    let id: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isHiDPI: Bool
    fileprivate let cgMode: CGDisplayMode

    init(_ cgMode: CGDisplayMode) {
        self.cgMode = cgMode
        self.id = cgMode.ioDisplayModeID
        self.width = cgMode.width
        self.height = cgMode.height
        self.pixelWidth = cgMode.pixelWidth
        self.pixelHeight = cgMode.pixelHeight
        self.refreshRate = cgMode.refreshRate
        self.isHiDPI = cgMode.pixelWidth != cgMode.width
    }

    static func == (lhs: DisplayMode, rhs: DisplayMode) -> Bool {
        lhs.id == rhs.id
    }

    var refreshRateRounded: Int {
        Int(refreshRate.rounded())
    }

    /// Two modes "match resolution" if their pixel dimensions and HiDPI state
    /// are equal — i.e., they're the same mode at different refresh rates.
    func matchesResolution(of other: DisplayMode) -> Bool {
        pixelWidth == other.pixelWidth
            && pixelHeight == other.pixelHeight
            && isHiDPI == other.isHiDPI
    }

    /// The underlying `CGDisplayMode`, exposed to `DisplayManager` only.
    func cgDisplayMode() -> CGDisplayMode { cgMode }
}
