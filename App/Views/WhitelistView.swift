import SwiftUI
import CallBlockerCore

/// FR-03: số ngoại lệ không bao giờ bị chặn dù nằm trong dải chặn (BR-06).
struct WhitelistView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newNumber = ""
    @State private var newNote = ""
    @State private var syncingContacts = false
    @State private var inputError: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle(isOn: Binding(
                        get: { model.contactsWhitelistEnabled },
                        set: { enabled in
                            Task {
                                syncingContacts = true
                                await model.setContactsWhitelist(enabled: enabled)
                                syncingContacts = false
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Không chặn số trong Danh bạ")
                            if model.contactsWhitelistEnabled {
                                Text("\(PatternParser.formatCount(model.contactWhitelistCount)) số từ Danh bạ")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .disabled(syncingContacts)
                    if syncingContacts {
                        HStack { ProgressView(); Text("Đang đọc Danh bạ…") }
                    }
                } footer: {
                    Text("Danh bạ chỉ được đối chiếu trên thiết bị này và không bao giờ được gửi lên máy chủ.")
                }

                Section("Thêm số ngoại lệ") {
                    TextField("Số điện thoại", text: $newNumber)
                        .keyboardType(.phonePad)
                    TextField("Ghi chú (vd. Shipper GHN)", text: $newNote)
                    if let inputError {
                        Text(inputError).foregroundColor(.red).font(.footnote)
                    }
                    Button("Thêm vào danh sách trắng", action: add)
                        .disabled(newNumber.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section("Số ngoại lệ thủ công") {
                    if model.manualWhitelist.isEmpty {
                        Text("Chưa có số nào.").foregroundColor(.secondary)
                    }
                    ForEach(model.manualWhitelist) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(PhoneNormalizer.nationalDisplay(entry.phoneNumber)).font(.body.monospaced())
                            if let note = entry.note {
                                Text(note).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        model.removeManualWhitelist(offsets.map { model.manualWhitelist[$0] })
                    }
                }
            }
            .navigationTitle("Danh sách trắng")
        }
        .navigationViewStyle(.stack)
    }

    private func add() {
        do {
            try model.addManualWhitelist(newNumber, note: newNote)
            newNumber = ""
            newNote = ""
            inputError = nil
        } catch {
            inputError = error.localizedDescription
        }
    }
}
