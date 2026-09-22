import SwiftUI

struct CashFlowForecastSettingsView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore

    private var forecast: CashFlowForecast {
        CashFlowForecastEngine.evaluate(state: store.state, preferences: preferences.value)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.value.cashFlowForecastEnabled },
            set: { preferences.update { $0.cashFlowForecastEnabled = $1 } }
        )
    }

    private var yellowPercentBinding: Binding<Double> {
        Binding(
            get: { preferences.value.forecastYellowThreshold * 100.0 },
            set: { newVal in
                let yellow = min(100.0, max(1.0, newVal.rounded())) / 100.0
                preferences.update { prefs, _ in
                    prefs.forecastYellowThreshold = yellow
                    if prefs.forecastRedThreshold <= yellow {
                        prefs.forecastRedThreshold = min(2.0, yellow + 0.05)
                    }
                }
            }
        )
    }

    private var redPercentBinding: Binding<Double> {
        Binding(
            get: { preferences.value.forecastRedThreshold * 100.0 },
            set: { newVal in
                let red = min(200.0, max(2.0, newVal.rounded())) / 100.0
                preferences.update { prefs, _ in
                    prefs.forecastRedThreshold = red
                    if prefs.forecastYellowThreshold >= red {
                        prefs.forecastYellowThreshold = max(0.01, red - 0.05)
                    }
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SettingsGlassSection("Forecasting") {
                    Toggle("Forecasting", isOn: enabledBinding)
                }

                SettingsGlassSection("Warning Thresholds") {
                    VStack(spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Yellow Warning")
                                    .font(.subheadline.weight(.medium))
                                Text("Caution threshold")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Int(yellowPercentBinding.wrappedValue))%")
                                .font(.subheadline.monospacedDigit().bold())
                                .foregroundStyle(.orange)
                                .frame(width: 44, alignment: .trailing)
                            Stepper(
                                "",
                                value: yellowPercentBinding,
                                in: 1...100,
                                step: 5
                            )
                            .labelsHidden()
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Red Warning")
                                    .font(.subheadline.weight(.medium))
                                Text("Critical limit exceedance")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Int(redPercentBinding.wrappedValue))%")
                                .font(.subheadline.monospacedDigit().bold())
                                .foregroundStyle(.red)
                                .frame(width: 44, alignment: .trailing)
                            Stepper(
                                "",
                                value: redPercentBinding,
                                in: max(2, yellowPercentBinding.wrappedValue + 1)...200,
                                step: 5
                            )
                            .labelsHidden()
                        }
                    }
                }

                if !forecast.eligible {
                    SettingsGlassSection("Status") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Forecasting starts after 14 days of recorded spending.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            HStack {
                                ProgressView(value: Double(forecast.availableHistorySpan), total: 14)
                                    .tint(.secondary)
                                Text("\(forecast.availableHistorySpan) of 14 days available")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    SettingsGlassSection("Status") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(format: NSLocalizedString("Forecast based on the last %lld days", comment: ""), Int64(forecast.historyDays)))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Includes scheduled transactions and installments.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Cash Flow Forecast")
        .navigationBarTitleDisplayMode(.inline)
    }
}

