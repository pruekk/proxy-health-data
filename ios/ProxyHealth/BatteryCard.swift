import SwiftUI

/// How much is left right now. Readiness answers "should I train hard today"; this answers
/// "what is still in the tank". Everything comes from the server, constants included.
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

            gauge.padding(.top, 16)

            HStack(spacing: 10) {
                stat("+\(battery.chargedOvernight)%", "ชาร์จเมื่อคืน", .green)
                stat("−\(battery.drainedToday)%", "ใช้ไปวันนี้", .red)
            }
            .padding(.top, 14)

            // The comparison and the advice in one sentence, from the server, so the card and the
            // AI tools say the same thing.
            if let message = battery.message {
                Text(message)
                    .font(.system(size: 12.5)).lineSpacing(2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            if !battery.missing.isEmpty {
                Text("ยังขาด \(missingNames)")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 7)
            }
        }
        .sheet(isPresented: $explaining) { ReadinessInfoSheet(section: .battery) }
    }

    /// A battery outline with the level inside it, centred on the whole cell rather than the
    /// filled part, and the number and unit at the same size.
    private var gauge: some View {
        HStack(spacing: 3) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.track)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(placeholder ? AnyShapeStyle(Brand.track) : AnyShapeStyle(fillColor))
                        .frame(width: max(18, geometry.size.width * Double(battery.level) / 100))
                        .padding(2)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(battery.level)").font(.system(size: 25, weight: .bold)).monospacedDigit()
                        Text("%").font(.system(size: 25, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 58)
            Capsule().fill(Brand.track).frame(width: 5, height: 20)
        }
    }

    private var fillColor: LinearGradient {
        let colors: [Color] = switch battery.level {
        case ..<25: [.red.opacity(0.85), .red]
        case ..<50: [.orange.opacity(0.85), .orange]
        default: [Brand.exercise.opacity(0.85), Brand.exercise]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private func stat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 19, weight: .bold)).foregroundStyle(placeholder ? Color.secondary : tint)
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(Brand.plate, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var missingNames: String { BatteryFormat.missingNames(battery.missing) }
}
