import SwiftUI

/// The catch-all pane. Home to currency conversion — the one feature in Tinycast that reaches the
/// network, which is why it ships off and needs an explicit yes before it can be switched on.
struct MiscellaneousSettingsView: View {
    @ObservedObject private var currencyRates = AppCore.shared.currencyRates
    @State private var askingConsent = false
    @State private var refreshing = false
    @State private var refreshFailed = false

    var body: some View {
        SettingsPane(
            title: "Miscellaneous",
            subtitle: "Options that don't belong to a single feature."
        ) {
            SettingsCard(header: "Calculator") {
                SettingsRow(
                    title: "Currency Conversion",
                    subtitle: conversionStatus,
                    systemImage: "dollarsign.arrow.circlepath",
                    tint: .green,
                    statusDot: currencyRates.isEnabled ? .green : nil
                ) {
                    // Deliberately not bound straight to the setting: flipping it on only opens the
                    // consent sheet, so the switch springs back until the user actually accepts.
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { currencyRates.isEnabled },
                            set: { wantsOn in
                                if wantsOn {
                                    askingConsent = true
                                } else {
                                    currencyRates.setEnabled(false)
                                }
                            })
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                if currencyRates.isEnabled {
                    SettingsDivider()
                    SettingsRow(
                        title: "Exchange Rates",
                        subtitle: ratesStatus,
                        systemImage: "clock.arrow.circlepath",
                        tint: .gray
                    ) {
                        Button("Update Now") {
                            refreshing = true
                            Task {
                                let landed = await currencyRates.refreshNow()
                                refreshFailed = !landed
                                refreshing = false
                            }
                        }
                        .disabled(refreshing)
                    }

                    // The target a bare `300 usd` converts to. Only shown while conversion is on —
                    // the default is meaningless to a feature the user hasn't consented to.
                    SettingsDivider()
                    SettingsRow(
                        title: "Default Currency",
                        subtitle: "Target for conversions without a destination, like “300 usd”.",
                        systemImage: "arrow.triangle.swap",
                        tint: .green
                    ) {
                        Picker("", selection: Binding(
                            get: { currencyRates.defaultCurrencyOverride ?? "" },
                            set: { currencyRates.setDefaultCurrency($0.isEmpty ? nil : $0) })
                        ) {
                            // Empty selection string is the sentinel for "use the system default".
                            Text("System Default").tag("")
                            ForEach(currencyRates.supportedCurrencies, id: \.code) { currency in
                                Text("\(currency.code) — \(currency.name)").tag(currency.code)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }
        .sheet(isPresented: $askingConsent) {
            CurrencyConsentSheet(
                onCancel: { askingConsent = false },
                onAccept: {
                    askingConsent = false
                    currencyRates.setEnabled(true)
                })
        }
    }

    /// Carries the off-state promise that used to need its own callout: nothing is contacted until
    /// the switch is on.
    private var conversionStatus: String {
        let examples = "Convert inline — \"100 dollars to yen\", \"€20 to GBP\"."
        return currencyRates.isEnabled ? examples : "\(examples) Off — no service is contacted."
    }

    private var ratesStatus: String {
        if refreshing { return "Updating…" }
        if refreshFailed { return "Couldn't reach \(CurrencyRateStore.provider). Try again." }
        guard let fetched = currencyRates.rates?.fetchedAt else {
            return "\(CurrencyRateStore.provider) · not downloaded yet."
        }
        let stamp = fetched.formatted(date: .abbreviated, time: .shortened)
        return "\(CurrencyRateStore.provider) · updated \(stamp). Refreshes daily."
    }
}

/// The consent step. Three facts are the ones that actually decide the answer — who is contacted, how
/// often, and that nothing personal goes with it — plus the provider link so the claim is checkable.
private struct CurrencyConsentSheet: View {
    let onCancel: () -> Void
    let onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            HStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "network")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.green)
                Text("Turn on currency conversion?")
                    .font(.headline)
            }

            Text(
                "Tinycast downloads exchange rates from \(CurrencyRateStore.provider) and Coinbase once a day and "
                + "keeps a copy on your Mac. No account, no identifiers, nothing you type. "
                + "Turning it off deletes the cached rates."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Spacing.lg) {
                HStack(spacing: Theme.Spacing.md) {
                    Link(destination: CurrencyRateStore.providerURL) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text(CurrencyRateStore.providerURL.host() ?? "Provider")
                            Image(systemName: "arrow.up.right.square")
                        }
                        .font(.callout)
                    }
                    Link(destination: URL(string: "https://coinbase.com")!) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text("coinbase.com")
                            Image(systemName: "arrow.up.right.square")
                        }
                        .font(.callout)
                    }
                }
                Spacer()
                Button("Not Now", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Enable", action: onAccept)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(width: 420)
    }
}
