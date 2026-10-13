import DiskTraceCore
import SwiftUI

/// The user-facing closed loop: time windows → concrete files → task evidence
/// and limits → Finder. Read-only; no delete actions.
struct EventsView: View {
    @EnvironmentObject private var model: AppModel

    private var events: [StorageEvent] { model.events }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if events.isEmpty {
                emptyState
            } else {
                eventList
                if model.hasMoreEvents { Button("加载更多事件") { Task { await model.loadMoreEvents() } } }
                if let id = model.selectedEventID, let event = events.first(where: { $0.id == id }) {
                    Divider()
                    EventDetail(event: event)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("暂无已记录事件", systemImage: "tray").font(.headline)
            Text("在所选时段内，监控范围还没有形成可展示的净变化事件；或数据库仍是旧版本（等待后台升级）。")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var eventList: some View {
        VStack(spacing: 0) {
            ForEach(events) { event in
                Button {
                    Task { await model.selectEvent(event.id) }
                } label: {
                    EventRow(event: event, selected: model.selectedEventID == event.id)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EventRow: View {
    let event: StorageEvent
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shortPath(event.scopePath)).font(.body.weight(.medium)).lineLimit(2)
                Text("\(event.windowStart.formatted(date: .abbreviated, time: .shortened)) · \(categoryText(event.reasonCategory))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text(event.netBytes.map(signedBytes) ?? "未知")
                    .font(.body.monospacedDigit())
                    .foregroundStyle((event.netBytes ?? 0) >= 0 ? Color.orange : Color.green)
                HStack(spacing: 6) {
                    tag(attributionText(event.attributionClass), color: attributionColor(event.attributionClass))
                    tag(measurementText(event.measurement), color: .secondary)
                }
            }
        }
        .padding(14)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear)
        .contentShape(Rectangle())
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}

private struct EventDetail: View {
    @EnvironmentObject private var model: AppModel
    let event: StorageEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if model.eventFiles.isEmpty {
                Text("没有保留的文件明细（可能已过保留期）。").font(.callout).foregroundStyle(.secondary)
            } else {
                fileTable
            }
            if !model.eventLinks.isEmpty {
                Divider()
                candidateList
            }
            if event.unassignedBytes != nil {
                Label("其中 \(bytes(abs(event.unassignedBytes ?? 0))) 尚未找到任务候选；这不等于卷级未知空间。", systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shortPath(event.scopePath)).font(.headline)
            HStack(spacing: 16) {
                metric("已测净变化", event.netBytes.map(signedBytes) ?? "未知")
                metric("新增", event.grossAddedBytes.map(signedBytes) ?? "未知")
                metric("释放", event.grossRemovedBytes.map(signedBytes) ?? "未知")
                metric("候选任务", "\(event.candidateCount)")
            }
            Text("时间窗 \(event.windowStart.formatted(date: .abbreviated, time: .shortened)) – \(event.windowEnd.formatted(date: .abbreviated, time: .shortened)) · 测量 \(measurementText(event.measurement))")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    model.reveal(event.scopePath)
                } label: { Label("在 Finder 中定位", systemImage: "folder") }
                Button {
                    model.confirmEvent(event.id)
                } label: { Label("这是我主动操作", systemImage: "hand.raised") }
                .disabled(model.controlPending)
                .help("仅确认这个事件；后台回执后生效，不删除文件。")
                if event.attributionClass == .userConfirmed {
                    Button("撤销确认") { Task { await model.sendControl(.revokeUser, eventID: event.id) } }.disabled(model.controlPending)
                }
            }
            if let message = model.controlMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }

    private var fileTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("具体文件（\(model.eventFiles.count)）").font(.subheadline.weight(.semibold))
            ForEach(model.eventFiles) { change in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shortPath(change.displayPath)).font(.callout).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 8) {
                            Text(changeKindText(change.kind)).font(.caption2).foregroundStyle(.secondary)
                            Text(timingText(change.timing)).font(.caption2).foregroundStyle(.secondary)
                            if let presence = model.presence(for: change.id) {
                                Text(presenceText(presence)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 10)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(change.deltaAllocated.map(signedBytes) ?? "未知").font(.callout.monospacedDigit())
                        Text("前 \(change.beforeAllocated.map(bytes) ?? "未知") → 后 \(change.afterAllocated.map(bytes) ?? "未知")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Button { model.reveal(change.displayPath) } label: { Image(systemName: "arrow.right.circle") }
                        .buttonStyle(.borderless)
                }
                .padding(.vertical, 3)
                Divider()
            }
            if model.hasMoreFiles { Button("加载更多文件") { Task { await model.loadMoreFiles() } } }
        }
    }

    private var candidateList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("任务候选").font(.subheadline.weight(.semibold))
            Text("窗口关联不是写入证明：即使是“可能相关”，也只能说该时段相关目录净增，不能断言是哪次任务写入。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.eventLinks, id: \.id) { link in
                HStack(alignment: .top, spacing: 10) {
                    Text(linkStateText(link.state)).font(.caption).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(link.basis).font(.callout)
                        Text(link.limitation).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Text helpers

private func categoryText(_ c: ReasonCategory) -> String {
    switch c {
    case .dependencies: return "依赖目录"
    case .buildOutputs: return "构建产物"
    case .modelCache: return "模型缓存"
    case .sessionArtifacts: return "会话产物"
    case .temporaryFiles: return "临时文件"
    case .downloadsFolder: return "下载目录"
    case .mixed: return "多类目录"
    case .unknown: return "类型未知"
    }
}
private func attributionText(_ c: EventAttributionClass) -> String {
    switch c {
    case .unknown: return "来源未知"
    case .userConfirmed: return "你已确认"
    case .agentProbable: return "可能相关"
    case .agentConfirmed: return "已确认"
    }
}
private func attributionColor(_ c: EventAttributionClass) -> Color {
    switch c {
    case .agentProbable, .agentConfirmed: return .orange
    case .userConfirmed: return .green
    case .unknown: return .secondary
    }
}
private func measurementText(_ m: MeasurementState) -> String {
    switch m {
    case .measured: return "测量完整"
    case .beforeUnknown: return "前值未知"
    case .coverageGap: return "存在缺口"
    case .unstable: return "写入中"
    case .quotaLimited: return "受配额限制"
    }
}
private func changeKindText(_ k: FileChangeKind) -> String {
    switch k {
    case .added: return "新增"
    case .grown: return "变大"
    case .shrunk: return "变小"
    case .removed: return "删除"
    case .moved: return "移动"
    case .replaced: return "替换"
    case .metadataOnly: return "仅元数据"
    case .firstObserved: return "首次观测"
    }
}
private func timingText(_ t: TimingPrecision) -> String {
    switch t {
    case .liveHintWindow: return "事件线索窗"
    case .scanWindow: return "扫描窗"
    case .recoveryWindow: return "恢复窗"
    }
}
private func linkStateText(_ s: TaskLinkState) -> String {
    switch s {
    case .timeOnly: return "仅时间"
    case .pathCandidate: return "路径候选"
    case .ambiguous: return "存在歧义"
    case .userConfirmed: return "已确认"
    case .verifiedWriter: return "已验证写入者"
    }
}
private func presenceText(_ check: PresenceCheck) -> String {
    switch check.result {
    case .present: return "任务后仍存在"
    case .replaced: return "路径仍在，文件已被替换"
    case .missing: return "此路径已不存在"
    case .unknown: return "尚不能确认"
    }
}
