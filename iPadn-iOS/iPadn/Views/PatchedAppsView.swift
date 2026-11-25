import SwiftUI

/// Apps iPadn patched and re-signed: their update state, "update all", and
/// the automatic-update settings.
struct PatchedAppsView: View {
    @ObservedObject private var apps = PatchedAppStore.shared
    @ObservedObject private var updater = PatchedAppUpdater.shared
    @AppStorage(PatchedAppUpdater.autoKey) private var autoUpdate = false
    @AppStorage(PatchedAppUpdater.vpnKey) private var toggleVPN = true

    private var sorted: [PatchedApp] {
        apps.apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                if updater.running {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(verbatim: updater.status ?? "").foregroundStyle(.secondary)
                    }
                    Button("停止", role: .destructive) { updater.cancel() }
                } else {
                    Button {
                        updater.updateAll()
                    } label: {
                        Label("全部更新", systemImage: "arrow.down.app")
                    }
                    .disabled(apps.apps.isEmpty)
                    Button {
                        Task { await updater.check() }
                    } label: {
                        HStack {
                            Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                            if updater.checking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(apps.apps.isEmpty || updater.checking)
                }
            } footer: {
                if let checked = updater.lastChecked {
                    Text("上次检查：\(checked.formatted(date: .abbreviated, time: .shortened))")
                }
            }

            if apps.apps.isEmpty {
                Section {
                    Text("还没有已修改的应用。开启「解密后签名」后，解密成功的应用会自动出现在这里。")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(sorted) { app in
                        NavigationLink {
                            PatchedAppDetailView(bundleID: app.bundleID)
                        } label: {
                            row(app)
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { sorted[$0].bundleID }
                        for id in ids { apps.remove(id) }
                    }
                } header: {
                    Text("已修改的应用")
                } footer: {
                    Text("左滑可停止跟踪；应用本身不会被删除。")
                }
            }

            Section {
                Toggle("打开 iPadn 时自动更新", isOn: $autoUpdate)
                Toggle("自动开关 LocalDevVPN", isOn: $toggleVPN)
            } footer: {
                Text("自动更新最多每 6 小时检查一次。有新版本时会下载、解密、提升 SDK，并用原来的证书签名，再直接原生安装、保留数据：需要时先打开 LocalDevVPN 连接，装完再断开。未完成原生安装配对时，更新会准备好，等你点按安装。也可以在快捷指令中使用「更新已修改的应用」。")
            }
        }
        .toolPage()
        .navigationTitle("已修改的应用")
        .navigationBarTitleDisplayMode(.inline)
        .task { await apps.prepare() }
    }

    private func row(_ app: PatchedApp) -> some View {
        let subtitle: String
        if let latest = updater.listings[app.bundleID] {
            subtitle = AppText.text("已修改 \(app.version)，商店最新 \(latest.version)")
        } else if let ready = app.readyVersion {
            subtitle = AppText.text("\(ready) 已准备好，待安装")
        } else if app.storeID == nil {
            subtitle = AppText.text("没有 App Store ID，无法检查更新")
        } else {
            subtitle = AppText.text("已修改 \(app.version)")
        }
        let shown = StoreApp(id: app.storeID ?? app.bundleID, name: app.name, bundleID: app.bundleID,
                             version: app.version, iconURL: app.iconURL)
        return VStack(alignment: .leading, spacing: 4) {
            AppRow(app: shown, subtitle: subtitle)
            if let error = app.lastError {
                Text(verbatim: error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            if !app.autoUpdate {
                Text("不参与全部更新").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One patched app: install a prepared update and the settings its updates use.
struct PatchedAppDetailView: View {
    let bundleID: String
    @ObservedObject private var apps = PatchedAppStore.shared
    @ObservedObject private var updater = PatchedAppUpdater.shared
    @ObservedObject private var certificates = SigningCertificateStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var installing = false
    @State private var installMessage: String?

    var body: some View {
        Form {
            if let app = apps.app(bundleID) {
                content(app)
            }
        }
        .toolPage()
        .navigationTitle(apps.app(bundleID)?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func content(_ app: PatchedApp) -> some View {
        Section {
            LabeledContent("Bundle ID") { Text(verbatim: app.bundleID).foregroundStyle(.secondary) }
            LabeledContent("已修改版本") { Text(verbatim: app.version.isEmpty ? "-" : app.version).foregroundStyle(.secondary) }
            if let latest = updater.listings[app.bundleID] {
                LabeledContent("商店最新") { Text(verbatim: latest.version).foregroundStyle(.secondary) }
            }
            if let error = app.lastError {
                Text(verbatim: error).font(.footnote).foregroundStyle(.red)
            }
        }

        if let ready = app.readyVersion, app.readyRecordID != nil {
            Section {
                Button {
                    install()
                } label: {
                    HStack {
                        Label(AppText.text("安装 \(ready)"), systemImage: "arrow.down.app")
                        if installing { Spacer(); ProgressView() }
                    }
                }
                .disabled(installing || updater.running)
            } footer: {
                if let installMessage { Text(verbatim: installMessage) }
            }
        }

        Section {
            Toggle("参与全部更新", isOn: binding(\.autoUpdate, app))
            Toggle("提升 SDK 版本", isOn: Binding(
                get: { apps.app(bundleID)?.sdkTarget != nil },
                set: { on in apps.update(bundleID) { $0.sdkTarget = on ? SDKVersionPatcher.defaultTarget : nil } }))
            if let target = app.sdkTarget {
                LabeledContent("目标 SDK") {
                    TextField(text: Binding(
                        get: { apps.app(bundleID)?.sdkTarget ?? target },
                        set: { text in apps.update(bundleID) { $0.sdkTarget = text } }),
                              prompt: Text(verbatim: SDKVersionPatcher.defaultTarget)) {
                        Text("目标 SDK")
                    }
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                }
                if SDKVersionPatcher.encode(target) == nil {
                    Text("版本号无效").font(.footnote).foregroundStyle(.red)
                }
            }
            Picker("签名证书", selection: binding(\.certificateID, app)) {
                ForEach(certificates.certificates) { certificate in
                    Text(verbatim: certificate.name).tag(Optional(certificate.id))
                }
            }
            Toggle("修复 App Group", isOn: binding(\.fixAppGroups, app))
        } header: {
            Text("更新时使用")
        } footer: {
            Text("这些设置只用于这个应用的更新，与「处理选项」无关。换用其他证书签名会被系统当作不同的开发者，可能丢失应用数据。")
        }

        Section {
            Button("停止跟踪", role: .destructive) {
                apps.remove(bundleID)
                dismiss()
            }
        }
    }

    /// Reads the live entry; falls back to `app` while the page closes after "stop tracking".
    private func binding<Value>(_ keyPath: WritableKeyPath<PatchedApp, Value>, _ app: PatchedApp) -> Binding<Value> {
        Binding(
            get: { (apps.app(bundleID) ?? app)[keyPath: keyPath] },
            set: { value in apps.update(bundleID) { $0[keyPath: keyPath] = value } })
    }

    private func install() {
        installing = true
        installMessage = nil
        Task {
            defer { installing = false }
            do {
                installMessage = try await updater.installReady(bundleID)
            } catch {
                installMessage = error.localizedDescription
            }
        }
    }
}
