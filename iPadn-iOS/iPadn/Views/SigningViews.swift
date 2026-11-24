import SwiftUI
import UniformTypeIdentifiers

/// Imported signing certificates: pick the one used after decryption.
struct SigningCertificatesView: View {
    @ObservedObject private var certificates = SigningCertificateStore.shared
    @State private var importing = false

    var body: some View {
        Form {
            if certificates.certificates.isEmpty {
                Section {
                    Text("还没有导入证书").foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(certificates.certificates) { certificate in
                        Button {
                            certificates.selectedID = certificate.id
                        } label: {
                            row(certificate)
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { certificates.certificates[$0].id }
                        for id in ids { certificates.remove(id) }
                    }
                }
            }
            Section {
                Button {
                    importing = true
                } label: {
                    Label("导入证书", systemImage: "plus")
                }
            }
        }
        .toolPage()
        .navigationTitle("签名证书")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $importing) {
            NavigationStack { CertificateImportView() }
        }
    }

    private func row(_ certificate: SigningCertificate) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: certificate.name).foregroundStyle(.primary)
                if !certificate.teamName.isEmpty {
                    Text(verbatim: certificate.teamName).font(.footnote).foregroundStyle(.secondary)
                }
                if let expires = certificate.expires {
                    Text("到期：\(expires.formatted(date: .abbreviated, time: .omitted))")
                        .font(.footnote)
                        .foregroundStyle(expires < Date() ? Color.red : Color.secondary)
                }
                if certificate.debuggable {
                    Text("可调试（JIT）").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if certificate.id == certificates.selectedID {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Picks a .p12, its provisioning profile and the password, then stores them.
struct CertificateImportView: View {
    private enum Slot { case p12, profile }
    private struct Picked { let name: String; let data: Data }

    @Environment(\.dismiss) private var dismiss
    @State private var slot: Slot?
    @State private var picking = false
    @State private var p12: Picked?
    @State private var profile: Picked?
    @State private var password = ""
    @State private var issue: String?

    var body: some View {
        Form {
            Section {
                fileRow("证书文件 (.p12)", name: p12?.name) { slot = .p12; picking = true }
                fileRow("描述文件 (.mobileprovision)", name: profile?.name) { slot = .profile; picking = true }
                SecureField("证书密码", text: $password)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } footer: {
                if let issue {
                    Text(verbatim: issue).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("导入证书")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("导入") { save() }.disabled(p12 == nil || profile == nil)
            }
        }
        // The same copying picker the IPA import uses; .fileImporter left the
        // certificate files unselectable. Several files can be picked at once.
        .sheet(isPresented: $picking) {
            PackageDocumentPicker { result in
                if case .success(let urls) = result { take(urls) }
                picking = false
            }
            .ignoresSafeArea()
        }
    }

    /// Sorts picked files by extension; an unknown one goes to the row that was tapped.
    private func take(_ urls: [URL]) {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer {
                if access { url.stopAccessingSecurityScopedResource() }
                try? FileManager.default.removeItem(at: url)
            }
            guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= 4 * 1024 * 1024 else {
                issue = AppText.text("无法读取文件")
                continue
            }
            let picked = Picked(name: url.deletingPathExtension().lastPathComponent, data: data)
            switch url.pathExtension.lowercased() {
            case "p12", "pfx": p12 = picked
            case "mobileprovision", "provisionprofile": profile = picked
            default:
                if slot == .profile { profile = picked } else { p12 = picked }
            }
            issue = nil
        }
    }

    private func fileRow(_ title: LocalizedStringKey, name: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(verbatim: name ?? AppText.text("选择文件"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func save() {
        guard let p12, let profile else { return }
        do {
            try SigningCertificateStore.shared.importCertificate(
                name: p12.name, p12: p12.data, password: password, profile: profile.data)
            dismiss()
        } catch {
            issue = error.localizedDescription
        }
    }
}
