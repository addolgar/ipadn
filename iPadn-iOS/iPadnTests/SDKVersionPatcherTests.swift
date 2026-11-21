import XCTest
@testable import iPadn

final class SDKVersionPatcherTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdkpatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - fixtures

    private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    private func buildVersion(minos: UInt32, sdk: UInt32, platform: UInt32 = 2) -> Data {
        le32(0x32) + le32(24) + le32(platform) + le32(minos) + le32(sdk) + le32(0)
    }

    private func versionMin(minos: UInt32, sdk: UInt32) -> Data {
        le32(0x25) + le32(16) + le32(minos) + le32(sdk)
    }

    private func thin(_ commands: [Data]) -> Data {
        let body = commands.reduce(Data(), +)
        let header = le32(0xFEED_FACF) + le32(0x0100_000C) + le32(0) + le32(2)
            + le32(UInt32(commands.count)) + le32(UInt32(body.count)) + le32(0) + le32(0)
        return header + body + Data(count: 64)
    }

    private func fat(_ slices: [Data]) -> Data {
        var file = be32(0xCAFE_BABE) + be32(UInt32(slices.count))
        var offsets: [Int] = []
        var next = 0x1000
        for slice in slices {
            offsets.append(next)
            file += be32(0x0100_000C) + be32(0) + be32(UInt32(next)) + be32(UInt32(slice.count)) + be32(12)
            next += 0x1000
        }
        for (slice, offset) in zip(slices, offsets) {
            file += Data(count: offset - file.count)
            file += slice
        }
        return file
    }

    private func sdkValues(in url: URL) throws -> [UInt32] {
        // Patching to version 0 never changes anything, so this only reads.
        let data = try Data(contentsOf: url)
        var values: [UInt32] = []
        var index = 0
        while index + 24 <= data.count {
            let command = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: index, as: UInt32.self)) }
            let size = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: index + 4, as: UInt32.self)) }
            if command == 0x32, size == 24 {
                values.append(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: index + 16, as: UInt32.self)) })
                index += 24
            } else if command == 0x25, size == 16 {
                values.append(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: index + 12, as: UInt32.self)) })
                index += 16
            } else {
                index += 4
            }
        }
        return values
    }

    // MARK: - tests

    func testVersionEncoding() {
        XCTAssertEqual(SDKVersionPatcher.encode("27.1"), 0x001B_0100)
        XCTAssertEqual(SDKVersionPatcher.encode("26"), 0x001A_0000)
        XCTAssertEqual(SDKVersionPatcher.encode(" 16.4.1 "), 0x0010_0401)
        XCTAssertNil(SDKVersionPatcher.encode("27,1"))
        XCTAssertNil(SDKVersionPatcher.encode("27."))
        XCTAssertNil(SDKVersionPatcher.encode("27.256"))
        XCTAssertNil(SDKVersionPatcher.encode(""))
        XCTAssertEqual(SDKVersionPatcher.describe(0x001B_0100), "27.1")
        XCTAssertEqual(SDKVersionPatcher.describe(0x0010_0401), "16.4.1")
    }

    func testThinFileRaisesOnlyOlderIOSFields() throws {
        let url = directory.appendingPathComponent("thin")
        let target = SDKVersionPatcher.encode("27.1")!
        try thin([buildVersion(minos: 15 << 16, sdk: 16 << 16 | 4 << 8),
                  buildVersion(minos: 15 << 16, sdk: 14 << 16, platform: 6),  // Mac Catalyst: untouched
                  versionMin(minos: 12 << 16, sdk: 28 << 16)])                 // already newer: untouched
            .write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let old = try SDKVersionPatcher.patchFile(at: url, to: target)
        XCTAssertEqual(old, [16 << 16 | 4 << 8])
        XCTAssertEqual(try sdkValues(in: url), [target, 14 << 16, 28 << 16])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o755)
        XCTAssertEqual(try SDKVersionPatcher.patchFile(at: url, to: target), [], "a second run changes nothing")
    }

    func testFatFilePatchesEverySlice() throws {
        let url = directory.appendingPathComponent("fat")
        let target = SDKVersionPatcher.encode("27.1")!
        try fat([thin([buildVersion(minos: 15 << 16, sdk: 26 << 16)]),
                 thin([versionMin(minos: 12 << 16, sdk: 14 << 16)])]).write(to: url)
        let old = try SDKVersionPatcher.patchFile(at: url, to: target)
        XCTAssertEqual(old, [26 << 16, 14 << 16])
        XCTAssertEqual(try sdkValues(in: url), [target, target])
    }

    func testNonMachOIsRejected() throws {
        let url = directory.appendingPathComponent("text")
        try Data("not a binary at all, just text".utf8).write(to: url)
        XCTAssertThrowsError(try SDKVersionPatcher.patchFile(at: url, to: 27 << 16)) { error in
            XCTAssertEqual(error as? SDKVersionPatcher.PatchError, .notMachO)
        }
    }

    private func makeBundle(_ url: URL, executable: String, sdk: UInt32, extra: [String: Any] = [:]) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleExecutable": executable, "DTSDKName": "iphoneos16.0", "DTPlatformVersion": "16.0"]
        info.merge(extra) { _, new in new }
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: url.appendingPathComponent("Info.plist"))
        try thin([buildVersion(minos: 15 << 16, sdk: sdk)]).write(to: url.appendingPathComponent(executable))
    }

    private func info(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testAppAndExtensionsArePatchedWithInfoKeys() throws {
        let app = directory.appendingPathComponent("Demo.app", isDirectory: true)
        let scenes: [String: Any] = ["UIApplicationSceneManifest": ["UIApplicationSupportsMultipleScenes": false]]
        try makeBundle(app, executable: "Demo", sdk: 16 << 16, extra: scenes)
        let widget = app.appendingPathComponent("PlugIns/Widget.appex", isDirectory: true)
        try makeBundle(widget, executable: "Widget", sdk: 16 << 16)
        let target = SDKVersionPatcher.encode("27.1")!

        var lines: [String] = []
        let changes = SDKVersionPatcher.patchApp(at: app, to: target) { lines.append($0) }
        XCTAssertEqual(changes.map(\.path), ["Demo", "PlugIns/Widget.appex/Widget"])
        XCTAssertEqual(changes.map(\.new), [target, target])
        XCTAssertEqual(try sdkValues(in: app.appendingPathComponent("Demo")), [target])
        XCTAssertEqual(try sdkValues(in: widget.appendingPathComponent("Widget")), [target])
        XCTAssertEqual(try info(app)["DTSDKName"] as? String, "iphoneos27.1")
        XCTAssertEqual(try info(widget)["DTPlatformVersion"] as? String, "27.1")
        XCTAssertNotNil(try info(app)["UIApplicationSceneManifest"], "other keys are kept")
        XCTAssertFalse(lines.isEmpty)
    }

    func testAppWithoutScenesIsCappedBelowTwentySeven() throws {
        let app = directory.appendingPathComponent("Old.app", isDirectory: true)
        try makeBundle(app, executable: "Old", sdk: 14 << 16)
        var lines: [String] = []
        let changes = SDKVersionPatcher.patchApp(at: app, to: SDKVersionPatcher.encode("27.1")!) { lines.append($0) }
        XCTAssertEqual(changes.first?.new, SDKVersionPatcher.capWithoutScenes)
        XCTAssertEqual(try sdkValues(in: app.appendingPathComponent("Old")), [SDKVersionPatcher.capWithoutScenes])
        XCTAssertTrue(lines.contains { $0.contains("UIApplicationSceneManifest") })
    }
}
