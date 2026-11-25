import Foundation
import UIKit
import Zsign

/// Re-signs an unpacked .app folder with an imported certificate (zsign, MIT).
/// The bundle ID is kept, so a later update signed with the same certificate
/// replaces the app and keeps its data.
enum AppSigner {
    /// Blocking; call from a background queue. Signs nested frameworks and
    /// extensions too, and embeds the certificate's provisioning profile.
    /// With `fixAppGroups`, injects GroupFix so a re-signed app can still reach
    /// the App Groups / keychain groups it was built for (needed by apps that
    /// share data with their extensions, e.g. mail clients).
    static func sign(appDir: URL, with material: SigningFiles.Material,
                     fixAppGroups: Bool = false, log: (String) -> Void) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: material.p12.path), manager.fileExists(atPath: material.profile.path) else {
            throw ToolError.message(AppText.text("还没有可用的签名证书"))
        }
        // Inject BEFORE signing so the load command and the copied dylib are
        // covered by the new signature.
        if fixAppGroups {
            do { try injectGroupFix(into: appDir, material: material, log: log) }
            catch { log("group fix skipped: \(error.localizedDescription)") }
        }
        // Same clean-up Feather does before zsign: old signatures and profiles
        // (zsign does not replace an existing embedded.mobileprovision), plus
        // FairPlay leftovers that only mean something next to Apple's signature.
        var removed = 0
        for name in ["embedded.mobileprovision", "com.apple.WatchPlaceholder", "SignedByEsign"] {
            if (try? manager.removeItem(at: appDir.appendingPathComponent(name))) != nil { removed += 1 }
        }
        if let walker = manager.enumerator(at: appDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in walker where ["_CodeSignature", "SC_Info"].contains(url.lastPathComponent) {
                if (try? manager.removeItem(at: url)) != nil { removed += 1 }
                walker.skipDescendants()
            }
        }
        if removed > 0 { log("removed \(removed) old signature/profile item(s)") }

        // zsign calls the completion block unconditionally: passing none crashes.
        var succeeded = false
        let returned = Zsign.sign(appPath: appDir.path,
                                  provisionPath: material.profile.path,
                                  p12Path: material.p12.path,
                                  p12Password: material.password,
                                  removeProvision: true,
                                  completion: { success in succeeded = success })
        guard returned, succeeded else { throw ToolError.message(AppText.text("签名失败")) }
        log("signed with \(material.certificate.name) (\(material.certificate.teamID))")
    }

    /// Copies GroupFix.dylib into the app's Frameworks, writes its config, and
    /// adds a load command to the main executable so it loads at launch.
    private static func injectGroupFix(into appDir: URL, material: SigningFiles.Material,
                                       log: (String) -> Void) throws {
        let manager = FileManager.default
        guard let source = Bundle.main.url(forResource: "GroupFix", withExtension: "dylib") else {
            throw ToolError.message("GroupFix.dylib missing from iPadn")
        }
        guard let granted = material.certificate.appGroups.first else {
            throw ToolError.message(AppText.text("签名证书未授予 App Group"))
        }
        // Read the main executable name from the app's Info.plist.
        let infoURL = appDir.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty else {
            throw ToolError.message("no CFBundleExecutable")
        }

        let frameworks = appDir.appendingPathComponent("Frameworks", isDirectory: true)
        try manager.createDirectory(at: frameworks, withIntermediateDirectories: true)
        let dylib = frameworks.appendingPathComponent("GroupFix.dylib")
        try? manager.removeItem(at: dylib)
        try manager.copyItem(at: source, to: dylib)

        // Config read by GroupFix at launch, next to the dylib.
        let config: [String: Any] = [
            "fallbackGroup": granted,
            "newTeam": material.certificate.teamID,
        ]
        try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
            .write(to: frameworks.appendingPathComponent("GroupFix.plist"))

        let executableURL = appDir.appendingPathComponent(executable)
        guard Zsign.injectDyLib(appExecutable: executableURL.path, with: "@rpath/GroupFix.dylib", weak: true) else {
            throw ToolError.message("inject failed")
        }
        log("group fix: mapped app groups -> \(granted), keychain team -> \(material.certificate.teamID)")
    }
}

/// Installs a package that is already signed for this device: natively when a
/// pairing file is set up (silent, keeps data on update), otherwise through
/// the system's one-tap prompt.
@MainActor
enum SignedPackageInstaller {
    static func install(_ package: URL, name: String, bundleID: String?, version: String?,
                        installation: InstallationService) async throws -> String {
        var identifier = bundleID ?? ""
        var shortVersion = version ?? ""
        // The one-tap manifest needs both; the package itself is the authority.
        if identifier.isEmpty || shortVersion.isEmpty,
           let info = try? await Task.detached(priority: .userInitiated, operation: {
               try PackageInfoService.read(package)
           }).value {
            if identifier.isEmpty { identifier = info.bundleID }
            if shortVersion.isEmpty { shortVersion = info.version }
        }
        if shortVersion.isEmpty { shortVersion = "1.0" }
        guard !identifier.isEmpty else { throw ToolError.message(AppText.text("安装包信息不完整，无法安装")) }

        if NativeInstaller.hasPairingFile {
            let outcome = try await NativeInstaller.install(package: package, bundleID: identifier) { _ in }
            return outcome.upgraded ? AppText.text("已覆盖安装，原有数据保留。") : AppText.text("安装完成。")
        }
        let job = DownloadJob(app: StoreApp(id: identifier, name: name, bundleID: identifier, version: shortVersion),
                              status: .completed)
        let url = try await installation.automaticInstallURL(job: job, file: package)
        guard await UIApplication.shared.open(url) else { throw ToolError.message(AppText.text("安装失败")) }
        return AppText.text("请在系统弹窗中确认安装，完成前请勿退出 iPadn。")
    }
}
