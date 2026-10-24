import SwiftUI

/// Training readiness: the morning glance. The score, the band, the sentence and the factor
/// breakdown all come from the server, so this view only lays them out — the app and the AI
/// tools can never quote different numbers.
struct ReadinessCard: View {
    let readiness: ReadinessDoc

    var body: some View {
        Card {
            HStack {
                Text("ความพร้อมซ้อม").font(.system(size: 10.5, weight: .bold)).kerning(0.9).foregroundStyle(.secondary)
                Spacer()
                if !readiness.missing.isEmpty {
                    Text("ขาด \(readiness.missingNames)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }

            if let score = readiness.score {
                HStack(alignment: .center, spacing: 15) {
                    dial(score)
                    Text(readiness.headline ?? readiness.advice ?? "")
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .foregroundStyle(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)

                if !readiness.factors.isEmpty {
                    Divider().padding(.top, 14)
                    VStack(spacing: 9) {
                        ForEach(readiness.factors) { factor in
                            row(factor)
                        }
                    }
                    .padding(.top, 12)
                }

                if let basis = readiness.basis {
                    Text(basis).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 11)
                }
            } else {
                Text("ยังคำนวณไม่ได้ — ต้องมีอย่างน้อย 2 ใน 4 ปัจจัย (ขาด \(readiness.missingNames))")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
    }

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
            Text(factor.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.track)
                    Capsule().fill(color(for: factor.direction))
                        .frame(width: max(4, geometry.size.width * Double(factor.score) / 100))
                }
            }
            .frame(height: 6)
            HStack(spacing: 4) {
                Text(factor.deviation ?? factor.value.formatted(1))
                    .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                if let baseline = baselineText(factor) {
                    Text(baseline).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Sleep's baseline is a target in minutes; showing "ฐาน 480" next to "6:04" reads as two
    /// different quantities, so it is formatted the same way as the value.
    private func baselineText(_ factor: ReadinessDoc.Factor) -> String? {
        guard let baseline = factor.baseline else { return nil }
        if factor.key == "sleep" {
            return "เป้า \(Int(baseline) / 60):\(String(format: "%02d", Int(baseline) % 60))"
        }
        return "ฐาน \(baseline.formatted(baseline < 100 ? 1 : 0))"
    }

    private var bandColor: Color {
        switch readiness.band {
        case "recover": .red
        case "caution": .orange
        case "ready": Brand.exercise
        default: .green
        }
    }

    private func color(for direction: String) -> Color {
        switch direction {
        case "bad": .red
        case "watch": .orange
        default: Brand.exercise
        }
    }
}
