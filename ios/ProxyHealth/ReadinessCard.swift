import SwiftUI

/// Training readiness: the morning glance. The score, the band, the sentence and the factor
/// breakdown all come from the server, so this view only lays them out — the app and the AI
/// tools can never quote different numbers.
struct ReadinessCard: View {
    let readiness: ReadinessDoc
    @State private var explaining = false
    /// `.redacted` greys out text but leaves shapes alone, so a placeholder would show a
    /// convincing green dial. Colour is dropped explicitly instead.
    var placeholder = false

    var body: some View {
        Card {
            HStack {
                Text("ความพร้อมซ้อม").font(.system(size: 10.5, weight: .bold)).kerning(0.9).foregroundStyle(.secondary)
                Spacer()
                if !readiness.missing.isEmpty {
                    Text("ขาด \(readiness.missingNames)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                Button { explaining = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }

            if let score = readiness.score {
                HStack(alignment: .center, spacing: 16) {
                    dial(score)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(readiness.advice ?? "")
                            .font(.system(size: 15, weight: .semibold))
                            .lineSpacing(2)
                        if let reason = readiness.reason, !reason.isEmpty {
                            Text(reason)
                                .font(.system(size: 12.5))
                                .lineSpacing(2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 16)

                if !readiness.factors.isEmpty {
                    Divider().padding(.top, 18)
                    VStack(spacing: 10) {
                        ForEach(readiness.factors) { factor in
                            row(factor)
                        }
                    }
                    .padding(.top, 14)
                }

            } else {
                Text("ยังคำนวณไม่ได้ — ต้องมีอย่างน้อย 2 ใน 4 ปัจจัย (ขาด \(readiness.missingNames))")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
        .sheet(isPresented: $explaining) { sheet }
    }

    private var sheet: some View { ReadinessInfoSheet() }

    private func dial(_ score: Int) -> some View {
        ZStack {
            Circle().stroke(Brand.track, lineWidth: 13)
            Circle()
                .trim(from: 0, to: Double(score) / 100)
                .stroke(bandColor, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text("\(score)").font(.system(size: 30, weight: .bold)).monospacedDigit()
                Text(readiness.bandLabel ?? "").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 106, height: 106)
    }

    private func row(_ factor: ReadinessDoc.Factor) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(factor.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                if let note = factor.note {
                    Text(note).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 70, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.track)
                    Capsule().fill(color(for: factor.direction))
                        .frame(width: max(4, geometry.size.width * Double(factor.score) / 100))
                }
            }
            .frame(height: 6)
            // One rule down the column: the measured value, then your own normal in brackets.
            // The deviation is carried by the bar's length and colour instead.
            HStack(spacing: 4) {
                Text(measuredText(factor)).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                if let baseline = baselineText(factor) {
                    Text("(\(baseline))").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 108, alignment: .trailing)
        }
    }

    /// Sleep's baseline is a target in minutes; showing "ฐาน 480" next to "6:04" reads as two
    /// different quantities, so it is formatted the same way as the value.
    private func baselineText(_ factor: ReadinessDoc.Factor) -> String? {
        guard let baseline = factor.baseline else { return nil }
        if factor.key == "sleep" { return clock(baseline) }
        return baseline.formatted(baseline < 100 ? 1 : 0)
    }

    private func measuredText(_ factor: ReadinessDoc.Factor) -> String {
        switch factor.key {
        case "hrv": "\(factor.value.formatted(1)) ms"
        case "restingHeartRate": "\(factor.value.formatted(0)) bpm"
        case "sleep": clock(factor.value)
        case "load": "\(factor.value.formatted(0)) นาที"
        default: factor.value.formatted(1)
        }
    }

    private func clock(_ minutes: Double) -> String {
        "\(Int(minutes) / 60):\(String(format: "%02d", Int(minutes) % 60))"
    }

    private var bandColor: Color {
        if placeholder { return Brand.track }
        switch readiness.band {
        case "recover": return .red
        case "caution": return .orange
        case "ready": return Brand.exercise
        default: return .green
        }
    }

    private func color(for direction: String) -> Color {
        if placeholder { return Brand.track }
        switch direction {
        case "bad": return .red
        case "watch": return .orange
        default: return Brand.exercise
        }
    }
}
