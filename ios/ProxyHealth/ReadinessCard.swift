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
                // Says the number will not move on its own, which is the whole point of
                // computing it once at wake rather than on every app open.
                if let stamp { Text(stamp).font(.system(size: 10.5)).foregroundStyle(.tertiary) }
                if !readiness.missing.isEmpty {
                    Text("ขาด \(readiness.missingNames)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        .padding(.leading, 6)
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

    private var stamp: String? {
        guard let at = readiness.wakeTime ?? readiness.computedAt else { return nil }
        let time = at.formatted(date: .omitted, time: .shortened)
        let label = readiness.wakeTime == nil ? "คิดเมื่อ" : "คิดตอนตื่น"
        return readiness.locked == true ? "\(label) \(time) · คงที่ทั้งวัน" : "\(label) \(time)"
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

    /// Short label, bar, then the value with its change against your own normal. Targets and
    /// baselines live in the ⓘ sheet; four numbers on one line was too much to read at a glance.
    private func row(_ factor: ReadinessDoc.Factor) -> some View {
        HStack(spacing: 10) {
            Text(factor.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.track)
                    Capsule().fill(color(for: factor.direction))
                        .frame(width: max(4, geometry.size.width * Double(factor.score) / 100))
                }
            }
            .frame(height: 6)
            HStack(spacing: 0) {
                Text(measuredText(factor)).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                // Sleep shows time in bed next to time asleep, since that is the number people
                // remember; it is greyed because only the first one is scored.
                if let secondary = factor.secondary {
                    Text("/\(secondary)").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.tertiary).monospacedDigit()
                }
                if let change = changeText(factor) {
                    Text(" (\(change))").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 130, alignment: .trailing)
        }
    }

    private func changeText(_ factor: ReadinessDoc.Factor) -> String? {
        ReadinessFormat.change(percent: factor.changePercent)
    }

    private func measuredText(_ factor: ReadinessDoc.Factor) -> String {
        ReadinessFormat.value(key: factor.key, value: factor.value)
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
