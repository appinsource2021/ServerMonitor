import SwiftUI
import UserNotifications
import LocalAuthentication

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var store: ServerStore?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in self.store?.didReceiveDeviceToken(hex) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("push registration failed: \(error)")
    }

    // Show alerts while the app is open, too.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        Task { @MainActor in await self.store?.refreshAll() }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let server = response.notification.request.content.userInfo["server"] as? String {
            await MainActor.run { self.store?.openServerName = server }
        }
    }
}

@main
struct ServerMonitorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = ServerStore()
    @State private var lock = AppLock()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environment(store)
                if lock.locked {
                    LockView(lock: lock)
                }
            }
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            .onAppear {
                delegate.store = store
                lock.unlockIfNeeded()
                store.startPolling()
                Task {
                    let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                    if ok { await MainActor.run { UIApplication.shared.registerForRemoteNotifications() } }
                }
            }
            .onChange(of: phase) { _, p in
                switch p {
                case .active:
                    lock.unlockIfNeeded()
                    store.startPolling()
                case .background:
                    lock.lockIfEnabled()
                    store.stopPolling()
                default: break
                }
            }
        }
    }
}

@Observable
final class AppLock {
    var enabled: Bool { UserDefaults.standard.object(forKey: "applock.enabled") as? Bool ?? true }
    var locked: Bool

    init() {
        locked = UserDefaults.standard.object(forKey: "applock.enabled") as? Bool ?? true
    }

    func lockIfEnabled() { if enabled { locked = true } }

    func unlockIfNeeded() {
        guard locked else { return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { locked = false; return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Server Monitor") { ok, _ in
            DispatchQueue.main.async { if ok { self.locked = false } }
        }
    }
}

struct LockView: View {
    let lock: AppLock
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
                Text("Server Monitor is locked").font(.headline)
                Button("Unlock") { lock.unlockIfNeeded() }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(width: 200)
            }
        }
    }
}

struct RootView: View {
    @Environment(ServerStore.self) private var store
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ServerListView()
                .tabItem { Label("Servers", systemImage: "server.rack") }
                .tag(0)
            AlertsView()
                .tabItem { Label("Alerts", systemImage: "bell") }
                .badge(store.allActiveAlerts.count)
                .tag(1)
            if store.isAdmin {
                Group {
                    if PlanStore.shared.allows(.team) { TeamView() } else { PlanLockedScreen(feature: .team) }
                }
                .tabItem { Label("Team", systemImage: "person.2") }
                .tag(3)
            }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
        .onOpenURL { url in
            switch PhoneLink.parse(url.absoluteString) {
            case .authorize(let a): store.pendingAuthorize = a
            case .importServers(let i): store.pendingImport = i
            case nil: if let link = TeamJoin.parse(url.absoluteString) { store.pendingJoin = link }
            }
        }
        .sheet(item: Binding(get: { store.pendingJoin.map(JoinSheetItem.init) }, set: { if $0 == nil { store.pendingJoin = nil } })) { item in
            JoinView(link: item.link)
        }
        .sheet(item: Binding(get: { store.pendingAuthorize }, set: { if $0 == nil { store.pendingAuthorize = nil } })) { a in
            AuthorizePhoneView(link: a)
        }
        .sheet(item: Binding(get: { store.pendingImport }, set: { if $0 == nil { store.pendingImport = nil } })) { i in
            ImportServersView(link: i)
        }
        .toolbarBackground(Theme.bg.opacity(0.94), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onChange(of: store.openServerName) { _, name in
            if name != nil { tab = 0 }
        }
    }
}

struct JoinSheetItem: Identifiable {
    let link: TeamJoin.Link
    var id: String { link.code }
}
