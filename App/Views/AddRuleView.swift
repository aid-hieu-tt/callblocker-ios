import SwiftUI
import CallBlockerCore

/// FR-02: nhập mẫu số, kiểm tra hợp lệ trực tiếp (BR-03, BR-04) trước khi lưu.
struct AddRuleView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var saveError: String?
    @FocusState private var focused: Bool

    private let examples = ["024 8888 xxxx", "028 999 xxxx", "1900 xxxx", "0889 123 456"]

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Ví dụ: 0248888xxxx", text: $input)
                        .font(.title3.monospaced())
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .focused($focused)
                } header: {
                    Text("Số hoặc mẫu số")
                } footer: {
                    Text("x hoặc * thay cho một chữ số bất kỳ. Số bắt đầu bằng 0 được tự chuyển sang mã quốc gia 84.")
                }

                if !input.isEmpty {
                    Section("Kết quả") { preview }
                }

                Section("Gợi ý") {
                    ForEach(examples, id: \.self) { example in
                        Button(example) { input = example }
                            .font(.body.monospaced())
                    }
                }
            }
            .navigationTitle("Thêm quy tắc")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu", action: save).disabled(!isValid)
                }
            }
            .onAppear { focused = true }
        }
    }

    private var validation: Result<BlockPattern, PatternError> { model.validate(input) }

    private var isValid: Bool {
        if case .success = validation { return true }
        return false
    }

    @ViewBuilder
    private var preview: some View {
        switch validation {
        case .success(let pattern):
            LabeledRow(title: "Chuẩn quốc tế", value: "+" + pattern.normalized)
            LabeledRow(title: "Số lượng bị chặn", value: PatternParser.formatCount(pattern.numberCount))
            if let first = pattern.ranges().first, let last = pattern.ranges().last {
                LabeledRow(title: "Từ", value: PhoneNormalizer.nationalDisplay(first.lower))
                LabeledRow(title: "Đến", value: PhoneNormalizer.nationalDisplay(last.upper))
            }
            if let saveError {
                Text(saveError).foregroundColor(.red)
            }
        case .failure(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.circle.fill")
                .foregroundColor(.red)
        }
    }

    private func save() {
        do {
            try model.addRule(input)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

struct LabeledRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.body.monospaced())
        }
    }
}
