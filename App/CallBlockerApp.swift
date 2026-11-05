import SwiftUI

@main
struct CallBlockerApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // BGTaskScheduler bắt buộc đăng ký trước khi app hoàn tất khởi chạy.
        SpamRefreshScheduler.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                Task { await model.refreshExtensionStatus() }
            case .background:
                SpamRefreshScheduler.schedule()
            default:
                break
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.extensionStatus == .disabled && !model.onboardingSkipped {
                OnboardingView()
            } else {
                MainTabView()
            }
        }
        .task { await model.refreshExtensionStatus() }
        .alert("Thông báo", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            RulesView()
                .tabItem { Label("Quy tắc chặn", systemImage: "phone.down.circle") }
            WhitelistView()
                .tabItem { Label("Danh sách trắng", systemImage: "person.crop.circle.badge.checkmark") }
            SpamView()
                .tabItem { Label("Số rác", systemImage: "exclamationmark.shield") }
        }
    }
}
