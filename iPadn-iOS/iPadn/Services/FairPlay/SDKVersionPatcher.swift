import Foundation

/// Raises the iOS SDK version a Mach-O records in `LC_BUILD_VERSION` /
/// `LC_VERSION_MIN_IPHONEOS`: the same edit as `vtool -set-build-version`.
///
/// UIKit picks compatibility behaviour from that number (dyld's program SDK
/// version): an app linked against an old SDK is letterboxed or scaled on newer
/// screens, and iPhone Duo only lets an app fill its inner display from SDK 27.1.
/// Nothing is recompiled, so the app also opts into newer default behaviours.
/// Editing the header invalidates the code signature: the package has to be
/// re-signed before it can be installed.
enum SDKVersionPatcher {
    static let enabledKey = "sdkPatch.enabled"
    static let targetKey = "sdkPatch.target"
    static let defaultTarget = "27.1"

    /// UIKit apps linked against the SDK after iOS 26 must use the scene life
    /// cycle or they do not launch; apps without a scene manifest are capped here.
    static let sceneRequiredFrom: UInt32 = 27 << 16
    static let capWithoutScenes: UInt32 = 26 << 16

    enum PatchError: Error, Equatable {
        case notMachO
        case truncated
    }

    struct Change: Equatable {
        /// Path relative to the .app folder.
        let path: String
        let old: [UInt32]
        let new: UInt32
    }

    private static let fatMagic: UInt32 = 0xCAFE_BABE      // read big-endian
    private static let fatMagic64: UInt32 = 0xCAFE_BABF    // read big-endian
    private static let magic32: UInt32 = 0xFEED_FACE       // read little-endian
    private static let magic64: UInt32 = 0xFEED_FACF       // read little-endian
    private static let lcBuildVersion: UInt32 = 0x32
    private static let lcVersionMinIPhoneOS: UInt32 = 0x25
    private static let platformIOS: UInt32 = 2

    /// The target from settings, or nil when patching is off or the value is invalid.
    static var configuredTarget: UInt32? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: enabledKey) else { return nil }
        return encode(defaults.string(forKey: targetKey) ?? defaultTarget)
    }

    /// "27.1" → 0x001B0100 (xxxx.yy.zz nibbles, as Mach-O stores it).
    static func encode(_ text: String) -> UInt32? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [UInt32] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = UInt32(part) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        guard numbers[0] <= 0xFFFF, numbers[1] <= 0xFF, numbers[2] <= 0xFF else { return nil }
        return numbers[0] << 16 | numbers[1] << 8 | numbers[2]
    }

    static func describe(_ version: UInt32) -> String {
        let patch = version & 0xFF
        return "\(version >> 16).\((version >> 8) & 0xFF)" + (patch == 0 ? "" : ".\(patch)")
    }

    // MARK: - app bundle

    /// Patches the main executable of the app and of every extension, and the
    /// matching `DTSDKName` / `DTPlatformVersion` keys. Only ever raises.
    static func patchApp(at appDir: URL, to requested: UInt32, log: (String) -> Void) -> [Change] {
        let manager = FileManager.default
        var target = requested
        let mainInfo = readPlist(appDir.appendingPathComponent("Info.plist"))
        if target >= sceneRequiredFrom, let info = mainInfo?.value, info["UIApplicationSceneManifest"] == nil {
            target = capWithoutScenes
            log("no UIApplicationSceneManifest: SDK \(describe(requested)) would stop this app launching, using \(describe(target))")
        }

        var bundles = [appDir]
        for folder in ["PlugIns", "Extensions"] {
            let directory = appDir.appendingPathComponent(folder, isDirectory: true)
            let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
            bundles += names.filter { $0.hasSuffix(".appex") }.sorted()
                .map { directory.appendingPathComponent($0, isDirectory: true) }
        }

        var changes: [Change] = []
        for bundle in bundles {
            let plistURL = bundle.appendingPathComponent("Info.plist")
            guard let plist = readPlist(plistURL),
                  let executable = plist.value["CFBundleExecutable"] as? String,
                  !executable.isEmpty, !executable.contains("/") else {
                log("skipped \(bundle.lastPathComponent): no CFBundleExecutable")
                continue
            }
            let relative = bundle == appDir ? executable
                : String(bundle.path.dropFirst(appDir.path.count + 1)) + "/" + executable
            let old: [UInt32]
            do {
                old = try patchFile(at: bundle.appendingPathComponent(executable), to: target)
            } catch {
                log("skipped \(relative): \(error)")
                continue
            }
            guard !old.isEmpty else {
                log("\(relative): already SDK \(describe(target)) or newer")
                continue
            }
            changes.append(Change(path: relative, old: old, new: target))
            log("\(relative): SDK \(old.map(describe).joined(separator: "/")) -> \(describe(target))")

            var updated = plist.value
            updated["DTSDKName"] = "iphoneos" + describe(target)
            updated["DTPlatformVersion"] = describe(target)
            if let data = try? PropertyListSerialization.data(fromPropertyList: updated, format: plist.format, options: 0) {
                try? data.write(to: plistURL, options: .atomic)
            }
        }
        return changes
    }

    private static func readPlist(_ url: URL) -> (value: [String: Any], format: PropertyListSerialization.PropertyListFormat)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
              let dictionary = value as? [String: Any] else { return nil }
        return (dictionary, format)
    }

    // MARK: - Mach-O

    /// Raises every iOS SDK field below `target` in the file, writing only the
    /// load-command region in place (permissions and the rest of the file are
    /// untouched). Returns the old values that were changed.
    static func patchFile(at url: URL, to target: UInt32) throws -> [UInt32] {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 8), head.count == 8 else { throw PatchError.notMachO }

        var offsets: [UInt64] = [0]
        let outer = readBE32(head, 0)
        if outer == fatMagic || outer == fatMagic64 {
            let is64 = outer == fatMagic64
            let count = Int(readBE32(head, 4))
            guard count > 0, count <= 64 else { throw PatchError.notMachO }
            let stride = is64 ? 32 : 20
            guard let table = try handle.read(upToCount: count * stride), table.count == count * stride else {
                throw PatchError.truncated
            }
            offsets = (0..<count).map { index in
                is64 ? readBE64(table, index * stride + 8) : UInt64(readBE32(table, index * stride + 8))
            }
        }

        var changed: [UInt32] = []
        for offset in offsets {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 28), header.count == 28 else { throw PatchError.truncated }
            let headerSize: Int
            switch readLE32(header, 0) {
            case magic64: headerSize = 32
            case magic32: headerSize = 28
            default: throw PatchError.notMachO
            }
            let sizeOfCommands = Int(readLE32(header, 20))
            guard sizeOfCommands < 16 << 20 else { throw PatchError.truncated }
            let length = headerSize + sizeOfCommands
            try handle.seek(toOffset: offset)
            guard var region = try handle.read(upToCount: length), region.count == length else {
                throw PatchError.truncated
            }
            let old = try patchCommands(&region, to: target)
            if !old.isEmpty {
                try handle.seek(toOffset: offset)
                try handle.write(contentsOf: region)
                changed += old
            }
        }
        return changed
    }

    /// `region` starts at a thin Mach-O header and holds all of its load commands.
    static func patchCommands(_ region: inout Data, to target: UInt32) throws -> [UInt32] {
        guard region.count >= 28 else { throw PatchError.truncated }
        let headerSize: Int
        switch readLE32(region, 0) {
        case magic64: headerSize = 32
        case magic32: headerSize = 28
        default: throw PatchError.notMachO
        }
        let commandCount = Int(readLE32(region, 16))
        let end = headerSize + Int(readLE32(region, 20))
        guard end <= region.count else { throw PatchError.truncated }

        var cursor = headerSize
        var changed: [UInt32] = []
        for _ in 0..<commandCount {
            guard cursor + 8 <= end else { throw PatchError.truncated }
            let command = readLE32(region, cursor) & 0x7FFF_FFFF
            let size = Int(readLE32(region, cursor + 4))
            guard size >= 8, cursor + size <= end else { throw PatchError.truncated }
            var sdkOffset: Int?
            if command == lcBuildVersion, size >= 24, readLE32(region, cursor + 8) == platformIOS {
                sdkOffset = cursor + 16
            } else if command == lcVersionMinIPhoneOS, size >= 16 {
                sdkOffset = cursor + 12
            }
            if let sdkOffset {
                let old = readLE32(region, sdkOffset)
                if old < target {
                    writeLE32(&region, sdkOffset, target)
                    changed.append(old)
                }
            }
            cursor += size
        }
        return changed
    }

    private static func readLE32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    private static func readBE32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    private static func readBE64(_ data: Data, _ offset: Int) -> UInt64 {
        data.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }

    private static func writeLE32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        data.withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self) }
    }
}
