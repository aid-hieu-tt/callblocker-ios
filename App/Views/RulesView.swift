import SwiftUI
import CallBlockerCore

struct RulesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingAdd = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    if model.extensionStatus == .disabled {
                        Button {
                            Task { await model.openSystemSettings() }
                        } label: {
                            Label("Tiện ích đang tắt — chạm để bật trong Cài đặt", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                    }
                    HStack {
                        Text("Số đang bị chặn")
                        Spacer()
                        Text(PatternParser.formatCount(model.effectiveBlockedCount))
                            .font(.headline.monospacedDigit())
                    }
                    SyncStatusRow(status: model.syncStatus) {
                        Task { await model.reloadCallDirectory() }
                    }
                }

                Section {
                    if model.rules.isEmpty {
                        Text("Chưa có quy tắc. Chạm + để thêm, ví dụ 0248888xxxx.")
                            .foregroundColor(.secondary)
                    }
                    ForEach(model.rules) { rule in
                        RuleRow(rule: rule) { active in model.setRule(rule, active: active) }
                    }
                    .onDelete { offsets in
                        model.deleteRules(offsets.map { model.rules[$0].id })
                    }
                } header: {
                    Text("Quy tắc")
                } footer: {
                    Text("Dùng x hoặc * cho chữ số bất kỳ. Tối đa \(PatternParser.defaultMaxWildcards) ký tự đại diện mỗi quy tắc.")
                }
            }
            .navigationTitle("Chặn cuộc gọi")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Thêm quy tắc")
                }
            }
            .refreshable { await model.reloadCallDirectory() }
            .sheet(isPresented: $showingAdd) { AddRuleView() }
        }
        .navigationViewStyle(.stack)
    }
}

private struct RuleRow: View {
    let rule: BlockRule
    let onToggle: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { rule.isActive }, set: onToggle)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.patternDisplay)
                    .font(.body.monospaced())
                Text("\(PatternParser.formatCount(rule.numberCount)) số · +\(rule.normalizedPattern)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct SyncStatusRow: View {
    let status: AppModel.SyncStatus
    let retry: () -> Void

    var body: some View {
        HStack {
            switch status {
            case .idle:
                Label("Chưa đồng bộ trong phiên này", systemImage: "clock")
                    .foregroundColor(.secondary)
            case .syncing:
                ProgressView()
                Text("Đang nạp vào CallKit…")
            case .succeeded(let seconds, let summary):
                Label(successText(seconds: seconds, summary: summary), systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundColor(.red)
            }
            Spacer()
            if status != .syncing {
                Button("Đồng bộ", action: retry)
                    .buttonStyle(.borderless)
            }
        }
        .font(.subheadline)
    }

    private func successText(seconds: Double, summary: CallDirectoryLoadSummary?) -> String {
        let time = String(format: "%.1fs", seconds)
        guard let summary else { return "Đã đồng bộ (\(time))" }
        switch summary.mode {
        case .full:
            return "Nạp toàn phần \(PatternParser.formatCount(summary.blockedAdded)) số (\(time))"
        case .incremental:
            return "Cập nhật +\(PatternParser.formatCount(summary.blockedAdded)) / −\(PatternParser.formatCount(summary.blockedRemoved)) (\(time))"
        }
    }
}
