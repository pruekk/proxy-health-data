import SwiftUI

/// Shared look: soft white cards on a light ground, a floating tab bar, ring gauges.
enum Brand {
    static let teal = Color(red: 0.17, green: 0.70, blue: 0.75)
    static let blue = Color(red: 0.18, green: 0.54, blue: 0.74)
    static let indigo = Color(red: 0.34, green: 0.38, blue: 0.69)
    static let ground = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let move = Color(red: 0.95, green: 0.33, blue: 0.29)
    static let exercise = Color(red: 0.56, green: 0.82, blue: 0.29)
    static let stand = Color(red: 0.27, green: 0.78, blue: 0.84)
    static let gradient = LinearGradient(colors: [teal, indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 8)
            .shadow(color: .black.opacity(0.03), radius: 2, x: 0, y: 1)
    }
}

struct SectionTitle: View {
    let text: String
    var hint: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.system(size: 17, weight: .bold))
            Spacer()
            if let hint { Text(hint).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 2)
        .padding(.top, 10)
    }
}

/// A single activity ring with its percentage in the middle.
struct Ring: View {
    let value: Double
    let goal: Double
    let color: Color
    let name: String
    let detail: String

    private var fraction: Double { goal > 0 ? min(value / goal, 1) : 0 }
    private var percent: Int { goal > 0 ? Int((value / goal * 100).rounded()) : 0 }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle().stroke(Color(.systemGray6), lineWidth: 11)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(percent)%").font(.system(size: 19, weight: .bold)).monospacedDigit()
            }
            .frame(width: 84, height: 84)
            Text(name).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Two-up tile: label, big value, a line of context.
struct Tile: View {
    let label: String
    let value: String
    var unit: String?
    var meta: String?
    var tint: Color = Brand.blue

    var body: some View {
        Card {
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 26, weight: .bold)).monospacedDigit()
                if let unit { Text(unit).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary) }
            }
            .padding(.top, 10)
            if let meta { Text(meta).font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.top, 6) }
        }
    }
}

/// A row inside a card: icon, title, subtitle, trailing value.
struct MetricRow: View {
    let symbol: String
    let title: String
    var subtitle: String?
    let value: String
    var detail: String?
    var tint: Color = Brand.blue
    var showsChevron = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14.5, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            if showsChevron {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 9)
    }
}

struct Divided<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            content
        }
    }
}

/// The floating pill at the bottom.
struct FloatingTabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol).font(.system(size: 19, weight: .medium))
                        Text(tab.title).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(selection == tab ? Brand.blue : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 20, x: 0, y: 10)
        .padding(.horizontal, 18)
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case latest, history, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .latest: "ล่าสุด"
        case .history: "ประวัติ"
        case .settings: "ตั้งค่า"
        }
    }
    var symbol: String {
        switch self {
        case .latest: "house.fill"
        case .history: "clock"
        case .settings: "gearshape"
        }
    }
}

extension Double {
    /// Trims the float tail for display: 75.349998 -> "75.3", 10706.0 -> "10,706".
    func formatted(_ decimals: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = decimals
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: self)) ?? String(self)
    }
}

extension Date {
    /// "3 นาทีที่แล้ว", "เมื่อวาน", "15 ต.ค."
    var relativeThai: String {
        let seconds = Date().timeIntervalSince(self)
        if seconds < 90 { return "เมื่อครู่" }
        if seconds < 3600 { return "\(Int(seconds / 60)) นาทีที่แล้ว" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) ชม.ที่แล้ว" }
        let days = Int(seconds / 86_400)
        if days == 1 { return "เมื่อวาน" }
        if days < 30 { return "\(days) วันก่อน" }
        return formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "th_TH")))
    }
}
