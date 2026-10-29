import SwiftUI

/// Shared look: soft cards on a recessed ground, a floating tab bar, ring gauges.
///
/// Every surface colour is resolved per trait collection. A fixed light grey ground would put
/// dark cards on a pale background in dark mode, which is exactly backwards.
enum Brand {
    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    /// Brand accents lift slightly in the dark so they stay legible on a near-black ground.
    static let teal = adaptive(light: (0.17, 0.70, 0.75), dark: (0.29, 0.80, 0.85))
    static let blue = adaptive(light: (0.18, 0.54, 0.74), dark: (0.36, 0.69, 0.90))
    static let indigo = adaptive(light: (0.34, 0.38, 0.69), dark: (0.50, 0.54, 0.86))
    static let move = adaptive(light: (0.95, 0.33, 0.29), dark: (1.00, 0.45, 0.40))
    static let exercise = adaptive(light: (0.56, 0.82, 0.29), dark: (0.66, 0.90, 0.38))
    static let stand = adaptive(light: (0.27, 0.78, 0.84), dark: (0.38, 0.86, 0.92))

    /// Behind the cards. Light: a shade below white. Dark: below the card, never above it.
    static let ground = adaptive(light: (0.92, 0.92, 0.93), dark: (0.05, 0.05, 0.06))
    /// The cards themselves, a step lighter than the ground in dark mode.
    static let card = adaptive(light: (1, 1, 1), dark: (0.11, 0.11, 0.12))
    /// The track a ring is drawn on.
    static let track = adaptive(light: (0.94, 0.94, 0.95), dark: (0.17, 0.17, 0.19))
    /// The neutral plate behind a row icon.
    static let plate = adaptive(light: (0.953, 0.953, 0.965), dark: (0.17, 0.17, 0.19))

    static let gradient = LinearGradient(colors: [teal, indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct Card<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    /// Rows bring their own 13pt of vertical padding, so a card full of them insets by 3 to land
    /// on the same 16 as everything else (mockup: `.row:first-child{padding-top:2px}`).
    var vertical: CGFloat = 16
    var horizontal: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.vertical, vertical)
            .padding(.horizontal, horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            // Shadows do nothing against a near-black ground, so dark mode leans on the card
            // being lighter than what is behind it instead.
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.06), radius: 14, x: 0, y: 8)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.03), radius: 2, x: 0, y: 1)
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
        .padding(.top, 26)
        .padding(.bottom, 10)
    }
}

/// A single activity ring with its percentage in the middle.
struct Ring: View {
    let value: Double
    let goal: Double
    let color: Color
    let name: String
    let detail: String

    private var fraction: Double { Trends.fraction(value: value, goal: goal) }
    private var percent: Int { Trends.percent(value: value, goal: goal) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().stroke(Brand.track, lineWidth: 11)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(percent)%").font(.system(size: 19, weight: .bold)).monospacedDigit()
            }
            .frame(width: 84, height: 84)
            // 13 rather than the tile's 6: the dial's bottom edge is a curve, so the same
            // numeric gap reads as tighter than it does under a flat line of text.
            Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.top, 13)
            Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 1)
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
    var symbol: String?
    var tint: Color = Brand.blue

    var body: some View {
        Card(vertical: 14, horizontal: 14) {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(tint)
                }
                Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 26, weight: .bold)).monospacedDigit()
                if let unit { Text(unit).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary) }
            }
            .padding(.top, 10)
            .fixedSize(horizontal: false, vertical: true)
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
    /// Renders `detail` as a tinted pill — used for changes like "−1.9 kg / 90 วัน".
    var detailStyle: DetailStyle = .plain
    var tint: Color = Brand.blue
    var showsChevron = false

    enum DetailStyle { case plain, good, bad, warning }

    private var detailColor: Color {
        switch detailStyle {
        case .plain: .secondary
        case .good: .green
        case .bad: .red
        case .warning: .orange
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Brand.plate, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14.5, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5, weight: detailStyle == .plain ? .regular : .semibold))
                        .foregroundStyle(detailColor)
                        .padding(.horizontal, detailStyle == .plain ? 0 : 6)
                        .padding(.vertical, detailStyle == .plain ? 0 : 2)
                        .background(detailStyle == .plain ? .clear : detailColor.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            if showsChevron {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 13)
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
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 20, x: 0, y: 10)
        .padding(.horizontal, 18)
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case latest, calendar, history, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .latest: "ล่าสุด"
        case .calendar: "ปฏิทิน"
        case .history: "ประวัติ"
        case .settings: "ตั้งค่า"
        }
    }
    /// Which tab the app opens on. A simulator run can ask for one by name, so a screen can be
    /// put in front of a camera without synthesising taps:
    ///   xcrun simctl launch booted <bundle id> -tab calendar
    static var launchDefault: AppTab {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "tab"), let tab = AppTab(rawValue: name) {
            return tab
        }
        #endif
        return .latest
    }

    var symbol: String {
        switch self {
        case .latest: "house.fill"
        case .calendar: "calendar"
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

extension Int {
    /// Grouped for reading: 68000 -> "68,000".
    func formatted(_ decimals: Int = 0) -> String { Double(self).formatted(decimals) }
}

extension Date {
    /// "3 นาทีที่แล้ว", "เมื่อวาน", "15 ต.ค."
    var relativeThai: String { RelativeThai.describe(self) }
}
