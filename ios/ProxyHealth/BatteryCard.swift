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
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 2) {
                Text("เข้านอน \(battery.bedLevel)% → ตื่น \(battery.wakeLevel)%")
                Text(BatterySegments.sinceWakeText(battery.sinceWake))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
    }

    private var gauge: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(Array(BatterySegments.states(level: battery.level, wakeLevel: battery.wakeLevel).enumerated()), id: \.offset) { _, state in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(color(for: state))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 44)
            markers.padding(.top, 7)
        }
    }

    /// Each marker sits over its own value on the bar rather than in a caption underneath, and
    /// the left one steps aside when the two would overlap.
    private var markers: some View {
        let collide = BatterySegments.markersCollide(level: battery.level, wakeLevel: battery.wakeLevel)
        return GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Text("0").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text("100").font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(width: geometry.size.width, alignment: .trailing)
                marker("ตอนนี้", battery.level, at: geometry.size.width, anchor: collide ? 0.92 : 0.5)
                marker("ตื่นมา", battery.wakeLevel, at: geometry.size.width, anchor: 0.5)
            }
        }
        .frame(height: 30)
    }

    private func marker(_ label: String, _ value: Int, at width: Double, anchor: Double) -> some View {
        VStack(spacing: 3) {
            Rectangle().fill(Brand.track).frame(width: 1, height: 8)
            HStack(spacing: 3) {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(value)%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
        }
        .fixedSize()
        .alignmentGuide(.leading) { $0.width * anchor }
        .offset(x: width * Double(min(100, max(0, value))) / 100)
    }

    private func color(for state: BatterySegments.State) -> Color {
        if placeholder { return Brand.track }
        return switch state {
        case .filled: fillColor
        case .used: Brand.track.opacity(0.95)
        case .empty: Brand.track.opacity(0.4)
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
