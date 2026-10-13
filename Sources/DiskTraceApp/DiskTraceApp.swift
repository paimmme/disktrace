import AppKit
import Charts
import DiskTraceCore
import SwiftUI

private enum Palette {
    static let blue = Color(red: 0.12, green: 0.36, blue: 0.72)
    static let orange = Color(red: 0.76, green: 0.31, blue: 0.07)
    static let green = Color(red: 0.12, green: 0.46, blue: 0.37)
    static let surface = Color(nsColor: .controlBackgroundColor)
}

@main
struct DiskTraceApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("DiskTrace") {
            RootView().environmentObject(model).frame(minWidth: 1000, minHeight: 680)
        }
        .defaultSize(width: 1180, height: 820)
        Settings { SettingsView().environmentObject(model) }
    }
}

private enum Page: String, CaseIterable, Identifiable {
    case overview = "空间概览", events = "文件与事件", growth = "目录变化", health = "监控状态"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "chart.xyaxis.line"
        case .events: return "doc.text.magnifyingglass"
        case .growth: return "folder"
        case .health: return "waveform.path.ecg"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "先看空间何时减少，再查增长落在哪里。"
        case .events: return "从时间窗进入具体文件与任务证据，未知保持未知。"
        case .growth: return "按目录查看净变化，区分实测事实与原因线索。"
        case .health: return "查看采样时效、监控范围和数据缺口。"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var page: Page? = .overview
    private var selected: Page { page ?? .overview }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(systemName: "internaldrive").font(.system(size: 25)).foregroundStyle(Palette.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DiskTrace").font(.system(size: 20, weight: .semibold))
                        Text("磁盘变化观察室").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 18).padding(.top, 20)
                List(Page.allCases, selection: $page) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.icon).frame(width: 20)
                        Text(item.rawValue).fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                    }.padding(.vertical, 7).tag(item)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    Label("数据仅保存在本机", systemImage: "lock.shield")
                    Text("记录变化，不自动删除文件。")
                }.font(.caption).foregroundStyle(.secondary).padding(18)
            }.navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    pageHeader
                    if let error = model.errorMessage {
                        Notice(icon: "exclamationmark.triangle", title: "数据读取需要关注", detail: error, color: Palette.orange)
                    }
                    switch selected {
                    case .overview: OverviewView()
                    case .events: EventsView()
                    case .growth: GrowthView()
                    case .health: HealthView()
                    }
                }.padding(30).frame(maxWidth: 1150, alignment: .leading).frame(maxWidth: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Palette.blue)
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refresh() } } label: { Label("刷新数据", systemImage: "arrow.clockwise") }
                    .disabled(model.refreshing).help("重新读取本机数据（⌘R）").keyboardShortcut("r")
            }
            ToolbarItem { SettingsLink { Image(systemName: "gearshape") }.help("设置") }
        }
        .task(id: model.range) {
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
    }
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(selected.rawValue).font(.system(size: 28, weight: .semibold))
                    Text(selected.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                VStack(alignment: .trailing, spacing: 6) {
                    StatusBadge(title: model.errorMessage != nil ? "读取异常" : model.isFresh ? "采样正常" : "等待新采样",
                                color: model.errorMessage != nil ? Palette.orange : model.isFresh ? Palette.green : .secondary)
                    if let date = model.latestSample?.observedAt {
                        Text("最近采样 \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if selected != .health {
                Picker("查看时间", selection: $model.range) {
                    ForEach(HistoryRange.allCases) { range in Text(range.rawValue).tag(range) }
                }.pickerStyle(.segmented).frame(maxWidth: 410)
            }
        }
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let sample = model.latestSample {
                capacity(sample)
                if model.lowSpace {
                    Notice(icon: "externaldrive.badge.exclamationmark", title: "空间偏低，值得先看看增长目录",
                           detail: "当前剩余 \(bytes(sample.freeBytes))。这个提醒只说明空间不足，不能说明是谁写入了文件。", color: Palette.orange)
                }
            } else {
                EmptyState(icon: "internaldrive", title: "等待第一条空间记录", detail: "后台开始采样后，这里会出现剩余空间和变化曲线。")
            }
            SectionPanel(title: "可用空间趋势", subtitle: "曲线下降表示剩余空间减少；这是整个卷的变化。") {
                SpaceChart(samples: model.samples)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("近期提醒").font(.headline)
                    if model.displayAlerts.isEmpty {
                        Text("当前时间范围内没有提醒。没有提醒不代表没有文件变化。").foregroundStyle(.secondary).font(.callout)
                    } else {
                        ForEach(Array(model.displayAlerts.prefix(4))) { alert in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: alert.action == .notifySafetyLowSpace ? "exclamationmark.circle" : "sparkle.magnifyingglass")
                                    .foregroundStyle(alert.action == .notifySafetyLowSpace ? Palette.orange : Palette.blue)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(alert.readableReason).font(.callout.weight(.medium))
                                    Text(alert.action == .notifySafetyLowSpace ? "持续低空间提醒已合并显示" : alert.readableClass)
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(alert.evaluatedAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("这些数据能告诉你什么").font(.headline)
                    Label("何时：可用空间的变化曲线", systemImage: "clock")
                    Label("哪里：已监控目录的净变化", systemImage: "folder")
                    Label("原因：有证据才显示关联", systemImage: "magnifyingglass")
                    Text("当前 Agent 任务关联仍待修复核验。未知来源会保留为未知；这里还不能追溯具体下载文件。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.vertical, 4)
        }
    }
    private func capacity(_ sample: VolumeSample) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 32) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前可用").font(.callout).foregroundStyle(.secondary)
                    Text(bytes(sample.freeBytes)).font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(model.lowSpace ? Palette.orange : Palette.blue)
                }
                Spacer()
                Metric(title: "所选时段内可用空间变化", value: model.spaceChange.map(signedBytes) ?? "记录不足",
                       note: model.samples.count > 1 ? "负数表示空间减少" : "至少需要两次采样")
                Metric(title: "卷总容量", value: bytes(sample.capacityBytes), note: "已用 \(bytes(sample.usedBytes))")
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.blue.opacity(0.14))
                    Capsule().fill(model.lowSpace ? Palette.orange.opacity(0.8) : Palette.blue)
                        .frame(width: geometry.size.width * min(1, max(0, 1 - sample.freeFraction)))
                }
            }.frame(height: 9).accessibilityLabel("已用空间 \(Int((1 - sample.freeFraction) * 100))%")
            HStack {
                Text("已用 \(String(format: "%.1f", (1 - sample.freeFraction) * 100))%")
                Spacer()
                Text("可用 \(String(format: "%.1f", sample.freeFraction * 100))%")
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SpaceChart: View {
    let samples: [VolumeSample]
    private var bounds: ClosedRange<Double> {
        let values = samples.map { Double($0.freeBytes) / 1_000_000_000 }
        let low = values.min() ?? 0, high = values.max() ?? 1
        let padding = max(0.25, (high - low) * 0.2)
        return max(0, low - padding)...(high + padding)
    }
    var body: some View {
        if samples.isEmpty {
            EmptyState(icon: "chart.xyaxis.line", title: "这个时段还没有采样", detail: "选择更长的时间范围，或等待后台记录新的采样。")
        } else {
            Chart(samples) { sample in
                LineMark(x: .value("采样时间", sample.observedAt), y: .value("可用空间", Double(sample.freeBytes) / 1_000_000_000))
                    .foregroundStyle(Palette.blue).lineStyle(StrokeStyle(lineWidth: 2.5))
                if samples.count < 60 {
                    PointMark(x: .value("采样时间", sample.observedAt), y: .value("可用空间", Double(sample.freeBytes) / 1_000_000_000))
                        .foregroundStyle(Palette.blue).symbolSize(18)
                }
            }
            .chartYScale(domain: bounds)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(String(format: "%.1f GB", number)) }
                    }
                }
            }
            .frame(height: 210)
            .accessibilityLabel("可用空间趋势，共 \(samples.count) 次采样")
            HStack {
                Text("\(samples.count) 次采样")
                Spacer()
                Text("纵轴已放大，以便看清小幅变化")
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct GrowthView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var filter = 0
    @State private var selected: GrowthSummary?
    private var rows: [GrowthSummary] {
        model.growth.filter {
            (search.isEmpty || $0.path.localizedCaseInsensitiveContains(search)) &&
            (filter == 0 || (filter == 1 ? $0.netBytes > 0 : $0.netBytes < 0))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                TextField("搜索目录路径", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 350)
                Spacer()
                Picker("变化类型", selection: $filter) {
                    Text("全部变化").tag(0); Text("空间增加占用").tag(1); Text("空间释放").tag(2)
                }.frame(width: 185)
            }
            Text("显示所选时段的目录净变化。父目录包含子目录，数值不可直接相加；正数表示占用增加。")
                .font(.callout).foregroundStyle(.secondary)
            if rows.isEmpty {
                EmptyState(icon: "folder.badge.questionmark", title: search.isEmpty ? "尚无匹配的目录变化" : "没有匹配的目录",
                           detail: "目录约每 15 分钟校准一次。变化只覆盖已监控路径；选择更长时段或清除筛选再查看。")
            } else {
                HStack {
                    Text("目录与最近校准"); Spacer(); Text("时段净变化").frame(width: 130, alignment: .trailing)
                    Text("原因线索").frame(width: 100)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.prefix(200))) { row in
                        Button { selected = row } label: { GrowthRow(row: row) }.buttonStyle(.plain)
                        Divider().padding(.leading, 50)
                    }
                }.background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 10))
                Text(rows.count > 200 ? "共 \(rows.count) 个目录，显示净变化最大的 200 个。可搜索具体路径。" : "共 \(rows.count) 个目录。点击一行查看路径、测量窗口与证据。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $selected) { row in GrowthDetail(summary: row).environmentObject(model) }
    }
}

private struct GrowthRow: View {
    let row: GrowthSummary
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").font(.title3).foregroundStyle(Palette.blue.opacity(0.7)).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(row.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(shortPath(row.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("最近校准 \(row.latest.windowEnd.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(signedBytes(row.netBytes)).font(.callout.weight(.semibold)).monospacedDigit()
                .foregroundStyle(row.netBytes > 0 ? Palette.orange : Palette.green).frame(width: 130, alignment: .trailing)
            Text(row.decision?.readableClass ?? "尚未评估").font(.caption).foregroundStyle(.secondary).frame(width: 100)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.padding(16).contentShape(Rectangle()).help(row.path)
    }
}

private struct GrowthDetail: View {
    let summary: GrowthSummary
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var evidence: [Evidence] = []
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(summary.name, systemImage: "folder").font(.title2.weight(.semibold))
                Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(summary.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 40) {
                Metric(title: "所选时段净变化", value: signedBytes(summary.netBytes), note: "\(summary.windows) 个测量窗口")
                Metric(title: "最近记录的目录占用", value: bytes(summary.latest.afterAllocatedBytes), note: "目录及其子目录的分配空间")
            }
            Divider()
            Text("为什么发生变化").font(.headline)
            Text(summary.decision?.readableReason ?? "这个目录尚无原因判定。记录了变化，不等于已经找到写入者。")
                .font(.callout)
            if let decision = summary.decision {
                Text("以下判定对应 \(decision.evaluatedAt.formatted(date: .abbreviated, time: .shortened)) 的单次窗口，不代表整个时段的全部变化。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if evidence.isEmpty {
                Text("当前没有可展示的归因证据。需要更多路径、任务或进程线索。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(evidence.prefix(6)) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(evidenceTitle(item)).font(.callout.weight(.medium))
                        Text(item.observedAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        Text(evidenceExplanation(item)).font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("查看原始证据说明") {
                            Text(item.limitation).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }.font(.caption)
                    }
                }
            }
            Notice(icon: "info.circle", title: "关联线索需要核验", detail: "当前版本的 Agent 任务关联仍有已知缺陷。时间或工作目录重合不能证明某个文件由 Agent 下载；暂不展示未经验证的任务名称或进程。", color: Palette.blue)
            HStack {
                Button("在 Finder 中查看", systemImage: "arrow.up.forward.square") { model.reveal(summary.path) }
                Button("复制路径", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(summary.path, forType: .string)
                }
                Spacer()
            }
        }.padding(28)
        }.frame(width: 680, height: 620)
        .task { evidence = await model.evidence(for: summary) }
    }
    private func evidenceTitle(_ evidence: Evidence) -> String {
        switch evidence.source {
        case .agentTaskEvent: return evidence.scope == .timeWindowOnly ? "Agent 活动在时间上重合" : "Agent 工作目录存在关联线索"
        case .processOperation: return "进程操作记录"
        case .userFeedback: return "用户反馈"
        case .pathRule: return "路径规则"
        case .directoryNameHint: return "目录名称线索"
        case .cacheDirectoryHint: return "缓存目录线索"
        case .finderOrBrowserHint: return "Finder 或浏览器活动线索"
        }
    }
    private func evidenceExplanation(_ evidence: Evidence) -> String {
        switch evidence.source {
        case .agentTaskEvent:
            return evidence.scope == .timeWindowOnly
                ? "仅活动时间重合，没有证据证明这个目录由 Agent 写入。"
                : "会话时间和工作目录重合，但未观测到进程对具体文件的写入。"
        case .directoryNameHint, .cacheDirectoryHint:
            return "目录名称或缓存位置只是线索，不能证明文件由谁创建。"
        default: return evidence.limitation
        }
    }
}

private struct HealthView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionPanel(title: "数据是否仍在更新", subtitle: "以最新容量采样判断时效，不把数据库存在当成后台正常。") {
                LabeledContent("容量采样", value: model.isFresh ? "最近 3 分钟有新记录" : "最近 3 分钟没有新记录，请检查后台")
                LabeledContent("界面刷新", value: "每 15 秒读取；⌘R 可手动刷新")
                LabeledContent("历史数据占用", value: bytes(model.databaseBytes))
                LabeledContent("已保存的 Agent 活动记录", value: "\(model.activityCount) 条（关联准确性待核验）")
                LabeledContent("本时段的覆盖缺口", value: "\(model.gaps.count) 条")
            }
            SectionPanel(title: "本机配置的监控目录", subtitle: "卷级曲线反映整体空间；目录变化只覆盖下面的路径。配置范围不等于每个目录都成功扫描。") {
                if model.roots.isEmpty {
                    Text("该数据库没有可读取的本机范围配置，不能确认监控目录。").foregroundStyle(.secondary)
                } else {
                    ForEach(model.roots, id: \.self) { path in
                        HStack {
                            Label(shortPath(path), systemImage: "folder").textSelection(.enabled)
                            Spacer()
                            Button("Finder") { model.reveal(path) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            SectionPanel(title: "覆盖与权限缺口", subtitle: "记录不完整的时段不能当作可靠测量；这里只展示数据库中已记录的缺口。") {
                if model.gaps.isEmpty {
                    Text("所选时段没有已记录的缺口。尚未证明全盘覆盖，也不代表所有异常都已被检测。").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.gaps.prefix(20))) { gap in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(gap.cause.readable, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.orange)
                            Text(gap.start, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            Text(gap.affectedRoots.map(shortPath).joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Divider()
                    }
                }
            }
            Notice(icon: "bell.slash", title: "当前提醒仅保存在应用内", detail: "系统通知、登录自动启动、具体文件追溯和可靠任务关联尚未完成。关闭主窗口不停止已启动的本地后台；退出登录后需重新启动。", color: Palette.blue)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Form {
            Section("历史数据位置") {
                TextField("数据库路径", text: $model.databasePath)
                Button("读取此数据库") { Task { await model.refresh() } }
                Text("界面只读取历史，不修改或清理数据库。修改路径不会改变后台监控的写入位置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("刷新与监控") {
                Text("界面每 15 秒刷新；本机后台约每 60 秒采样、每 15 分钟校准目录。")
                Text("监控范围和采样间隔目前由本地启动配置管理，尚不能在界面中修改。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding().frame(width: 580, height: 340)
    }
}

private struct SectionPanel<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct Metric: View {
    let title: String, value: String, note: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct StatusBadge: View {
    let title: String
    let color: Color
    var body: some View {
        HStack(spacing: 6) { Circle().fill(color).frame(width: 6, height: 6); Text(title) }
            .font(.caption.weight(.medium)).foregroundStyle(color).padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.1)).clipShape(Capsule())
    }
}

private struct Notice: View {
    let icon: String, title: String, detail: String
    let color: Color
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct EmptyState: View {
    let icon: String, title: String, detail: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }.frame(maxWidth: .infinity).padding(.vertical, 32)
    }
}
