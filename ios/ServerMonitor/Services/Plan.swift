import Foundation
import Observation

/// Everything a plan can lock lives here. Screens never look at the plan name;
/// they ask `PlanStore.shared.allows(.terminal)` and show `PlanSheet` when the answer is no.
/// Prices, limits and the trial length are the constants in `PlanConfig`.
enum Feature: String, CaseIterable, Identifiable {
    case moreServers
    case terminal
    case files
    case cleanup
    case containerActions
    case serviceActions
    case serviceInstall
    case push
    case team

    var id: String { rawValue }

    var title: String {
        switch self {
        case .moreServers: "More than \(PlanConfig.freeServerLimit) server"
        case .terminal: "Terminal"
        case .files: "File manager"
        case .cleanup: "Smart cleanup"
        case .containerActions: "Container start, stop, restart"
        case .serviceActions: "Service start, stop, restart"
        case .serviceInstall: "Install services"
        case .push: "Push notifications"
        case .team: "Team access"
        }
    }

    var detail: String {
        switch self {
        case .moreServers: "Free watches one server. Pro watches as many as you add."
        case .terminal: "A real SSH terminal with htop, vim and quick commands."
        case .files: "Browse, view, edit, upload and delete files on the server."
        case .cleanup: "Reclaim disk space from Docker, caches and old logs."
        case .containerActions: "Start, stop and restart Docker containers from the phone."
        case .serviceActions: "Start, stop and restart systemd services."
        case .serviceInstall: "Install Nginx, MariaDB, Redis and others with one tap."
        case .push: "Alerts reach the phone while the app is closed."
        case .team: "Let colleagues watch servers without SSH, through the relay."
        }
    }

    var icon: String {
        switch self {
        case .moreServers: "server.rack"
        case .terminal: "terminal"
        case .files: "folder"
        case .cleanup: "sparkles"
        case .containerActions: "shippingbox"
        case .serviceActions: "gearshape.2"
        case .serviceInstall: "square.and.arrow.down"
        case .push: "bell.badge"
        case .team: "person.2"
        }
    }
}

enum Plan: String, CaseIterable, Identifiable {
    case free, trial, pro
    var id: String { rawValue }
    var label: String {
        switch self {
        case .free: "Free"
        case .trial: "Trial"
        case .pro: "Pro"
        }
    }
}

/// The numbers. Change them here and nowhere else.
enum PlanConfig {
    static let trialDays = 14
    static let freeServerLimit = 1
    /// Free = watch only: monitoring, Docker and services lists, health check, alerts in the app.
    static let freeFeatures: Set<Feature> = []
    /// There is no StoreKit yet, so nothing can be bought and nobody must be locked out:
    /// everyone is Pro until this is true. Flip it when purchases ship.
    static let purchasesEnabled = false
}

@Observable
final class PlanStore {
    static let shared = PlanStore()

    /// Set from Settings to see how Free or Trial behaves. Nil = the real plan.
    var simulated: Plan? {
        didSet { UserDefaults.standard.set(simulated?.rawValue, forKey: Self.simulatedKey) }
    }

    /// Set by StoreKit once it exists. Until then false, which `purchasesEnabled` makes harmless.
    var purchased = false

    /// The day the app was first opened on this device. Kept in the Keychain so that
    /// deleting and reinstalling the app does not restart the trial.
    let trialStarted: Date

    private static let simulatedKey = "plan.simulated"
    private static let trialKey = "plan.trialStarted"

    private init() {
        if let s = Keychain.string(Self.trialKey), let t = TimeInterval(s) {
            trialStarted = Date(timeIntervalSince1970: t)
        } else {
            trialStarted = Date()
            Keychain.setString(String(trialStarted.timeIntervalSince1970), for: Self.trialKey)
        }
        simulated = UserDefaults.standard.string(forKey: Self.simulatedKey).flatMap(Plan.init(rawValue:))
    }

    var trialEnds: Date { trialStarted.addingTimeInterval(TimeInterval(PlanConfig.trialDays) * 86_400) }
    var trialDaysLeft: Int { max(0, Int((trialEnds.timeIntervalSinceNow / 86_400).rounded(.up))) }
    var trialActive: Bool { Date() < trialEnds }

    /// The plan the rules give, ignoring the simulation.
    var actual: Plan {
        guard PlanConfig.purchasesEnabled else { return .pro }
        if purchased { return .pro }
        return trialActive ? .trial : .free
    }

    var plan: Plan { simulated ?? actual }

    var serverLimit: Int? { plan == .free ? PlanConfig.freeServerLimit : nil }

    func allows(_ f: Feature) -> Bool {
        plan != .free || PlanConfig.freeFeatures.contains(f)
    }

    /// `current` = servers already in the list.
    func canAddServer(current: Int) -> Bool {
        guard let limit = serverLimit else { return true }
        return current < limit
    }

    /// One line for Settings: "Pro", "Trial · 9 days left", "Free · 1 server".
    var statusLine: String {
        switch plan {
        case .pro: "Pro"
        case .trial: "Trial · \(trialDaysLeft) day\(trialDaysLeft == 1 ? "" : "s") left"
        case .free: "Free · \(PlanConfig.freeServerLimit) server, watch only"
        }
    }
}
