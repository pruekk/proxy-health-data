import SwiftUI

/// The zones to glance at before heading out: five equal blocks and the heart rates that divide
/// them. Deliberately says nothing about today — what it is for is knowing that 137 to 150 is
/// the middle zone, which is a fact about the body rather than about this morning.
///
/// The boundaries are printed once each, under the edge they mark. A row of ranges would print
/// every number twice, and the 137 ending one zone is the 137 starting the next.
struct HeartRateZonesCard: View {
    let zones: ZonesDoc
    var placeholder = false
    @State private var explaining = false

    var body: some View {
        Card {
            HStack {
                Text("โซนหัวใจ").font(.system(size: 10.5, weight: .bold)).kerning(0.9).foregroundStyle(.secondary)
                Spacer()
                Button { explaining = true } label: {
                    Image(systemName: "info.circle").font(.system(size: 15)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                ForEach(zones.zones) { zone in
                    VStack(spacing: 3) {
                        Text("โซน \(zone.zone)")
                            .font(.system(size: 9.5, weight: .bold)).kerning(0.5)
                            .foregroundStyle(tint(zone.zone).opacity(0.75))
                        Text(zone.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tint(zone.zone))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(background(zone.zone), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.top, 12)

            boundaries.padding(.top, 7)
        }
        .sheet(isPresented: $explaining) { ReadinessInfoSheet(section: .zones) }
    }

    /// Each number sits under the edge it marks: the lower bound of the first zone at the left,
    /// then the upper bound of each zone at that block's right edge.
    private var boundaries: some View {
        HStack(spacing: 6) {
            ForEach(Array(zones.zones.enumerated()), id: \.offset) { index, zone in
                HStack(spacing: 0) {
                    if index == 0 {
                        Text("\(zone.from)").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("\(zone.to)").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Pastel fills, so the card reads as a reference rather than competing with the cards above.
    private func background(_ zone: Int) -> Color {
        if placeholder { return Brand.track }
        return switch zone {
        case 1: Color(red: 0.86, green: 0.90, blue: 0.96)
        case 2: Color(red: 0.86, green: 0.94, blue: 0.81)
        case 3: Color(red: 0.98, green: 0.93, blue: 0.77)
        case 4: Color(red: 0.98, green: 0.87, blue: 0.78)
        default: Color(red: 0.98, green: 0.84, blue: 0.82)
        }
    }

    private func tint(_ zone: Int) -> Color {
        if placeholder { return .clear }
        return switch zone {
        case 1: Color(red: 0.18, green: 0.31, blue: 0.51)
        case 2: Color(red: 0.24, green: 0.42, blue: 0.16)
        case 3: Color(red: 0.54, green: 0.42, blue: 0.08)
        case 4: Color(red: 0.60, green: 0.35, blue: 0.11)
        default: Color(red: 0.61, green: 0.23, blue: 0.20)
        }
    }
}
