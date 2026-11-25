import XCTest
@testable import iPadn

final class PatchedAppUpdaterTests: XCTestCase {
    private func patched(_ version: String, versionID: String? = nil) -> PatchedApp {
        var app = PatchedApp(bundleID: "com.example.app", name: "Example", version: version)
        app.storeID = "123456789"
        app.storeVersionID = versionID
        return app
    }

    private func listing(_ version: String, versionID: String? = nil) -> StoreApp {
        var app = StoreApp(id: "123456789", name: "Example", bundleID: "com.example.app", version: version)
        app.externalVersionID = versionID
        return app
    }

    func testNewerStoreVersionIsAnUpdate() {
        XCTAssertTrue(PatchedAppUpdater.needsUpdate(patched("7.12.3"), latest: listing("7.13.0")))
        XCTAssertTrue(PatchedAppUpdater.needsUpdate(patched("1.9"), latest: listing("1.10")))
    }

    func testSameOrOlderStoreVersionIsNot() {
        XCTAssertFalse(PatchedAppUpdater.needsUpdate(patched("7.12.3"), latest: listing("7.12.3")))
        XCTAssertFalse(PatchedAppUpdater.needsUpdate(patched("7.13.0"), latest: listing("7.12.3")))
    }

    func testBuildSuffixAndVersionIDMeanTheSameRelease() {
        XCTAssertFalse(PatchedAppUpdater.needsUpdate(patched("10.0.10"), latest: listing("10.0.10.105")))
        XCTAssertFalse(PatchedAppUpdater.needsUpdate(patched("1.0", versionID: "8800"), latest: listing("1.1", versionID: "8800")))
    }

    func testUnknownPreparedVersionIsUpdated() {
        XCTAssertTrue(PatchedAppUpdater.needsUpdate(patched(""), latest: listing("2.0")))
    }

    func testPatchedAppRoundTrips() throws {
        var app = patched("7.12.3", versionID: "1")
        app.sdkTarget = "27.1"
        app.certificateID = UUID()
        app.fixAppGroups = true
        app.readyRecordID = UUID()
        app.readyVersion = "7.13.0"
        let decoded = try JSONDecoder().decode(PatchedApp.self, from: JSONEncoder().encode(app))
        XCTAssertEqual(decoded, app)
    }
}
