import SwiftUI

/// FR-01 / BR-02: hướng dẫn bật tiện ích trong Cài đặt iOS.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var checking = false

    private let steps: [(icon: String, text: String)] = [
        ("gearshape.fill", "Mở ứng dụng Cài đặt"),
        ("phone.fill", "Chọn Điện thoại"),
        ("hand.raised.fill", "Chọn Chặn cuộc gọi & nhận dạng"),
        ("switch.2", "Bật công tắc Chặn Cuộc Gọi"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "phone.down.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)

                Text("Bật tính năng chặn cuộc gọi")
                    .font(.title.bold())
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)

                Text("iOS yêu cầu bạn tự cho phép ứng dụng chặn và nhận dạng cuộc gọi. Việc này chỉ cần làm một lần.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(spacing: 14) {
                            Text("\(index + 1)")
                                .font(.headline)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color.accentColor.opacity(0.15)))
                            Image(systemName: step.icon)
                                .frame(width: 24)
                                .foregroundColor(.accentColor)
                            Text(step.text)
                        }
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))

                Button {
                    Task { await model.openSystemSettings() }
                } label: {
                    Label("Mở Cài đặt", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    Task {
                        checking = true
                        await model.refreshExtensionStatus()
                        checking = false
                    }
                } label: {
                    HStack {
                        if checking { ProgressView() }
                        Text("Tôi đã bật — kiểm tra lại")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Thiết lập quy tắc trước") { model.onboardingSkipped = true }
                    .frame(maxWidth: .infinity)
                    .font(.footnote)
            }
            .padding(.horizontal, 24)
        }
    }
}
