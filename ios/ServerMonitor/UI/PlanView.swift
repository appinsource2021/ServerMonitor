import SwiftUI

/// Shown when a locked feature is tapped, and from Settings → Plan.
/// `reason` is the feature that opened it; it is listed first.
struct PlanSheet: View {
    var reason: Feature?
    @Environment(\.dismiss) private var dismiss
    private let plans = PlanStore.shared

    private var ordered: [Feature] {
        guard let reason else { return Feature.allCases }
        return [reason] + Feature.allCases.filter { $0 != reason }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let reason {
                        Banner(icon: "lock.fill", title: "\(reason.title) is a Pro feature",
                               text: reason.detail, color: Theme.warn)
                    }
                    Card(padding: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Your plan").font(.system(size: 12, weight: .semibold)).tracking(0.7).foregroundStyle(Theme.text2)
                            Text(plans.statusLine).font(.system(size: 17, weight: .semibold))
                            if plans.plan == .trial {
                                Text("Everything is open until \(plans.trialEnds.formatted(date: .abbreviated, time: .omitted)). After that the app keeps watching your first server; the features below need Pro.")
                                    .font(.system(size: 13)).foregroundStyle(Theme.text2)
                            } else if plans.plan == .free {
                                Text("Watching stays free: metrics, Docker and services, health check and alerts inside the app.")
                                    .font(.system(size: 13)).foregroundStyle(Theme.text2)
                            }
                        }
                    }

                    VStack(spacing: 8) {
                        SectionHeader(text: "Pro includes")
                        ListCard {
                            ForEach(ordered) { f in
                                HStack(spacing: 12) {
                                    Image(systemName: f.icon).foregroundStyle(Theme.accent).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.title).font(.system(size: 15, weight: .medium))
                                        Text(f.detail).font(.system(size: 12)).foregroundStyle(Theme.text2)
                                    }
                                    Spacer()
                                    Image(systemName: plans.allows(f) ? "checkmark.circle.fill" : "lock.fill")
                                        .foregroundStyle(plans.allows(f) ? Theme.ok : Theme.text2)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                            }
                        }
                    }

                    if plans.plan != .pro {
                        Button { } label: { Text("Pro is coming to the App Store") }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(true).opacity(0.6)
                        Text("Purchases are not available in this build yet.")
                            .font(.system(size: 12)).foregroundStyle(Theme.text2).padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24).padding(.top, 8)
            }
            .background(Theme.bg)
            .navigationTitle("Server Monitor Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

/// Settings → Plan: the status line, the sheet, and the developer switch to try Free or Trial.
struct PlanSection: View {
    private let plans = PlanStore.shared
    @State private var showSheet = false

    var body: some View {
        VStack(spacing: 8) {
            SectionHeader(text: "Plan")
            ListCard {
                Button { showSheet = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: plans.plan == .pro ? "checkmark.seal.fill" : "seal").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plans.statusLine).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                            Text("What Pro includes").font(.system(size: 12)).foregroundStyle(Theme.text2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
                    }
                    .padding(14)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                HStack {
                    Text("Simulate").font(.system(size: 15))
                    Spacer()
                    Picker("Simulate plan", selection: Binding(get: { plans.simulated }, set: { plans.simulated = $0 })) {
                        Text("Off").tag(Plan?.none)
                        ForEach(Plan.allCases) { p in Text(p.label).tag(Plan?.some(p)) }
                    }
                    .pickerStyle(.menu).tint(Theme.text2)
                }
                .padding(.horizontal, 14).frame(minHeight: 48)
            }
            Text("Simulate shows how the app behaves on another plan. It does not change what you own.")
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
        }
        .sheet(isPresented: $showSheet) { PlanSheet() }
    }
}

/// A whole screen that is locked (the Team tab on Free).
struct PlanLockedScreen: View {
    let feature: Feature
    @State private var showSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(Theme.text2)
                Text(feature.title).font(.system(size: 20, weight: .semibold))
                Text(feature.detail).font(.system(size: 14)).foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                Button("See Pro") { showSheet = true }.buttonStyle(PrimaryButtonStyle(secondary: true)).padding(.horizontal, 60)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSheet) { PlanSheet(reason: feature) }
        }
    }
}
