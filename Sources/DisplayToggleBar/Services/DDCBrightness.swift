import CoreGraphics
import Foundation
import IOKit

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

/// DDC/CI brightness control over I²C for external monitors.
///
/// Apple Silicon's DDC pipe is unreliable, so reads and writes retry up to 3×
/// with 50ms gaps (same approach MonitorControl/BetterDisplay use). Displays
/// that don't reply to a probe read are cached as unsupported and won't be
/// re-probed until `invalidate()` is called (e.g. after a display reconfig).
@MainActor
final class DDCBrightness {
    private static let chipAddress: UInt32 = 0x37
    private static let sourceOffset: UInt32 = 0x51
    private static let brightnessVCP: UInt8 = 0x10

    private var cache: [CGDirectDisplayID: DDCCache] = [:]
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
        // with a valid VCP packet, mark unsupported so we don't re-probe.
        guard let read = readVCP(Self.brightnessVCP, on: service) else {
            unsupported.insert(displayID)
            return nil
        }

        let entry = DDCCache(avService: service, maxValue: read.max, lastSetValue: read.current)
        cache[displayID] = entry
        return entry
    }

    /// Walks every IOService in the registry and probes candidates with
    /// `IOAVServiceCreateWithService` + `IOAVServiceCopyEDID`. Whichever entry
    /// returns an EDID identifying the target display is the right one.
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
