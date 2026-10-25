import AppKit
import DiskTraceCore
import SwiftUI

/// In-app editor for `local-run.json` roots (no manual JSON editing).
struct MonitorRootsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: Set<String> = []
    @State private var message: String?

    private var allPaths: [String] {
        let suggested = model.rootSuggestions.map(\.url.path)
        return Array(Set(model.roots + suggested + Array(selection))).sorted()
    }

    var body: some View {
        Section("监控目录") {
            Text("勾选要监控的路径。保存后后台会重启文件监听并开始新基线扫描。")
                .font(.caption).foregroundStyle(.secondary)
            if model.databasePath != AppModel.defaultDatabasePath() {
                Text("当前打开的不是本机默认数据库，无法从这里修改监控范围。")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                ForEach(model.rootSuggestions, id: \.url.path) { item in
                    rootToggle(
                        path: item.url.path,
                        subtitle: item.label)
                }
                if !model.roots.filter({ r in !model.rootSuggestions.contains(where: { $0.url.path == r }) }).isEmpty {
                    Text("已在配置中的其它目录").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.roots.filter { r in !model.rootSuggestions.contains(where: { $0.url.path == r }) }, id: \.self) { path in
                        rootToggle(path: path, subtitle: nil)
                    }
                }
                ForEach(extraOnlyPaths, id: \.self) { path in
                    rootToggle(path: path, subtitle: "自定义")
                }
                HStack {
                    Button("添加文件夹…", systemImage: "folder.badge.plus") { pickFolder() }
                    Spacer()
                    Button("保存并应用") { Task { await apply() } }
                        .disabled(model.controlPending || selection.isEmpty)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onAppear {
            selection = Set(model.roots)
            model.refreshRootSuggestions()
        }
        .onChange(of: model.roots) { _, roots in
            if selection.isEmpty { selection = Set(roots) }
        }
    }

    private var extraOnlyPaths: [String] {
        Array(selection.filter { s in
            !model.roots.contains(s) && !model.rootSuggestions.contains(where: { $0.url.path == s })
        }).sorted()
    }

    private func rootToggle(path: String, subtitle: String?) -> some View {
        Toggle(isOn: binding(for: path)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shortPath(path)).font(.callout)
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(path) },
            set: { on in
                if on { selection.insert(path) } else { selection.remove(path) }
            })
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择要监控的文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            selection.insert(FilePaths.canonical(url.path))
        }
    }

    private func apply() async {
        guard !selection.isEmpty else { return }
        message = nil
        await model.applyMonitorRoots(Array(selection).sorted())
        message = model.controlMessage
    }
}
