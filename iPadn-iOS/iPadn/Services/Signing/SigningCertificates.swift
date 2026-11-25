import Foundation
import Security

/// A signing identity the user imported: a .p12, its password and the
/// provisioning profile that goes with it. Used to re-sign decrypted apps so
/// they can be installed straight from iPadn.
struct SigningCertificate: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// The .p12 file name, e.g. "Distribution".
    var name: String
    var teamName: String
    var teamID: String
    var expires: Date?
    /// `get-task-allow`: debuggable builds, needed for JIT; iOS asks for Developer Mode.
    var debuggable: Bool
    var devices: Int
    var imported: Date
    /// App groups the certificate grants; GroupFix maps an app's own groups to
    /// the first of these. Optional for certificates imported before this field.
    var appGroups: [String] = []
}

/// What a provisioning profile says about itself, read from its embedded plist.
struct ProvisioningProfileInfo: Sendable {
    var name: String
    var teamName: String
    var teamID: String
    var expires: Date?
    var debuggable: Bool
    var devices: Int
    var appGroups: [String]

    static func parse(_ data: Data) throws -> ProvisioningProfileInfo {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
            throw ToolError.message(AppText.text("描述文件无效"))
        }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let value = try? PropertyListSerialization.propertyList(from: xml, format: nil),
              let plist = value as? [String: Any] else {
            throw ToolError.message(AppText.text("描述文件无效"))
        }
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        return ProvisioningProfileInfo(
            name: plist["Name"] as? String ?? "",
            teamName: plist["TeamName"] as? String ?? "",
            teamID: (plist["TeamIdentifier"] as? [String])?.first ?? "",
            expires: plist["ExpirationDate"] as? Date,
            debuggable: entitlements["get-task-allow"] as? Bool ?? false,
            devices: (plist["ProvisionedDevices"] as? [String])?.count ?? 0,
            appGroups: entitlements["com.apple.security.application-groups"] as? [String] ?? []
        )
    }
}

/// Files and keychain access for imported certificates. Not actor-bound: the
/// decryptor reads the selected certificate from a background queue.
enum SigningFiles {
    static let enabledKey = "signing.afterDecrypt"
    static let selectedKey = "signing.certificate"
    static let fixGroupsKey = "signing.fixAppGroups"

    struct Material: Sendable {
        let certificate: SigningCertificate
        let p12: URL
        let profile: URL
        let password: String
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SigningCertificates", isDirectory: true)
    }

    static var indexURL: URL { directory.appendingPathComponent("index.json") }

    static func folder(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func loadIndex() -> [SigningCertificate] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([SigningCertificate].self, from: data)) ?? []
    }

    static func saveIndex(_ certificates: [SigningCertificate]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        try JSONEncoder().encode(certificates).write(to: indexURL, options: .atomic)
    }

    /// The certificate to sign with when "sign after decrypting" is on, or nil.
    static func materialIfEnabled() -> Material? {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return nil }
        return selectedMaterial()
    }

    static func selectedMaterial() -> Material? {
        material(for: UserDefaults.standard.string(forKey: selectedKey).flatMap(UUID.init(uuidString:)))
    }

    /// A specific certificate, falling back to the selected one (or the first)
    /// when it was removed. Used by patched-app updates, which re-sign with the
    /// certificate the app was installed with so the update keeps its data.
    static func material(for id: UUID?) -> Material? {
        let all = loadIndex()
        let selected = UserDefaults.standard.string(forKey: selectedKey).flatMap(UUID.init(uuidString:))
        guard let certificate = all.first(where: { $0.id == id }) ?? all.first(where: { $0.id == selected }) ?? all.first,
              let password = loadPassword(for: certificate.id) else { return nil }
        let base = folder(for: certificate.id)
        return Material(certificate: certificate,
                        p12: base.appendingPathComponent("certificate.p12"),
                        profile: base.appendingPathComponent("profile.mobileprovision"),
                        password: password)
    }

    // MARK: keychain (password only, this device only)

    private static func passwordQuery(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "iPadn") + ".signing",
         kSecAttrAccount as String: id.uuidString]
    }

    static func savePassword(_ password: String, for id: UUID) throws {
        SecItemDelete(passwordQuery(id) as CFDictionary)
        var item = passwordQuery(id)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw ToolError.message(AppText.text("无法保存证书密码"))
        }
    }

    static func loadPassword(for id: UUID) -> String? {
        var query = passwordQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(for id: UUID) {
        SecItemDelete(passwordQuery(id) as CFDictionary)
    }

    /// Rejects a wrong password up front. Other import errors are not fatal:
    /// some valid .p12 encodings are unreadable to Security but fine for OpenSSL.
    static func checkPassword(p12: Data, password: String) throws {
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData,
                                     [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        if status == errSecAuthFailed {
            throw ToolError.message(AppText.text("证书密码不正确"))
        }
    }
}

@MainActor
final class SigningCertificateStore: ObservableObject {
    static let shared = SigningCertificateStore()

    @Published private(set) var certificates: [SigningCertificate]
    @Published var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: SigningFiles.selectedKey) }
    }

    init() {
        let all = SigningFiles.loadIndex()
        certificates = all
        let saved = UserDefaults.standard.string(forKey: SigningFiles.selectedKey).flatMap(UUID.init(uuidString:))
        selectedID = all.contains { $0.id == saved } ? saved : all.first?.id
    }

    var selected: SigningCertificate? { certificates.first { $0.id == selectedID } }

    @discardableResult
    func importCertificate(name: String, p12: Data, password: String, profile: Data) throws -> SigningCertificate {
        let info = try ProvisioningProfileInfo.parse(profile)
        try SigningFiles.checkPassword(p12: p12, password: password)
        let id = UUID()
        let folder = SigningFiles.folder(for: id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try p12.write(to: folder.appendingPathComponent("certificate.p12"),
                          options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try profile.write(to: folder.appendingPathComponent("profile.mobileprovision"), options: .atomic)
            try SigningFiles.savePassword(password, for: id)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        let certificate = SigningCertificate(
            id: id, name: name.isEmpty ? info.name : name, teamName: info.teamName, teamID: info.teamID,
            expires: info.expires, debuggable: info.debuggable, devices: info.devices,
            imported: Date(), appGroups: info.appGroups)
        certificates.append(certificate)
        try SigningFiles.saveIndex(certificates)
        if selectedID == nil { selectedID = id }
        return certificate
    }

    func remove(_ id: UUID) {
        certificates.removeAll { $0.id == id }
        try? SigningFiles.saveIndex(certificates)
        try? FileManager.default.removeItem(at: SigningFiles.folder(for: id))
        SigningFiles.deletePassword(for: id)
        if selectedID == id { selectedID = certificates.first?.id }
    }
}
