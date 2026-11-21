import Foundation
import UIKit
import Zsign

/// Re-signs an unpacked .app folder with an imported certificate (zsign, MIT).
/// The bundle ID is kept, so a later update signed with the same certificate
/// replaces the app and keeps its data.
enum AppSigner {
    /// Blocking; call from a background queue. Signs nested frameworks and
    /// extensions too, and embeds the certificate's provisioning profile.
    static func sign(appDir: URL, with material: SigningFiles.Material, log: (String) -> Void) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: material.p12.path), manager.fileExists(atPath: material.profile.path) else {
            throw ToolError.message(AppText.text("还没有可用的签名证书"))
        }
        // FairPlay leftovers only mean something next to Apple's own signature.
        var removed = 0
        if let walker = manager.enumerator(at: appDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in walker where url.lastPathComponent == "SC_Info" {
                if (try? manager.removeItem(at: url)) != nil { removed += 1 }
                walker.skipDescendants()
            }
        }
        if removed > 0 { log("removed \(removed) SC_Info folder(s)") }

        let ok = Zsign.sign(appPath: appDir.path,
                            provisionPath: material.profile.path,
                            p12Path: material.p12.path,
                            p12Password: material.password)
        guard ok else { throw ToolError.message(AppText.text("签名失败")) }
        log("signed with \(material.certificate.name) (\(material.certificate.teamID))")
    }
}

/// Installs a package that is already signed for this device: natively when a
/// pairing file is set up (silent, keeps data on update), otherwise through
/// the system's one-tap prompt.
@MainActor
enum SignedPackageInstaller {
    static func install(_ package: URL, name: String, bundleID: String?,
                        installation: InstallationService) async throws -> String {
        var identifier = bundleID ?? ""
        if identifier.isEmpty {
            identifier = try await Task.detached(priority: .userInitiated) {
                try PackageInfoService.read(package).bundleID
            }.value
        }
        guard !identifier.isEmpty else { throw ToolError.message(AppText.text("安装失败")) }

        if NativeInstaller.hasPairingFile {
            let outcome = try await NativeInstaller.install(package: package, bundleID: identifier) { _ in }
            return outcome.upgraded ? AppText.text("已覆盖安装，原有数据保留。") : AppText.text("安装完成。")
        }
        let job = DownloadJob(app: StoreApp(id: identifier, name: name, bundleID: identifier, version: ""),
                              status: .completed)
        let url = try await installation.automaticInstallURL(job: job, file: package)
        guard await UIApplication.shared.open(url) else { throw ToolError.message(AppText.text("安装失败")) }
        return AppText.text("请在系统弹窗中确认安装，完成前请勿退出 iPadn。")
    }
}
