import Charts
import DiskTraceCore
import SwiftUI

struct SectionPanel<Content: View>: View {
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
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 概览：时段故事 + 条形图

struct IntervalVisualSummary {
    let headline: String
    let subline: String
    let explained: Int64
    let barRows: [PurposeBarRow]
}

struct PurposeBarRow: Identifiable {
    let id: String
    let title: String
    let netBytes: Int64
    let color: Color
    let icon: String
}

enum IntervalVisualBuilder {
    static func build(report: IntervalExplanationReport) -> IntervalVisualSummary {
        let rows = report.purposeGroups.compactMap { group -> PurposeBarRow? in
            guard let net = group.netBytes, net != 0 else { return nil }
            let style = purposeStyle(group.purpose)
            return PurposeBarRow(
                id: group.purpose.rawValue, title: shortPurposeTitle(group.purpose),
                netBytes: net, color: style.color, icon: style.icon)
        }.sorted { abs($0.netBytes) > abs($1.netBytes) }
        let explained = rows.reduce(Int64(0)) { $0 + $1.netBytes }
        let (headline, subline) = story(report: report, explained: explained, rows: rows)
        return IntervalVisualSummary(headline: headline, subline: subline, explained: explained, barRows: rows)
    }

    private static func story(
        report: IntervalExplanationReport, explained: Int64, rows: [PurposeBarRow]
    ) -> (String, String) {
        if let delta = report.volume.freeDelta, report.volume.methodComparable {
            let lost = -delta
            if lost > 0 {
                let top = rows.first
                let topPart = top.map { "其中已监控路径约 \(signedBytes($0.netBytes)) 落在「\( $0.title)」。" } ?? ""
                return (
                    "这个时段磁盘可用空间大约少了 \(bytes(lost))。",
                    topPart + (report.uncoveredBytes.map { " 另有约 \(bytes(max(0, $0))) 无法单靠监控路径解释（未扫到的目录、swap、系统缓存等）。" } ?? report.volume.methodNote))
            }
            if lost < 0 {
                return ("这个时段可用空间增加了 \(bytes(-lost))。", report.volume.methodNote)
            }
        }
        if rows.isEmpty {
            return ("这个时段还没有足够的文件级记录。", "卷曲线可能有变化，但监控目录内尚未形成可汇总的文件差分。")
        }
        return ("监控目录内有文件变化，但卷级采样暂时无法精确对齐。", report.volume.methodNote)
    }

    private static func shortPurposeTitle(_ p: SoftwarePurpose) -> String {
        switch p {
        case .codexAutoUpdate: return "Codex 更新缓存"
        case .codexSessionData: return "Codex 会话"
        case .harnessAutoUpdate: return "Harness 更新"
        case .claudeCache: return "Claude 缓存"
        case .systemSwap: return "系统 Swap"
        case .monitoredOther: return "其他监控路径"
        case .uncoveredVolume: return "未解释"
        }
    }

    static func purposeStyle(_ p: SoftwarePurpose) -> (color: Color, icon: String) {
        switch p {
        case .codexAutoUpdate: return (Color(red: 0.85, green: 0.45, blue: 0.12), "arrow.down.circle")
        case .codexSessionData: return (Color(red: 0.12, green: 0.36, blue: 0.72), "bubble.left.and.bubble.right")
        case .harnessAutoUpdate: return (.purple, "shippingbox")
        case .claudeCache: return (.teal, "sparkles")
        case .systemSwap: return (.gray, "memorychip")
        case .monitoredOther: return (.secondary, "folder")
        case .uncoveredVolume: return (.orange, "questionmark.folder")
        }
    }
}

struct IntervalStoryHeader: View {
    let summary: IntervalVisualSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.headline).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(summary.subline).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SummaryMetricTile: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PurposeBreakdownChart: View {
    let rows: [PurposeBarRow]
    private var scaleMax: Double {
        max(rows.map { abs(Double($0.netBytes)) }.max() ?? 1, 1)
    }
    var body: some View {
        if rows.isEmpty {
            Label("暂无足够数据画分布图", systemImage: "chart.bar.xaxis")
                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
        } else {
            Chart(rows) { row in
                BarMark(
                    x: .value("变化量", Double(row.netBytes) / 1_000_000),
                    y: .value("类别", row.title)
                )
                .foregroundStyle(row.color.gradient)
                .annotation(position: .trailing, alignment: .center) {
                    Text(signedBytes(row.netBytes)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .chartXScale(domain: -scaleMax / 1_000_000 * 1.15 ... scaleMax / 1_000_000 * 1.15)
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let mb = value.as(Double.self) { Text(String(format: "%.0f MB", mb)) }
                    }
                }
            }
            .frame(height: min(280, CGFloat(rows.count) * 36 + 40))
            .accessibilityLabel("按用途划分的空间变化条形图")
        }
    }
}

struct IntervalVisualPanel: View {
    let report: IntervalExplanationReport
    @State private var showDetails = false
    private var visual: IntervalVisualSummary { IntervalVisualBuilder.build(report: report) }
    var body: some View {
        SectionPanel(
            title: "这段时间磁盘怎么了？",
            subtitle: "先看结论和分布，需要时再展开技术说明。"
        ) {
            IntervalStoryHeader(summary: visual)
            HStack(spacing: 12) {
                SummaryMetricTile(
                    icon: "internaldrive",
                    title: "卷可用空间变化",
                    value: report.volume.freeDelta.map(signedBytes) ?? "—",
                    tint: (report.volume.freeDelta ?? 0) < 0 ? .orange : .green)
                SummaryMetricTile(
                    icon: "chart.bar.fill",
                    title: "监控路径合计",
                    value: visual.barRows.isEmpty ? "—" : signedBytes(visual.explained),
                    tint: Color(red: 0.12, green: 0.36, blue: 0.72))
                SummaryMetricTile(
                    icon: "questionmark.folder",
                    title: "卷级未解释估计",
                    value: report.uncoveredBytes.map(signedBytes) ?? "—",
                    tint: .secondary)
            }
            if let swap = report.swap.usedDelta, swap != 0 {
                HStack(spacing: 8) {
                    Image(systemName: "memorychip").foregroundStyle(.secondary)
                    Text("系统 Swap 变化 \(signedBytes(swap))（不归属某个 App）").font(.caption).foregroundStyle(.secondary)
                }
            }
            PurposeBreakdownChart(rows: visual.barRows)
            DisclosureGroup("展开技术说明与构建信息", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    if let commit = report.buildGitCommit, let schema = report.buildSchema {
                        Text("写入方 schema v\(schema)，commit \(commit)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(report.volume.methodNote).font(.caption).foregroundStyle(.secondary)
                    Text(report.uncoveredNote).font(.caption).foregroundStyle(.secondary)
                    ForEach(report.purposeGroups) { group in
                        Text("· \(group.purpose.displayName)：\(group.netBytes.map(signedBytes) ?? "部分未知")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 6)
            }.font(.caption)
        }
    }
}

// MARK: - 事件文件：横向影响条

struct FileImpactBars: View {
    let files: [FileChange]
    private var top: [(FileChange, Double)] {
        let withDelta = files.compactMap { change -> (FileChange, Int64)? in
            guard let d = change.deltaAllocated, d != 0 else { return nil }
            return (change, d)
        }
        let maxAbs = Double(withDelta.map { abs($0.1) }.max() ?? 1)
        return withDelta.prefix(8).map { ($0.0, Double($0.1) / maxAbs) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("影响最大的文件").font(.subheadline.weight(.semibold))
            if top.isEmpty {
                Text("没有可绘制的分配字节变化。").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(top.enumerated()), id: \.offset) { _, pair in
                    let (change, fraction) = pair
                    HStack(spacing: 10) {
                        Text(shortPath(change.displayPath)).font(.caption).lineLimit(1).frame(width: 140, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.12))
                                Capsule()
                                    .fill((change.deltaAllocated ?? 0) >= 0 ? Color.orange : Color.green)
                                    .frame(width: geo.size.width * min(1, abs(fraction)))
                            }
                        }.frame(height: 8)
                        Text(change.deltaAllocated.map(signedBytes) ?? "?").font(.caption.monospacedDigit()).frame(width: 72, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - 目录增长 Top 图

struct TopGrowthChart: View {
    let rows: [GrowthSummary]
    private var chartRows: [(String, Double, Int64)] {
        let top = rows.prefix(8)
        let maxAbs = Double(top.map { abs($0.netBytes) }.max() ?? 1)
        return top.map { (shortPath($0.path), Double($0.netBytes) / maxAbs, $0.netBytes) }
    }
    var body: some View {
        if chartRows.isEmpty { EmptyView() } else {
            Chart(Array(chartRows.enumerated()), id: \.offset) { _, row in
                BarMark(x: .value("净变化", Double(row.2) / 1_000_000), y: .value("目录", row.0))
                    .foregroundStyle(row.2 >= 0 ? Color.orange.gradient : Color.green.gradient)
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(String(format: "%.0f MB", v)) }
                    }
                }
            }
            .frame(height: min(260, CGFloat(chartRows.count) * 32 + 24))
        }
    }
}
