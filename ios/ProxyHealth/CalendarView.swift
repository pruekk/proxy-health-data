import SwiftUI

/// Tab two: a month at a glance of what was planned and what was done, and the next session in
/// full. The plan itself is written by the coach in the chat through MCP — nothing on this
/// screen edits it, which is also why the past needs no "edit" affordance anywhere.
struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @Environment(Dashboard.self) private var dashboard

    /// The first of the month on screen, in the server's local days rather than the device's.
    @State private var month = PlanMonth.current
    @State private var selected: PlanDayDoc?

    /// Only the month on screen. Holding on to the previous month's answer would paint its
    /// sessions onto this month's squares for as long as the fetch takes.
    private var range: PlanRangeDoc? {
        guard let plan = dashboard.plan, plan.from == month.from else { return nil }
        return plan
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                weekdays
                grid
                legend
                upNext
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 110)
        }
        .background(Brand.ground)
        .refreshable { await dashboard.loadPlan(settings: model.settings, month: month, force: true) }
        .task(id: month.key) {
            await dashboard.loadPlan(settings: model.settings, month: month)
            await dashboard.syncWatch()
            await dashboard.refreshWatchDates()
        }
        .sheet(item: $selected) { day in
            PlanDaySheet(day: day, today: range?.today ?? "")
        }
    }

    // MARK: Head

    private var header: some View {
        HStack(spacing: 10) {
            Text(month.title).font(.system(size: 20, weight: .bold))
            Spacer()
            stepper("chevron.left") { month = month.shifted(by: -1) }
            stepper("chevron.right") { month = month.shifted(by: 1) }
        }
        .padding(.horizontal, 2)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func stepper(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var weekdays: some View {
        HStack(spacing: 2) {
            ForEach(["อา", "จ", "อ", "พ", "พฤ", "ศ", "ส"], id: \.self) { name in
                Text(name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: Grid

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
            // The leading blanks keep the first of the month under its own weekday.
            ForEach(0..<month.leadingBlanks, id: \.self) { _ in Color.clear.frame(height: 54) }
            ForEach(month.dates, id: \.self) { date in
                let day = dayFor(date)
                PlanDayCell(
                    number: month.dayNumber(of: date),
                    day: day,
                    isToday: date == range?.today
                )
                .onTapGesture { if day != nil { selected = day } }
            }
        }
        .redacted(reason: range == nil ? .placeholder : [])
    }

    private func dayFor(_ date: String) -> PlanDayDoc? {
        range?.days.first { $0.date == date }
    }

    /// The pills name themselves, so what needs a key is the four states, which are shape.
    private var legend: some View {
        HStack(spacing: 12) {
            legendItem { PlanPillShape.planned.swatch(color: .secondary) } label: { Text("แผน") }
            legendItem { PlanPillShape.missed.swatch(color: Color(.tertiaryLabel)) } label: { Text("ไม่ได้ทำ") }
            legendItem { Text("⇄").font(.system(size: 11)) } label: { Text("ทำคนละแบบ") }
            legendItem { Circle().fill(PlanPalette.harder).frame(width: 7, height: 7) } label: { Text("หนักกว่าแผน") }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
    }

    private func legendItem<Mark: View, Label: View>(
        @ViewBuilder mark: () -> Mark, @ViewBuilder label: () -> Label
    ) -> some View {
        HStack(spacing: 5) { mark(); label() }
    }

    // MARK: Next up

    /// The first planned day from today onwards, shown in full so the screen answers "what am I
    /// doing next" without a tap.
    private var next: PlanDayDoc? {
        guard let range else { return nil }
        return range.days.first { $0.date >= range.today && $0.plan != nil }
    }

    @ViewBuilder private var upNext: some View {
        if let next, let plan = next.plan {
            SectionTitle(text: "ครั้งต่อไป", hint: PlanFormat.dayLabel(next.date))
            Card {
                PlanPrescription(plan: plan)
                WatchHandoffRow(day: next)
            }
        } else if range != nil {
            SectionTitle(text: "ครั้งต่อไป")
            Card {
                Text("ยังไม่มีแผนข้างหน้า")
                    .font(.system(size: 14, weight: .semibold))
                Text("ขอให้โค้ชในแชทวางแผนให้ — แผนเขียนได้เฉพาะวันนี้เป็นต้นไป")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - One square

/// A day in the grid: its number, and a pill saying what the day was. Colour is the kind of
/// session; shape is whether it was planned, done, swapped or missed.
private struct PlanDayCell: View {
    let number: Int
    let day: PlanDayDoc?
    let isToday: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text("\(number)")
                .font(.system(size: 12.5, weight: isToday ? .bold : .semibold))
                .foregroundStyle(isToday ? Brand.blue : .primary)
            if let mark {
                mark.shape.pill(text: mark.text, color: mark.color)
            } else {
                Color.clear.frame(height: 13)
            }
            if day?.harder == true {
                Circle().fill(PlanPalette.harder).frame(width: 5, height: 5)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .top)
        .padding(.top, 4)
        .background(
            isToday ? Brand.blue.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            if isToday {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Brand.blue, lineWidth: 1.5)
            }
        }
        .contentShape(.rect)
    }

    /// What the square shows. A day that was carried out names the session that happened; a day
    /// still ahead, or one that was not carried out, names the plan. Swapping those over is what
    /// would make the month lie about itself.
    private var mark: (text: String, color: Color, shape: PlanPillShape)? {
        guard let day else { return nil }
        let planned = day.plan?.kind
        switch day.state {
        case .planned:
            return planned.map { ($0.short, PlanPalette.color($0), PlanPillShape.planned) }
        case .missed:
            return planned.map { ($0.short, PlanPalette.color($0), PlanPillShape.missed) }
        case .done, .rest:
            return planned.map { ($0.short, PlanPalette.color($0), PlanPillShape.done) }
        case .different:
            return actualMark.map { ($0.text, $0.color, PlanPillShape.swapped) }
        case .unplanned:
            return actualMark.map { ($0.text, $0.color, PlanPillShape.done) }
        case .none:
            return nil
        }
    }

    /// A recorded session has no intensity the server can know about, so it is named by what it
    /// was rather than by a plan type it never had.
    private var actualMark: (text: String, color: Color)? {
        guard let name = day?.workouts.first?.activityTypeName else { return nil }
        let running = name.localizedCaseInsensitiveContains("run")
        return running
            ? ("วิ่ง", PlanPalette.color(.easy))
            : (PlanActivity.short(name), PlanPalette.color(.cross))
    }
}

/// Short Thai names for the activities that turn up most, so a swapped day says what it was
/// instead of "Other".
enum PlanActivity {
    static func short(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("climb") { return "ปีนผา" }
        if lower.contains("cycl") || lower.contains("bik") { return "ปั่น" }
        if lower.contains("swim") { return "ว่ายน้ำ" }
        if lower.contains("walk") || lower.contains("hik") { return "เดิน" }
        if lower.contains("strength") || lower.contains("training") { return "เวท" }
        if lower.contains("yoga") { return "โยคะ" }
        return "ครอส"
    }
}

/// The four shapes a pill can take, kept in one place because the legend and the grid have to
/// agree about them exactly.
enum PlanPillShape {
    case done, planned, missed, swapped

    @ViewBuilder func pill(text: String, color: Color) -> some View {
        switch self {
        case .done:
            label(text).foregroundStyle(.white)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .planned:
            label(text).foregroundStyle(color).overlay(dashes(color))
        case .swapped:
            label(text).foregroundStyle(.white)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(alignment: .topTrailing) { swapBadge.offset(x: 5, y: -6) }
        case .missed:
            label(text)
                .foregroundStyle(Color(.tertiaryLabel))
                .strikethrough(true, color: Color(.tertiaryLabel))
                .overlay(dashes(Color(.tertiaryLabel)))
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 7.5, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 32, height: 13)
    }

    private func dashes(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(color, style: StrokeStyle(lineWidth: 1.3, dash: [2.5, 2]))
    }

    private var swapBadge: some View {
        Text("⇄")
            .font(.system(size: 7))
            .foregroundStyle(.primary)
            .frame(width: 12, height: 12)
            .background(Brand.card, in: Circle())
            .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }

    /// The legend's miniature, with no text in it.
    @ViewBuilder func swatch(color: Color) -> some View {
        switch self {
        case .planned, .missed:
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(color, style: StrokeStyle(lineWidth: 1.3, dash: [2.5, 2]))
                .frame(width: 14, height: 9)
        case .done, .swapped:
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color).frame(width: 14, height: 9)
        }
    }
}

/// One colour per kind of session, so a glance at the month reads as a pattern of effort.
enum PlanPalette {
    static let harder = Color(red: 0.82, green: 0.21, blue: 0.17)

    static func color(_ kind: PlanKind) -> Color {
        switch kind {
        case .easy: Color(red: 0.42, green: 0.75, blue: 0.23)
        case .marathon: Color(red: 0.85, green: 0.62, blue: 0.20)
        case .threshold: Color(red: 0.91, green: 0.52, blue: 0.24)
        case .interval: Color(red: 0.88, green: 0.27, blue: 0.23)
        case .repetition: Color(red: 0.72, green: 0.25, blue: 0.55)
        case .long: Color(red: 0.18, green: 0.48, blue: 1.00)
        case .cross: Color(red: 0.17, green: 0.70, blue: 0.64)
        case .rest: Color(.systemGray)
        }
    }
}

// MARK: - The prescription

/// A plan written out as steps — the left column says how much, the right says what and at what
/// pace. Everything shown here was chosen by the coach; nothing is derived on the device.
struct PlanPrescription: View {
    let plan: PlanDoc

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(plan.kind.short) · \(plan.kind.title)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(PlanPalette.color(plan.kind))
                Spacer()
                if let summary { Text(summary).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }

            if plan.kind == .rest {
                Text(plan.kind.purpose)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array((plan.steps ?? []).enumerated()), id: \.offset) { index, step in
                    if index > 0 { Divider() }
                    stepRow(step)
                }
            }

            if let note = plan.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
        }
    }

    /// "รวม 65 นาที · ราว 6 กม." — whichever of the two the coach gave.
    private var summary: String? {
        var parts: [String] = []
        if let minutes = plan.totalMinutes, minutes > 0 { parts.append("รวม \(minutes.formatted(0)) นาที") }
        if let km = plan.targetDistanceKm, km > 0 { parts.append("ราว \(km.formatted(1)) กม.") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func stepRow(_ step: PlanDoc.Step) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(step.amountLabel)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline(step)).font(.system(size: 12.5, weight: .semibold))
                if let detail = subtitle(step) {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
    }

    /// The phase, and the pace when there is one — the one line that has to be readable mid-run.
    private func headline(_ step: PlanDoc.Step) -> String {
        if let pace = step.paceLabel { return "\(step.phaseLabel) · \(pace)" }
        return step.phaseLabel
    }

    private func subtitle(_ step: PlanDoc.Step) -> String? {
        var parts: [String] = []
        if let zone = step.zone { parts.append("โซน \(zone)") }
        if let detail = step.detail, !detail.isEmpty { parts.append(detail) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - A month of local days

/// The grid's month. Days are the server's `yyyy-MM-dd` strings throughout, so a device in
/// another time zone still highlights the same "today" the plan was written against.
struct PlanMonth: Equatable, Sendable {
    var year: Int
    var month: Int

    static var current: PlanMonth {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        return PlanMonth(year: parts.year ?? 2026, month: parts.month ?? 1)
    }

    var key: String { String(format: "%04d-%02d", year, month) }

    /// Buddhist-era month and year, matching the rest of the app's dates.
    var title: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "th_TH")
        formatter.dateFormat = "MMMM y"
        return first.map { formatter.string(from: $0) } ?? key
    }

    var from: String { "\(key)-01" }
    var to: String { String(format: "%@-%02d", key, length) }

    func shifted(by months: Int) -> PlanMonth {
        let zero = (year * 12 + month - 1) + months
        return PlanMonth(year: zero / 12, month: zero % 12 + 1)
    }

    /// Every day in the month, as keys.
    var dates: [String] { (1...length).map { String(format: "%@-%02d", key, $0) } }

    func dayNumber(of date: String) -> Int { Int(date.suffix(2)) ?? 0 }

    /// Sunday-first, matching the weekday header.
    var leadingBlanks: Int {
        guard let first else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.component(.weekday, from: first) - 1
    }

    var length: Int {
        guard let first else { return 30 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.range(of: .day, in: .month, for: first)?.count ?? 30
    }

    private var first: Date? { PlanFormat.day("\(key)-01") }
}
