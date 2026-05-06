import AppKit
import CoreGraphics
import Foundation
import IOKit

@_silgen_name("CGSConfigureDisplayEnabled")
private func CGSConfigureDisplayEnabled(
    _ config: CGDisplayConfigRef,
    _ display: CGDirectDisplayID,
    _ enabled: Bool
) -> CGError

@_silgen_name("SLSDetectDisplays")
private func SLSDetectDisplays() -> CGError

// DisplayServices brightness — these don't require entitlements (BetterDisplay
// imports the same set). Brightness is in the range 0.0 ... 1.0.
@_silgen_name("DisplayServicesGetBrightness")
private func DisplayServicesGetBrightness(_ display: CGDirectDisplayID, _ brightness: UnsafeMutablePointer<Float>) -> Int32

@_silgen_name("DisplayServicesSetBrightness")
private func DisplayServicesSetBrightness(_ display: CGDirectDisplayID, _ brightness: Float) -> Int32

@_silgen_name("DisplayServicesCanChangeBrightness")
private func DisplayServicesCanChangeBrightness(_ display: CGDirectDisplayID) -> Bool

// MARK: - IOAVService (dynamic load)
//
// IOAVServiceCreateWithService/ReadI2C/WriteI2C are the symbols BetterDisplay
// and MonitorControl use to talk DDC/CI to external monitors over the I²C
// pins of their cable. Apple stripped these from the on-disk framework
// binaries on modern macOS, so we resolve them at runtime via dlsym instead
// of link-time symbol binding.

private struct IOAVAPI {
    typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    typealias ReadFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    typealias WriteFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeRawPointer, UInt32) -> Int32
    typealias CopyEDIDFn = @convention(c) (AnyObject, UnsafeMutablePointer<Unmanaged<CFData>?>) -> Int32

    let create: CreateFn
    let read: ReadFn
    let write: WriteFn
    let copyEDID: CopyEDIDFn?

    static let shared: IOAVAPI? = load()

    private static func load() -> IOAVAPI? {
        // RTLD_DEFAULT searches every framework already loaded into the
        // process. CoreDisplay (which we link below) pulls these in.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        let candidatePaths = [
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
            "/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel",
            "/System/Library/PrivateFrameworks/IOAVFamily.framework/IOAVFamily",
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
        ]

        func resolve(_ name: String) -> UnsafeMutableRawPointer? {
            if let p = dlsym(rtldDefault, name) { return p }
            for path in candidatePaths {
                guard let h = dlopen(path, RTLD_LAZY) else { continue }
                if let p = dlsym(h, name) { return p }
            }
            return nil
        }

        guard
            let createPtr = resolve("IOAVServiceCreateWithService"),
            let readPtr = resolve("IOAVServiceReadI2C"),
            let writePtr = resolve("IOAVServiceWriteI2C")
        else {
            return nil
        }
        let copyEDIDPtr = resolve("IOAVServiceCopyEDID")

        return IOAVAPI(
            create: unsafeBitCast(createPtr, to: CreateFn.self),
            read: unsafeBitCast(readPtr, to: ReadFn.self),
            write: unsafeBitCast(writePtr, to: WriteFn.self),
            copyEDID: copyEDIDPtr.map { unsafeBitCast($0, to: CopyEDIDFn.self) }
        )
    }
}

// MARK: - DDC over I²C (external monitor brightness)

/// Cached state for one external display's DDC channel.
private final class DDCCache {
    let avService: AnyObject
    var maxValue: UInt16
    var lastSetValue: UInt16?

    init(avService: AnyObject, maxValue: UInt16, lastSetValue: UInt16?) {
        self.avService = avService
        self.maxValue = maxValue
        self.lastSetValue = lastSetValue
    }
}

@MainActor
final class DDCBrightness {
    private static let chipAddress: UInt32 = 0x37
    private static let sourceOffset: UInt32 = 0x51
    private static let brightnessVCP: UInt8 = 0x10

    private var cache: [CGDirectDisplayID: DDCCache] = [:]
    // Displays we've already probed and found don't speak DDC — avoid
    // re-probing on every slider open (would slow the UI for no reason).
    private var unsupported: Set<CGDirectDisplayID> = []

    func canChangeBrightness(_ displayID: CGDirectDisplayID) -> Bool {
        guard IOAVAPI.shared != nil else { return false }
        return ensureCache(for: displayID) != nil
    }

    func brightness(for displayID: CGDirectDisplayID) -> Float? {
        guard let entry = ensureCache(for: displayID) else { return nil }
        if let last = entry.lastSetValue {
            return Float(last) / Float(entry.maxValue)
        }
        if let read = readVCP(Self.brightnessVCP, on: entry.avService) {
            entry.maxValue = read.max
            entry.lastSetValue = read.current
            return Float(read.current) / Float(read.max)
        }
        return nil
    }

    @discardableResult
    func setBrightness(for displayID: CGDirectDisplayID, normalized value: Float) -> Bool {
        guard let entry = ensureCache(for: displayID) else { return false }
        let clamped = max(0, min(1, value))
        let target = UInt16((Float(entry.maxValue) * clamped).rounded())
        guard writeVCP(Self.brightnessVCP, value: target, on: entry.avService) else { return false }
        entry.lastSetValue = target
        return true
    }

    func invalidate() {
        cache.removeAll()
        unsupported.removeAll()
    }

    // MARK: - Service matching

    private func ensureCache(for displayID: CGDirectDisplayID) -> DDCCache? {
        if let existing = cache[displayID] { return existing }
        if unsupported.contains(displayID) { return nil }
        guard CGDisplayIsBuiltin(displayID) == 0 else { return nil }

        guard let service = findIOAVService(for: displayID) else {
            unsupported.insert(displayID)
            return nil
        }

        // Probe by reading current brightness. If the monitor doesn't reply
        // with a valid VCP packet after retries, it doesn't speak DDC over
        // this connection; mark it unsupported so we don't try again.
        guard let read = readVCP(Self.brightnessVCP, on: service) else {
            unsupported.insert(displayID)
            return nil
        }

        let entry = DDCCache(avService: service, maxValue: read.max, lastSetValue: read.current)
        cache[displayID] = entry
        return entry
    }

    private func findIOAVService(for displayID: CGDirectDisplayID) -> AnyObject? {
        guard let api = IOAVAPI.shared else { return nil }
        guard CGDisplayIsBuiltin(displayID) == 0 else { return nil }
        guard let copyEDID = api.copyEDID else { return nil }

        let targetVendor = CGDisplayVendorNumber(displayID)
        let targetModel = CGDisplayModelNumber(displayID)
        let targetSerial = CGDisplaySerialNumber(displayID)

        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        var iter: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            root,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iter
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        // Walk every IOService and probe candidates with
        // IOAVServiceCreateWithService + IOAVServiceCopyEDID. Whichever entry
        // returns an EDID identifying the target display is the right one.
        var exactMatch: AnyObject?
        var vendorProductMatch: AnyObject?

        var entry = IOIteratorNext(iter)
        while entry != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iter)
            }

            if let loc = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               loc.contains("Embedded") {
                continue
            }

            guard let unmanaged = api.create(kCFAllocatorDefault, entry) else { continue }
            let avService = unmanaged.takeRetainedValue()

            var edidPtr: Unmanaged<CFData>?
            let edidResult = copyEDID(avService, &edidPtr)
            guard edidResult == 0, let unmanagedEDID = edidPtr else { continue }
            let edidData = unmanagedEDID.takeRetainedValue() as Data
            guard edidData.count >= 18 else { continue }

            let vendor = (UInt32(edidData[8]) << 8) | UInt32(edidData[9])
            let product = UInt32(edidData[10]) | (UInt32(edidData[11]) << 8)
            let serial = UInt32(edidData[12])
                | (UInt32(edidData[13]) << 8)
                | (UInt32(edidData[14]) << 16)
                | (UInt32(edidData[15]) << 24)

            if vendor == targetVendor && product == targetModel {
                if targetSerial == 0 || serial == targetSerial {
                    if exactMatch == nil { exactMatch = avService }
                } else if vendorProductMatch == nil {
                    vendorProductMatch = avService
                }
            }
        }

        return exactMatch ?? vendorProductMatch
    }

    // MARK: - VCP transport

    private func writeVCP(_ vcp: UInt8, value: UInt16, on service: AnyObject) -> Bool {
        guard let api = IOAVAPI.shared else { return false }
        let hi = UInt8((value >> 8) & 0xFF)
        let lo = UInt8(value & 0xFF)
        var packet: [UInt8] = [0x84, 0x03, vcp, hi, lo]
        var checksum: UInt8 = 0x6E ^ UInt8(Self.sourceOffset)
        for b in packet { checksum ^= b }
        packet.append(checksum)

        // Apple Silicon's DDC pipe drops packets often; retry up to 3× with
        // 50ms gaps (same approach MonitorControl/BetterDisplay use).
        for _ in 0..<3 {
            let result = packet.withUnsafeBufferPointer { buf -> Int32 in
                api.write(service, Self.chipAddress, Self.sourceOffset, buf.baseAddress!, UInt32(buf.count))
            }
            if result == 0 { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func readVCP(_ vcp: UInt8, on service: AnyObject) -> (current: UInt16, max: UInt16)? {
        guard let api = IOAVAPI.shared else { return nil }
        var request: [UInt8] = [0x82, 0x01, vcp]
        var checksum: UInt8 = 0x6E ^ UInt8(Self.sourceOffset)
        for b in request { checksum ^= b }
        request.append(checksum)

        for _ in 0..<3 {
            let writeResult = request.withUnsafeBufferPointer { buf -> Int32 in
                api.write(service, Self.chipAddress, Self.sourceOffset, buf.baseAddress!, UInt32(buf.count))
            }
            if writeResult != 0 {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }

            // Monitors need a moment to prepare the reply.
            Thread.sleep(forTimeInterval: 0.04)

            var response = [UInt8](repeating: 0, count: 12)
            let readResult = response.withUnsafeMutableBufferPointer { buf -> Int32 in
                api.read(service, Self.chipAddress, 0, buf.baseAddress!, UInt32(buf.count))
            }
            if readResult != 0 {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }

            // Some chips include the leading 0x6E (slave address echo), others don't.
            var data = response
            if data.first == 0x6E { data.removeFirst() }
            guard data.count >= 10 else {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            guard data[0] & 0x80 != 0 else {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            guard data[1] == 0x02 else {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            // VCP unsupported by monitor — no point retrying.
            guard data[2] == 0x00 else { return nil }
            let max = (UInt16(data[5]) << 8) | UInt16(data[6])
            let current = (UInt16(data[7]) << 8) | UInt16(data[8])
            guard max > 0 else {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            return (current, max)
        }
        return nil
    }
}

struct Display: Identifiable, Equatable, Codable {
    static let builtinCacheKey = "builtin-display"

    let id: CGDirectDisplayID
    let cacheKey: String
    let uuid: String
    let name: String
    let isBuiltin: Bool
    let isActive: Bool

    var stableDescription: String {
        if isBuiltin {
            return "\(name) · Built-in"
        }

        return name
    }

    var detailIdentifier: String {
        isBuiltin ? "Built-in display" : uuid
    }
}

@MainActor
final class DisplayManager {
    private let knownDisplaysKey = "knownDisplays"
    private var knownDisplaysByKey: [String: Display] = [:]
    private let ddc = DDCBrightness()

    init() {
        loadKnownDisplays()
    }

    func invalidateBrightnessCache() {
        ddc.invalidate()
    }

    enum ToggleError: LocalizedError {
        case beginConfiguration(CGError)
        case configure(CGError)
        case complete(CGError)
        case builtinEnableFailed(CGError)
        case noKnownBuiltinDisplay
        case lastActiveDisplay

        var errorDescription: String? {
            switch self {
            case let .beginConfiguration(error):
                return "Could not start display configuration: \(error)"
            case let .configure(error):
                return "Could not update display state: \(error)"
            case let .complete(error):
                return "Could not apply display configuration: \(error)"
            case let .builtinEnableFailed(error):
                return "Could not re-enable the built-in display after display-wake retries: \(error). macOS is rejecting the display transaction."
            case .noKnownBuiltinDisplay:
                return "No known built-in display is available to restore."
            case .lastActiveDisplay:
                return "The only active display cannot be disabled."
            }
        }
    }

    func displays() -> [Display] {
        let activeDisplayIDs = Set(displayIDs(using: CGGetActiveDisplayList))
        let onlineDisplayIDs = displayIDs(using: CGGetOnlineDisplayList)

        let currentDisplays = onlineDisplayIDs.map { displayID in
            let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
            let displayUUID = uuid(for: displayID)

            return Display(
                id: displayID,
                cacheKey: isBuiltin ? Display.builtinCacheKey : displayUUID,
                uuid: displayUUID,
                name: name(for: displayID),
                isBuiltin: isBuiltin,
                isActive: activeDisplayIDs.contains(displayID)
            )
        }

        for display in currentDisplays {
            knownDisplaysByKey[display.cacheKey] = display
        }
        persistKnownDisplays()

        let currentKeys = Set(currentDisplays.map(\.cacheKey))
        let cachedDisabledDisplays = knownDisplaysByKey.values
            .filter { display in
                !currentKeys.contains(display.cacheKey) && !display.isActive
            }

        return (currentDisplays + cachedDisabledDisplays).sorted { lhs, rhs in
            if lhs.isBuiltin != rhs.isBuiltin {
                return lhs.isBuiltin
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func canDisable(_ display: Display) -> Bool {
        guard display.isActive else {
            return true
        }

        return displays().filter(\.isActive).count > 1
    }

    func setDisplay(_ display: Display, enabled: Bool) throws {
        if !enabled, !canDisable(display) {
            throw ToggleError.lastActiveDisplay
        }

        // First try: use the display as-is. This is the fast/common path —
        // matches the original working behavior for both disable and quick
        // re-enable (within a few seconds).
        do {
            try applyDisplayState(display, enabled: enabled, option: .forSession)
            updateKnownDisplay(display, isActive: enabled)
            return
        } catch ToggleError.complete(let firstError) where enabled && display.isBuiltin {
            // Long-disable case for built-in: WindowServer has GC'd the display
            // descriptor and CGCompleteDisplayConfiguration returns
            // kCGErrorCannotComplete (1001). Poke the framebuffer kext directly
            // to force re-probe (same kernel path lid-close uses), then
            // SLSDetectDisplays + retry.
            wakeBuiltinFramebuffer()
            detectDisplays()
            Thread.sleep(forTimeInterval: 0.5)

            let refreshed = resolveDisplayForEnable(display)
            do {
                try applyDisplayState(refreshed, enabled: true, option: .forSession)
                updateKnownDisplay(refreshed, isActive: true)
                return
            } catch ToggleError.complete {
                // Second escalation: longer wait + permanently option.
                Thread.sleep(forTimeInterval: 1.0)
                wakeBuiltinFramebuffer()
                detectDisplays()
                Thread.sleep(forTimeInterval: 1.0)
                let refreshed2 = resolveDisplayForEnable(refreshed)
                do {
                    try applyDisplayState(refreshed2, enabled: true, option: .permanently)
                    updateKnownDisplay(refreshed2, isActive: true)
                    return
                } catch ToggleError.complete {
                    throw ToggleError.builtinEnableFailed(firstError)
                }
            }
        }
    }

    func canChangeBrightness(_ display: Display) -> Bool {
        if display.isBuiltin {
            return DisplayServicesCanChangeBrightness(display.id)
        }
        return ddc.canChangeBrightness(display.id)
    }

    func brightness(for display: Display) -> Float? {
        if display.isBuiltin {
            var value: Float = 0
            let result = DisplayServicesGetBrightness(display.id, &value)
            guard result == 0 else { return nil }
            return value
        }
        return ddc.brightness(for: display.id)
    }

    @discardableResult
    func setBrightness(_ display: Display, to value: Float) -> Bool {
        let clamped = max(0.0, min(1.0, value))
        if display.isBuiltin {
            return DisplayServicesSetBrightness(display.id, clamped) == 0
        }
        return ddc.setBrightness(for: display.id, normalized: clamped)
    }

    private func updateKnownDisplay(_ display: Display, isActive: Bool) {
        knownDisplaysByKey[display.cacheKey] = Display(
            id: display.id,
            cacheKey: display.cacheKey,
            uuid: display.uuid,
            name: display.name,
            isBuiltin: display.isBuiltin,
            isActive: isActive
        )
        persistKnownDisplays()
    }

    // Forces the built-in panel's kernel driver to re-probe its hardware. The
    // M-series panel sits behind AppleCLCD2 / IOMobileFramebufferAP. After a
    // long disable, WindowServer has dropped its display descriptor; asking
    // these services to re-probe is the same path lid-close + lid-open
    // exercises and what BetterDisplay imports for the same purpose
    // (IOServiceGetMatchingServices + IOServiceRequestProbe).
    private func wakeBuiltinFramebuffer() {
        for serviceClass in ["AppleCLCD2", "IOMobileFramebufferAP", "IOMobileFramebuffer"] {
            requestProbe(forServiceMatching: serviceClass)
        }
    }

    private func requestProbe(forServiceMatching className: String) {
        guard let matching = IOServiceMatching(className) else { return }
        var iter: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
        guard result == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != IO_OBJECT_NULL {
            _ = IOServiceRequestProbe(service, 0)
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
    }

    @discardableResult
    func restoreBuiltinDisplayIfNeeded(force: Bool = false) throws -> Bool {
        detectDisplays()
        let currentDisplays = displays()
        guard let builtinDisplay = currentDisplays.first(where: \.isBuiltin) ?? knownDisplaysByKey[Display.builtinCacheKey] else {
            throw ToggleError.noKnownBuiltinDisplay
        }

        guard !builtinDisplay.isActive else {
            return false
        }

        let activeNonBuiltinCount = currentDisplays.filter { !$0.isBuiltin && $0.isActive }.count
        guard force || activeNonBuiltinCount == 0 else {
            return false
        }

        try setDisplay(builtinDisplay, enabled: true)
        return true
    }

    private func applyDisplayState(_ display: Display, enabled: Bool, option: CGConfigureOption) throws {
        var config: CGDisplayConfigRef?
        let beginError = CGBeginDisplayConfiguration(&config)
        guard beginError == .success, let config else {
            throw ToggleError.beginConfiguration(beginError)
        }

        let configureError = CGSConfigureDisplayEnabled(config, display.id, enabled)
        guard configureError == .success else {
            CGCancelDisplayConfiguration(config)
            throw ToggleError.configure(configureError)
        }

        let completeError = CGCompleteDisplayConfiguration(config, option)
        guard completeError == .success else {
            throw ToggleError.complete(completeError)
        }
    }

    private func resolveDisplayForEnable(_ display: Display) -> Display {
        guard display.isBuiltin else {
            return display
        }

        detectDisplays()
        return displays().first { $0.isBuiltin && $0.id != display.id } ?? display
    }

    private func detectDisplays() {
        _ = SLSDetectDisplays()
    }

    private func loadKnownDisplays() {
        guard let data = UserDefaults.standard.data(forKey: knownDisplaysKey),
              let displays = try? JSONDecoder().decode([Display].self, from: data) else {
            return
        }

        knownDisplaysByKey = Dictionary(uniqueKeysWithValues: displays.map { ($0.cacheKey, $0) })
    }

    private func persistKnownDisplays() {
        guard let data = try? JSONEncoder().encode(Array(knownDisplaysByKey.values)) else {
            return
        }

        UserDefaults.standard.set(data, forKey: knownDisplaysKey)
    }

    private func displayIDs(
        using getter: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    ) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard getter(0, nil, &count) == .success, count > 0 else {
            return []
        }

        var displayIDs = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        let error = displayIDs.withUnsafeMutableBufferPointer { buffer in
            getter(count, buffer.baseAddress, &count)
        }

        guard error == .success else {
            return []
        }

        return Array(displayIDs.prefix(Int(count)))
    }

    private func uuid(for displayID: CGDirectDisplayID) -> String {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return "display-\(displayID)"
        }

        let cfUUID = unmanagedUUID.takeRetainedValue()
        return (CFUUIDCreateString(kCFAllocatorDefault, cfUUID) as String?) ?? "display-\(displayID)"
    }

    private func name(for displayID: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? NSNumber,
               number.uint32Value == displayID {
                return screen.localizedName
            }
        }

        if CGDisplayIsBuiltin(displayID) != 0 {
            return "Built-in Display"
        }

        return "Display \(displayID)"
    }
}

final class DisplaySwitch: NSSwitch {
    var display: Display?
}

@MainActor
protocol DisplayTileDelegate: AnyObject {
    func displayTile(_ tile: DisplayTileView, didToggleEnabled enabled: Bool)
    func displayTile(_ tile: DisplayTileView, didChangeBrightness value: Float)
    func displayTile(_ tile: DisplayTileView, didSetExpanded expanded: Bool)
    func displayTileBrightness(_ tile: DisplayTileView) -> Float?
    func displayTileCanChangeBrightness(_ tile: DisplayTileView) -> Bool
}

@MainActor
final class DisplayTileView: NSView {
    let display: Display
    private weak var delegate: DisplayTileDelegate?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private let switchControl = DisplaySwitch()
    private let headerRow = NSView()

    private let brightnessIcon = NSImageView()
    private let brightnessLabel = NSTextField(labelWithString: "")
    private let brightnessSlider = NSSlider()
    private let expandedContainer = NSStackView()

    private let canToggle: Bool
    private let isExpandable: Bool
    private(set) var isExpanded: Bool

    private static let collapsedHeight: CGFloat = 36
    private static let expandedHeight: CGFloat = 100

    private var heightConstraint: NSLayoutConstraint!

    init(display: Display, activeCount: Int, expanded: Bool, canChangeBrightness: Bool, delegate: DisplayTileDelegate) {
        self.display = display
        self.delegate = delegate
        self.canToggle = !display.isActive || activeCount > 1
        self.isExpandable = canChangeBrightness
        self.isExpanded = canChangeBrightness && expanded
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: Self.collapsedHeight))

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        let initialHeight = isExpandable && self.isExpanded ? Self.expandedHeight : Self.collapsedHeight
        heightConstraint = heightAnchor.constraint(equalToConstant: initialHeight)
        heightConstraint.isActive = true

        configureHeader()
        if isExpandable {
            configureExpanded()
        }
        layoutSubviewsManually()
        applyExpandedState(animated: false)
        if isExpandable {
            refreshBrightnessFromSystem()
        }
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Layout

    private func configureHeader() {
        let symbolName = display.isBuiltin ? "laptopcomputer" : "display"
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        iconView.contentTintColor = canToggle ? .labelColor : .secondaryLabelColor

        titleLabel.stringValue = display.name
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = canToggle ? .labelColor : .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.toolTip = canToggle ? nil : "Only active display cannot be disabled"

        chevronView.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevronView.contentTintColor = .tertiaryLabelColor

        switchControl.display = display
        switchControl.state = display.isActive ? .on : .off
        switchControl.isEnabled = canToggle
        switchControl.target = self
        switchControl.action = #selector(switchToggled(_:))
    }

    private func configureExpanded() {
        brightnessIcon.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)
        brightnessIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        brightnessIcon.contentTintColor = .secondaryLabelColor

        brightnessLabel.font = .systemFont(ofSize: 11, weight: .regular)
        brightnessLabel.textColor = .secondaryLabelColor
        brightnessLabel.alignment = .right
        brightnessLabel.stringValue = "—"

        brightnessSlider.minValue = 0
        brightnessSlider.maxValue = 1
        brightnessSlider.isContinuous = true
        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessChanged(_:))

        let row = NSStackView(views: [brightnessIcon, brightnessSlider, brightnessLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        brightnessIcon.setContentHuggingPriority(.required, for: .horizontal)
        brightnessLabel.setContentHuggingPriority(.required, for: .horizontal)
        brightnessLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true

        expandedContainer.orientation = .vertical
        expandedContainer.alignment = .leading
        expandedContainer.spacing = 6
        expandedContainer.distribution = .fill
        expandedContainer.addArrangedSubview(makeSectionLabel("Brightness"))
        expandedContainer.addArrangedSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor).isActive = true
        row.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor).isActive = true
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func layoutSubviewsManually() {
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        switchControl.translatesAutoresizingMaskIntoConstraints = false

        headerRow.addSubview(iconView)
        headerRow.addSubview(titleLabel)
        headerRow.addSubview(switchControl)
        addSubview(headerRow)

        var constraints: [NSLayoutConstraint] = [
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            headerRow.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            headerRow.heightAnchor.constraint(equalToConstant: 28),

            iconView.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),

            switchControl.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor),
            switchControl.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
        ]

        if isExpandable {
            chevronView.translatesAutoresizingMaskIntoConstraints = false
            expandedContainer.translatesAutoresizingMaskIntoConstraints = false
            headerRow.addSubview(chevronView)
            addSubview(expandedContainer)

            constraints.append(contentsOf: [
                chevronView.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
                chevronView.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
                chevronView.trailingAnchor.constraint(lessThanOrEqualTo: switchControl.leadingAnchor, constant: -8),

                expandedContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
                expandedContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                expandedContainer.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 6),
                expandedContainer.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
            ])
        } else {
            // No chevron — let titleLabel run up to the switch.
            constraints.append(
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: switchControl.leadingAnchor, constant: -8)
            )
        }

        NSLayoutConstraint.activate(constraints)

        switchControl.setContentHuggingPriority(.required, for: .horizontal)
        switchControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    // MARK: - Behavior

    override func mouseDown(with event: NSEvent) {
        // No expandable content → let the click pass through (still allows
        // the switch to receive its own events).
        guard isExpandable else {
            super.mouseDown(with: event)
            return
        }

        let p = convert(event.locationInWindow, from: nil)
        if switchControl.frame.contains(p) {
            super.mouseDown(with: event)
            return
        }
        if isExpanded, expandedContainer.frame.contains(p) {
            super.mouseDown(with: event)
            return
        }
        isExpanded.toggle()
        applyExpandedState(animated: true)
        delegate?.displayTile(self, didSetExpanded: isExpanded)
        if isExpanded {
            refreshBrightnessFromSystem()
        }
    }

    private func applyExpandedState(animated: Bool) {
        guard isExpandable else {
            heightConstraint.constant = Self.collapsedHeight
            return
        }

        let isExpanding = isExpanded
        chevronView.image = NSImage(
            systemSymbolName: isExpanding ? "chevron.up" : "chevron.down",
            accessibilityDescription: nil
        )

        let targetHeight: CGFloat = isExpanding ? Self.expandedHeight : Self.collapsedHeight

        guard animated else {
            heightConstraint.constant = targetHeight
            expandedContainer.isHidden = !isExpanding
            expandedContainer.alphaValue = isExpanding ? 1 : 0
            return
        }

        // Stage expanded content visible-but-transparent on expand so it can
        // fade in. On collapse, keep visible during the shrink and hide at end.
        if isExpanding {
            expandedContainer.isHidden = false
            expandedContainer.alphaValue = 0
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.30
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            heightConstraint.animator().constant = targetHeight
            expandedContainer.animator().alphaValue = isExpanding ? 1 : 0
            superview?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.isExpanded {
                    self.expandedContainer.isHidden = true
                }
            }
        })
    }

    override var intrinsicContentSize: NSSize {
        let h = (isExpandable && isExpanded) ? Self.expandedHeight : Self.collapsedHeight
        return NSSize(width: 320, height: h)
    }

    private func refreshBrightnessFromSystem() {
        let canChange = delegate?.displayTileCanChangeBrightness(self) ?? false
        brightnessSlider.isEnabled = canChange
        brightnessIcon.contentTintColor = canChange ? .secondaryLabelColor : .tertiaryLabelColor

        if let value = delegate?.displayTileBrightness(self) {
            brightnessSlider.floatValue = value
            brightnessLabel.stringValue = "\(Int((value * 100).rounded()))%"
        } else {
            brightnessLabel.stringValue = canChange ? "—" : "N/A"
        }
    }

    @objc private func switchToggled(_ sender: DisplaySwitch) {
        delegate?.displayTile(self, didToggleEnabled: sender.state == .on)
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        let value = sender.floatValue
        brightnessLabel.stringValue = "\(Int((value * 100).rounded()))%"
        delegate?.displayTile(self, didChangeBrightness: value)
    }
}

@MainActor
final class PopoverContentViewController: NSViewController {
    private static let popoverWidth: CGFloat = 320

    var refreshAction: (() -> Void)?
    var quitAction: (() -> Void)?

    private let tilesStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No displays found")
    private let separator = NSBox()
    private let footerStack = NSStackView()

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        tilesStack.orientation = .vertical
        tilesStack.alignment = .leading
        tilesStack.distribution = .fill
        tilesStack.spacing = 4
        tilesStack.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12, weight: .regular)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let refreshButton = makeFooterButton(title: "Refresh", systemImage: "arrow.clockwise") { [weak self] in
            self?.refreshAction?()
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let quitButton = makeFooterButton(title: "Quit", systemImage: "power") { [weak self] in
            self?.quitAction?()
        }

        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 8
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footerStack.addArrangedSubview(refreshButton)
        footerStack.addArrangedSubview(spacer)
        footerStack.addArrangedSubview(quitButton)

        root.addSubview(tilesStack)
        root.addSubview(emptyLabel)
        root.addSubview(separator)
        root.addSubview(footerStack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.popoverWidth),

            tilesStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            tilesStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            tilesStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            emptyLabel.topAnchor.constraint(equalTo: tilesStack.topAnchor, constant: 12),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            separator.topAnchor.constraint(equalTo: tilesStack.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            separator.heightAnchor.constraint(equalToConstant: 1),

            footerStack.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            footerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footerStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            footerStack.heightAnchor.constraint(equalToConstant: 28)
        ])

        self.view = root
    }

    func setTiles(_ tiles: [DisplayTileView], hasDisplays: Bool) {
        // Drop the previous tiles so we don't accumulate.
        for view in tilesStack.arrangedSubviews {
            tilesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        emptyLabel.isHidden = hasDisplays

        for tile in tiles {
            tilesStack.addArrangedSubview(tile)
            tile.widthAnchor.constraint(equalTo: tilesStack.widthAnchor).isActive = true
        }

        // Force the view to layout so the popover picks up the new content size
        // immediately on first show.
        view.layoutSubtreeIfNeeded()
    }

    private func makeFooterButton(title: String, systemImage: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
}

@MainActor
final class ClosureButton: NSButton {
    private let closure: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.closure = action
        super.init(frame: .zero)
        self.title = title
        self.target = self
        self.action = #selector(invoke)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func invoke() {
        closure()
    }
}

@MainActor
final class MenuController: NSObject, DisplayTileDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let contentVC: PopoverContentViewController
    private let displayManager = DisplayManager()
    private var lastDisplayKeys: Set<String> = []
    private var expandedDisplayKeys: Set<String> = []
    private var eventMonitor: Any?

    // Throttle DDC writes — each round trip is ~50ms over I²C, so spamming on
    // every continuous slider step makes drags feel laggy. We coalesce to the
    // most recent value and send at most every 80ms.
    private var ddcWriteTimer: DispatchSourceTimer?
    private var pendingDDCWrite: (display: Display, value: Float)?

    override init() {
        self.contentVC = PopoverContentViewController()
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "display",
            accessibilityDescription: "Display Toggle"
        )
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = contentVC
        popover.delegate = self

        contentVC.refreshAction = { [weak self] in self?.refreshContent() }
        contentVC.quitAction = { NSApplication.shared.terminate(nil) }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        refreshContent()
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            guard let button = statusItem.button else { return }
            refreshContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Close popover when user clicks outside it.
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.popover.performClose(nil)
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    @objc private func refreshContent() {
        let displays = displayManager.displays()
        let activeCount = displays.filter(\.isActive).count
        lastDisplayKeys = Set(displays.map(\.cacheKey))
        expandedDisplayKeys.formIntersection(Set(displays.map(\.cacheKey)))

        let tiles = displays.map { display in
            DisplayTileView(
                display: display,
                activeCount: activeCount,
                expanded: expandedDisplayKeys.contains(display.cacheKey),
                canChangeBrightness: displayManager.canChangeBrightness(display),
                delegate: self
            )
        }
        contentVC.setTiles(tiles, hasDisplays: !displays.isEmpty)
    }

    @objc private func displayConfigurationChanged() {
        let previousDisplayKeys = lastDisplayKeys
        // Display IDs and IOAVService bindings can change after reconfig.
        displayManager.invalidateBrightnessCache()

        scheduleBuiltinRestorePass(after: 0.8, previousDisplayKeys: previousDisplayKeys, showErrors: true)
        scheduleBuiltinRestorePass(after: 2.0, previousDisplayKeys: previousDisplayKeys, showErrors: false)
        scheduleBuiltinRestorePass(after: 4.0, previousDisplayKeys: previousDisplayKeys, showErrors: false)
    }

    private func scheduleBuiltinRestorePass(after delay: TimeInterval, previousDisplayKeys: Set<String>, showErrors: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.restoreBuiltinAfterDisplayChange(previousDisplayKeys: previousDisplayKeys, showErrors: showErrors)
        }
    }

    private func restoreBuiltinAfterDisplayChange(previousDisplayKeys: Set<String>, showErrors: Bool) {
        let displays = displayManager.displays()
        let currentDisplayKeys = Set(displays.map(\.cacheKey))
        let removedDisplayKeys = previousDisplayKeys.subtracting(currentDisplayKeys)
        let removedNonBuiltinDisplay = removedDisplayKeys.contains { $0 != Display.builtinCacheKey }
        let noActiveNonBuiltinDisplay = !displays.contains { !$0.isBuiltin && $0.isActive }

        if removedNonBuiltinDisplay || noActiveNonBuiltinDisplay {
            do {
                _ = try displayManager.restoreBuiltinDisplayIfNeeded(force: removedNonBuiltinDisplay)
            } catch {
                if showErrors {
                    showError(error)
                }
            }
        }

        refreshContent()
    }

    // MARK: - DisplayTileDelegate

    func displayTile(_ tile: DisplayTileView, didToggleEnabled enabled: Bool) {
        let display = tile.display
        do {
            try displayManager.setDisplay(display, enabled: enabled)
        } catch {
            showError(error)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshContent()
        }
    }

    func displayTile(_ tile: DisplayTileView, didChangeBrightness value: Float) {
        let display = tile.display
        if display.isBuiltin {
            // DisplayServices is fast (memory write); update on every step.
            displayManager.setBrightness(display, to: value)
            return
        }
        // External display — throttle to avoid lag during slider drag.
        pendingDDCWrite = (display, value)
        if ddcWriteTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.08, repeating: .never)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if let pending = self.pendingDDCWrite {
                    self.displayManager.setBrightness(pending.display, to: pending.value)
                }
                self.pendingDDCWrite = nil
                self.ddcWriteTimer = nil
            }
            ddcWriteTimer = timer
            timer.resume()
        }
    }

    func displayTile(_ tile: DisplayTileView, didSetExpanded expanded: Bool) {
        if expanded {
            expandedDisplayKeys.insert(tile.display.cacheKey)
        } else {
            expandedDisplayKeys.remove(tile.display.cacheKey)
        }
    }

    func displayTileBrightness(_ tile: DisplayTileView) -> Float? {
        displayManager.brightness(for: tile.display)
    }

    func displayTileCanChangeBrightness(_ tile: DisplayTileView) -> Bool {
        displayManager.canChangeBrightness(tile.display)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Display toggle failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let menuController = MenuController()
_ = menuController

app.run()
