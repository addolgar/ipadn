import Foundation
import UIKit

/// An app iPadn decrypted and re-signed (usually with a raised SDK), kept so
/// that newer App Store versions can be prepared the same way.
struct PatchedApp: Codable, Identifiable, Equatable, Sendable {
    var id: String { bundleID }
    var bundleID: String
    /// App Store item ID. Nil for imported IPAs, which cannot be checked.
    var storeID: String?
    var name: String
    /// The newest version prepared (decrypted, patched and signed).
    var version: String
    var storeVersionID: String?
    var iconURL: URL?
    /// SDK raise for this app, e.g. "27.1"; nil when off.
    var sdkTarget: String?
    var certificateID: UUID?
    var fixAppGroups: Bool
    /// Included in "update all".
    var autoUpdate: Bool
    var updated: Date
    /// A signed update that is ready but not installed yet.
    var readyRecordID: UUID?
    var readyVersion: String?
    var lastError: String?

    init(bundleID: String, name: String, version: String) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        fixAppGroups = false
        autoUpdate = true
        updated = Date()
    }
}

/// The apps to keep updated, filled in whenever a re-signed decryption
/// finishes. Stored as JSON in Application Support.
@MainActor
final class PatchedAppStore: ObservableObject {
    static let shared = PatchedAppStore()
    private static let backfillKey = "patchedApps.backfilled"

    @Published private(set) var apps: [PatchedApp] = []
    private var prepared = false

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PatchedApps.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([PatchedApp].self, from: data) {
            apps = decoded
        }
    }

    func app(_ bundleID: String) -> PatchedApp? { apps.first { $0.bundleID == bundleID } }

    /// Once: adds apps re-signed before this list existed, from the decryption
    /// history. Their settings are read back from the signed package.
    func prepare() async {
        guard !prepared else { return }
        prepared = true
        DecryptRecordStore.shared.load()
        await AppContainer.shared.downloads.loaded()
        guard !UserDefaults.standard.bool(forKey: Self.backfillKey) else { return }
        let records = DecryptRecordStore.shared.records
            .filter { $0.state == .finished && $0.signedWith != nil && $0.bundleID != nil }
            .sorted { $0.startedAt < $1.startedAt }
        let outputs = records.compactMap { record in
            DecryptRecordStore.shared.outputURL(for: record).map { (record.id, $0) }
        }
        // GroupFix leaves its dylib in the package: the one setting worth recovering.
        let grouped: Set<UUID> = await Task.detached(priority: .utility) {
            Set(outputs.compactMap { id, url in
                ZipDirectory(url: url)?.entries.contains { $0.name.hasSuffix("/Frameworks/GroupFix.dylib") } == true ? id : nil
            })
        }.value
        let certificates = SigningFiles.loadIndex()
        for record in records {
            remember(record,
                     sdkTarget: SDKVersionPatcher.configuredTarget,
                     certificateID: certificates.first { $0.name == record.signedWith }?.id,
                     fixAppGroups: grouped.contains(record.id))
        }
        UserDefaults.standard.set(true, forKey: Self.backfillKey)
    }

    /// Adds or refreshes the app a clean, re-signed decryption produced.
    func remember(_ record: DecryptRecord, sdkTarget: UInt32?, certificateID: UUID?, fixAppGroups: Bool) {
        guard let bundleID = record.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty else { return }
        let job = record.sourceJobID.flatMap { id in AppContainer.shared.downloads.jobs.first { $0.id == id } }
        var entry = app(bundleID) ?? PatchedApp(bundleID: bundleID, name: record.appName, version: "")
        entry.name = job?.app.name ?? record.appName
        if let version = record.version, !version.isEmpty { entry.version = version }
        if let job, let id = UInt64(job.app.id), id > 0 {
            entry.storeID = String(id)
            entry.storeVersionID = job.app.externalVersionID
        }
        entry.iconURL = job?.app.iconURL ?? entry.iconURL ?? DecryptRecordStore.shared.iconURL(for: record)
        entry.sdkTarget = sdkTarget.map(SDKVersionPatcher.describe)
        entry.certificateID = certificateID
        entry.fixAppGroups = fixAppGroups
        entry.updated = Date()
        entry.lastError = nil
        // A newer run supersedes an update that was waiting to be installed.
        if entry.readyRecordID != record.id { entry.readyRecordID = nil; entry.readyVersion = nil }
        upsert(entry)
    }

    func update(_ bundleID: String, _ body: (inout PatchedApp) -> Void) {
        guard var entry = app(bundleID) else { return }
        body(&entry)
        upsert(entry)
    }

    func remove(_ bundleID: String) {
        apps.removeAll { $0.bundleID == bundleID }
        save()
    }

    private func upsert(_ entry: PatchedApp) {
        if let index = apps.firstIndex(where: { $0.bundleID == entry.bundleID }) {
            apps[index] = entry
        } else {
            apps.append(entry)
        }
        save()
    }

    private func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(apps).write(to: url, options: .atomic)
    }
}

/// Keeps patched apps current: checks the App Store, then for each newer
/// version downloads it, decrypts, raises the SDK and re-signs it with the
/// app's own settings, and installs it. Native installation needs the
/// LocalDevVPN tunnel; it is switched on for the installs and off afterwards.
@MainActor
final class PatchedAppUpdater: ObservableObject {
    static let shared = PatchedAppUpdater()
    static let autoKey = "patchedApps.autoUpdate"
    static let vpnKey = "patchedApps.toggleVPN"
    private static let checkedKey = "patchedApps.lastChecked"
    /// Automatic runs check at most this often.
    static let autoInterval: TimeInterval = 6 * 3600

    /// Newer store listings by bundle ID.
    @Published private(set) var listings: [String: StoreApp] = [:]
    @Published private(set) var checking = false
    @Published private(set) var running = false
    /// What the current run is doing, for the UI.
    @Published private(set) var status: String?
    @Published private(set) var lastChecked: Date?

    /// Downloads started by a run: the auto-decrypt setting must leave them
    /// to the run, which signs them with the app's own settings.
    private(set) var ownedJobIDs: Set<UUID> = []
    private var task: Task<Void, Never>?
    private var backgroundID = UIBackgroundTaskIdentifier.invalid

    private var apps: PatchedAppStore { .shared }

    init() {
        lastChecked = UserDefaults.standard.object(forKey: Self.checkedKey) as? Date
    }

    static var togglesVPN: Bool { UserDefaults.standard.object(forKey: vpnKey) as? Bool ?? true }

    /// Native installation is silent and keeps data; without it each update
    /// waits for the user to confirm the system prompt.
    static var canInstallNatively: Bool {
        NativeInstaller.hasPairingFile && NativeInstaller.isAvailable && NativeInstaller.isSystemVersionSupported
    }

    /// Whether the store has a version newer than the one last prepared.
    nonisolated static func needsUpdate(_ app: PatchedApp, latest: StoreApp) -> Bool {
        guard !app.version.isEmpty else { return true }
        return InstalledAppsView.isUpdate(latest, installed: app.version, versionID: app.storeVersionID)
    }

    // MARK: checking

    /// Looks up the store versions of every tracked app.
    @discardableResult
    func check() async -> [PatchedApp] {
        await apps.prepare()
        let tracked = apps.apps.filter { $0.storeID != nil }
        guard !tracked.isEmpty else { listings = [:]; return [] }
        checking = true
        defer { checking = false }
        let container = AppContainer.shared
        let country = container.apple.active.flatMap { StoreService.country(forStorefront: $0.storeFront) }
            ?? container.settings.store.country
        do {
            let found = try await StoreService.lookup(ids: tracked.compactMap(\.storeID), country: country).apps
            var newer: [String: StoreApp] = [:]
            for app in tracked {
                guard let id = app.storeID, let latest = found[id], Self.needsUpdate(app, latest: latest) else { continue }
                newer[app.bundleID] = latest
            }
            listings = newer
            let now = Date()
            lastChecked = now
            UserDefaults.standard.set(now, forKey: Self.checkedKey)
        } catch {
            container.errorMessage = error.localizedDescription
        }
        return apps.apps.filter { listings[$0.bundleID] != nil }
    }

    // MARK: running

    /// Called when iPadn comes to the front: runs when automatic updates are
    /// on and the last check is old enough.
    func autoRunIfDue() {
        guard UserDefaults.standard.bool(forKey: Self.autoKey), !running, !checking,
              AppContainer.shared.settings.proMode, AppContainer.shared.apple.active != nil else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.autoInterval { return }
        updateAll(userInitiated: false)
    }

    /// Checks, prepares every update and installs them. Ignored while running.
    func updateAll(userInitiated: Bool = true) {
        guard !running else { return }
        running = true
        task = Task { await run(userInitiated: userInitiated) }
    }

    func cancel() {
        task?.cancel()
        status = AppText.text("正在取消…")
    }

    private func run(userInitiated: Bool) async {
        let container = AppContainer.shared
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundID = UIApplication.shared.beginBackgroundTask(withName: "iPadn patched-app update") { [weak self] in
            // Out of background time: the run carries on when iPadn is back.
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        defer {
            running = false
            status = nil
            ownedJobIDs.removeAll()
            UIApplication.shared.isIdleTimerDisabled = false
            endBackgroundTask()
        }

        status = AppText.text("正在检查更新…")
        let due = await check().filter(\.autoUpdate)
        var failures: [String] = []

        if !due.isEmpty {
            if container.apple.active == nil {
                container.errorMessage = AppText.text("请先在「账号」中登录 Apple 账号")
                return
            }
            for (index, app) in due.enumerated() {
                if Task.isCancelled { break }
                guard let latest = listings[app.bundleID] else { continue }
                do {
                    status = AppText.text("正在下载 \(app.name)（\(index + 1)/\(due.count)）")
                    let job = try await download(latest)
                    status = AppText.text("正在解密并签名 \(app.name)")
                    let recordID = try await process(app, job: job)
                    apps.update(app.bundleID) { entry in
                        entry.version = latest.version
                        entry.storeVersionID = latest.externalVersionID
                        entry.readyRecordID = recordID
                        entry.readyVersion = latest.version
                        entry.lastError = nil
                    }
                    listings[app.bundleID] = nil
                } catch is CancellationError {
                    break
                } catch {
                    apps.update(app.bundleID) { $0.lastError = error.localizedDescription }
                    failures.append(AppText.text("\(app.name)：\(error.localizedDescription)"))
                }
            }
        }

        // Installs this run's updates and any left over from an earlier one.
        let ready = apps.apps.filter { $0.autoUpdate && $0.readyRecordID != nil }
        var installed = 0
        if !ready.isEmpty, !Task.isCancelled {
            if Self.canInstallNatively {
                let result = await installNatively(ready)
                installed = result.installed
                failures += result.failures
            } else {
                container.infoMessage = AppText.text("\(ready.count) 个更新已准备好，请在「已修改的应用」中逐个安装")
            }
        }

        if installed > 0 { container.infoMessage = AppText.text("已更新 \(installed) 个应用") }
        if !failures.isEmpty { container.errorMessage = failures.joined(separator: "\n") }
        if userInitiated, due.isEmpty, ready.isEmpty, failures.isEmpty, !Task.isCancelled {
            container.infoMessage = AppText.text("已修改的应用都是最新版本。")
        }
    }

    private func endBackgroundTask() {
        guard backgroundID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundID)
        backgroundID = .invalid
    }

    /// Adds the store's current version to the download queue (or reuses a
    /// finished or queued download of it) and waits until it is on disk.
    private func download(_ latest: StoreApp) async throws -> DownloadJob {
        let container = AppContainer.shared
        let downloads = container.downloads
        guard container.settings.store.platform == .iOS || container.settings.store.platform == .iPadOS else {
            throw ToolError.message(AppText.text("请在设置中把商店平台切换为 iPhone 或 iPad"))
        }
        func isCurrent(_ job: DownloadJob) -> Bool {
            job.app.id == latest.id && job.rawFormat == nil
                && !InstalledAppsView.isUpdate(latest, installed: job.app.version, versionID: job.app.externalVersionID)
        }
        if let done = downloads.jobs.first(where: { $0.status == .completed && isCurrent($0) && downloads.fileURL($0) != nil }) {
            return done
        }
        let before = Set(downloads.jobs.map(\.id))
        do {
            try await container.startDownload(app: latest, versionID: nil)
        } catch {
            // "This version is already downloading": follow that task instead.
            guard downloads.jobs.contains(where: { $0.app.id == latest.id && ![.completed, .failed].contains($0.status) })
            else { throw error }
        }
        guard let jobID = downloads.jobs.first(where: { !before.contains($0.id) && $0.app.id == latest.id })?.id
            ?? downloads.jobs.first(where: { $0.app.id == latest.id && ![.completed, .failed].contains($0.status) })?.id
        else { throw ToolError.message(AppText.text("下载任务未能创建")) }
        ownedJobIDs.insert(jobID)
        while true {
            try Task.checkCancellation()
            guard let job = downloads.jobs.first(where: { $0.id == jobID }) else {
                throw ToolError.message(AppText.text("下载任务已被移除"))
            }
            switch job.status {
            case .completed:
                guard downloads.fileURL(job) != nil else { throw ToolError.message(AppText.text("下载任务已被移除")) }
                return job
            case .failed:
                throw ToolError.message(job.error ?? AppText.text("下载失败"))
            default:
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Decrypts, patches and signs with the app's own settings. Returns the
    /// decryption record of the signed package.
    private func process(_ app: PatchedApp, job: DownloadJob) async throws -> UUID {
        let service = FairPlayHub.shared.service
        // One run at a time: wait for one the user started.
        while service.isRunning { try await Task.sleep(for: .seconds(1)) }
        guard let source = AppContainer.shared.downloads.fileURL(job) else {
            throw ToolError.message(AppText.text("原始 IPA 已不存在，请重新导入。"))
        }
        guard let signing = SigningFiles.material(for: app.certificateID) else {
            throw ToolError.message(AppText.text("还没有可用的签名证书"))
        }
        let options = FairPlayService.ProcessingOptions(
            sdkTarget: app.sdkTarget.flatMap(SDKVersionPatcher.encode),
            signing: signing,
            fixAppGroups: app.fixAppGroups)
        guard let recordID = FairPlayPresentation.shared.startForUpdate(url: source, job: job, options: options) else {
            throw ToolError.message(AppText.text("当前已有解密任务正在进行，请等待完成后再试。"))
        }
        var cancelled = false
        while service.isRunning && service.activeRecordID == recordID {
            if Task.isCancelled && !cancelled {
                cancelled = true
                service.cancel()
            }
            await Self.pause(0.5)
        }
        if cancelled { throw CancellationError() }
        let records = DecryptRecordStore.shared
        guard let record = records.records.first(where: { $0.id == recordID }) else {
            throw ToolError.message(AppText.text("签名失败"))
        }
        guard record.state == .finished else {
            throw ToolError.message(record.failure?.reason ?? AppText.text("签名失败"))
        }
        guard record.signedWith != nil, records.outputURL(for: record) != nil else {
            throw ToolError.message(AppText.text("签名失败"))
        }
        return recordID
    }

    // MARK: installing

    /// Installs one prepared update from its page. Natively when paired
    /// (switching LocalDevVPN as needed), otherwise through the system prompt.
    func installReady(_ bundleID: String) async throws -> String {
        guard let app = apps.app(bundleID) else { throw ToolError.message(AppText.text("找不到已签名的安装包")) }
        if Self.canInstallNatively {
            let result = await installNatively([app])
            if let failure = result.failures.first { throw ToolError.message(failure) }
            return AppText.text("已覆盖安装，原有数据保留。")
        }
        let package = try readyPackage(app)
        let message = try await SignedPackageInstaller.install(
            package, name: app.name, bundleID: app.bundleID, version: app.readyVersion,
            installation: AppContainer.shared.installation)
        // The system prompt gives no result back; the user confirmed by tapping.
        markInstalled(bundleID)
        return message
    }

    private func readyPackage(_ app: PatchedApp) throws -> URL {
        let records = DecryptRecordStore.shared
        guard let id = app.readyRecordID,
              let record = records.records.first(where: { $0.id == id }),
              let package = records.outputURL(for: record) else {
            apps.update(app.bundleID) { $0.readyRecordID = nil; $0.readyVersion = nil }
            throw ToolError.message(AppText.text("找不到已签名的安装包"))
        }
        return package
    }

    private func markInstalled(_ bundleID: String) {
        apps.update(bundleID) { entry in
            entry.readyRecordID = nil
            entry.readyVersion = nil
            entry.lastError = nil
            entry.updated = Date()
        }
    }

    private func installNatively(_ ready: [PatchedApp]) async -> (installed: Int, failures: [String]) {
        status = AppText.text("正在连接 LocalDevVPN…")
        var switchedOn = false
        if !(await Self.isConnected()) {
            guard Self.togglesVPN else {
                return (0, [AppText.text("没有连接 LocalDevVPN，无法原生安装。请打开 LocalDevVPN 后重试。")])
            }
            guard await Self.switchVPN(on: true) else {
                return (0, [AppText.text("无法打开 LocalDevVPN，请确认已安装。")])
            }
            switchedOn = true
            guard await Self.waitForConnection() else {
                _ = await Self.switchVPN(on: false)
                return (0, [AppText.text("没有连接 LocalDevVPN，无法原生安装。请打开 LocalDevVPN 后重试。")])
            }
        }
        var installed = 0
        var failures: [String] = []
        for app in ready {
            if Task.isCancelled { break }
            status = AppText.text("正在安装 \(app.name)")
            do {
                let package = try readyPackage(app)
                _ = try await SignedPackageInstaller.install(
                    package, name: app.name, bundleID: app.bundleID, version: app.readyVersion,
                    installation: AppContainer.shared.installation)
                markInstalled(app.bundleID)
                installed += 1
            } catch {
                apps.update(app.bundleID) { $0.lastError = error.localizedDescription }
                failures.append(AppText.text("\(app.name)：\(error.localizedDescription)"))
            }
        }
        // Leave the tunnel as it was found.
        if switchedOn { _ = await Self.switchVPN(on: false) }
        return (installed, failures)
    }

    /// The native installation service answers only through the tunnel.
    private static func isConnected() async -> Bool {
        do {
            _ = try await NativeInstaller.lookup(bundleID: Bundle.main.bundleIdentifier ?? "app.local.iPadn")
            return true
        } catch {
            return false
        }
    }

    /// LocalDevVPN returns about a second after it was asked, whether or not
    /// the tunnel is up yet, so keep asking for a while.
    private static func waitForConnection() async -> Bool {
        for _ in 0..<10 {
            if Task.isCancelled { return false }
            if await isConnected() { return true }
            await pause(2)
        }
        return false
    }

    /// Opens LocalDevVPN to connect or disconnect; it switches back to iPadn
    /// (ipadn://) on its own. Returns false when LocalDevVPN is not installed.
    private static func switchVPN(on: Bool) async -> Bool {
        guard let url = URL(string: "localdevvpn://\(on ? "enable" : "disable")?scheme=ipadn"),
              await UIApplication.shared.open(url) else { return false }
        // Wait to leave the foreground, then to come back.
        for _ in 0..<30 where UIApplication.shared.applicationState == .active { await pause(0.1) }
        for _ in 0..<300 where UIApplication.shared.applicationState != .active { await pause(0.1) }
        await pause(0.5)
        return true
    }

    /// A sleep that also finishes in a cancelled task, for waits that must
    /// run to the end (handing a cancelled decryption back, switching the
    /// tunnel off).
    private static func pause(_ seconds: Double) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }
}
