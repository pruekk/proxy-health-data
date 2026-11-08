import SwiftUI

/// How much is left right now. Readiness answers "should I train hard today"; this answers
/// "what is still in the tank". Twenty segments: lit for what is left, grey for what the day has
/// spent, faint for what last night never charged — so the morning's level stays visible all day.
struct BatteryCard: View {
    let battery: BatteryDoc
    var placeholder = false
    @State private var explaining = false

    var body: some View {
        Card {
            HStack {
                Text("พลังงานร่างกาย").font(.system(size: 10.5, weight: .bold)).kerning(0.9).foregroundStyle(.secondary)
                Spacer()
                Button { explaining = true } label: {
                    Image(systemName: "info.circle").font(.system(size: 15)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            headline.padding(.top, 10)
            gauge.padding(.top, 14)
            scale.padding(.top, 8)

            if let message = battery.message {
                Text(message)
                    .font(.system(size: 12.5)).lineSpacing(2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 13)
            }
            if !battery.missing.isEmpty {
                Text("ยังขาด \(BatteryFormat.missingNames(battery.missing))")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 7)
            }
        }
        .sheet(isPresented: $explaining) { ReadinessInfoSheet(section: .battery) }
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(battery.level)").font(.system(size: 34, weight: .bold)).monospacedDigit()
            Text("%").font(.system(size: 34, weight: .bold)).foregroundStyle(.secondary)
            if battery.estimated {
                Text("ประมาณ")
                    .font(.system(size: 10, weight: .bold)).kerning(0.4)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Brand.plate, in: Capsule())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            Spacer(minLength: 0)
        }
    }

    private var gauge: some View {
        HStack(spacing: 3) {
            ForEach(Array(BatterySegments.states(level: battery.level, wakeLevel: battery.wakeLevel).enumerated()), id: \.offset) { _, state in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(color(for: state))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 44)
    }

    /// Current level on the left, the day's highest on the right. The grey between them is what
    /// has been spent since.
    private var scale: some View {
        HStack {
            Text("ตอนนี้ \(battery.level)%")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            Spacer()
            Text("สูงสุด \(battery.wakeLevel)%")
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func color(for state: BatterySegments.State) -> Color {
        if placeholder { return Brand.track }
        return switch state {
        case .filled: fillColor
        case .used: Color(uiColor: .systemGray3)
        case .empty: Brand.track
        }
    }

    private var fillColor: Color {
        return switch battery.level {
        case ..<20: .red
        case ..<50: .orange
        default: Brand.exercise
        }
    }
}
