import SwiftUI
import CallBlockerCore

/// FR-05: nhãn cảnh báo cho số rác cộng đồng — chỉ hiển thị, không chặn cứng.
struct SpamView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("Cảnh báo số rác cộng đồng", isOn: Binding(
                        get: { model.spamEnabled },
                        set: { model.setSpamEnabled($0) }
                    ))
                } footer: {
                    Text("Khi có cuộc gọi từ số nằm trong danh sách, iOS sẽ hiển thị nhãn như [ Lừa đảo ] hoặc [ Quảng cáo ]. Bạn vẫn có thể tự quyết định nghe máy.")
                }

                Section("Dữ liệu") {
                    LabeledRow(title: "Số trong danh sách", value: PatternParser.formatCount(model.spamCount))
                    LabeledRow(title: "Cập nhật lần cuối", value: lastSyncText)
                    Button {
                        Task { await model.refreshSpamList() }
                    } label: {
                        HStack {
                            if model.isRefreshingSpam { ProgressView() }
                            Text("Cập nhật ngay")
                        }
                    }
                    .disabled(model.isRefreshingSpam || !model.spamEnabled)
                }
            }
            .navigationTitle("Số rác")
        }
        .navigationViewStyle(.stack)
    }

    private var lastSyncText: String {
        guard let date = model.spamLastSync else { return "Chưa bao giờ" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
