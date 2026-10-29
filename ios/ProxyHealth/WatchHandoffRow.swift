import SwiftUI
import WorkoutKit

/// The last row of the "ครั้งต่อไป" card: whether this session is on the watch, and the one
/// action that applies. The plan is the content of the card; the watch is where it goes, so this
/// sits underneath rather than competing with the prescription.
struct WatchHandoffRow: View {
    let day: PlanDayDoc

    @Environment(AppModel.self) private var model
    @Environment(Dashboard.self) private var dashboard
    @State private var authorization: WorkoutScheduler.AuthorizationState?

    private var isOnWatch: Bool { dashboard.watchDates.contains(day.date) }

    /// Reading the authorization state costs an await, so until it arrives the row assumes the
    /// happy path rather than flashing "cannot send".
    private var isBlocked: Bool {
        !WorkoutExport.isSupported || (authorization != nil && authorization != .authorized)
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: state.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state.tint)
                .frame(width: 30, height: 30)
                .background(state.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(state.title).font(.system(size: 13, weight: .semibold))
                Text(state.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.top, 13)
        .overlay(alignment: .top) { Divider() }
        .task { authorization = await WorkoutExport.authorization }
    }

    @ViewBuilder private var action: some View {
        if dashboard.isSendingToWatch {
            ProgressView().controlSize(.small)
        } else if isBlocked {
            button("อนุญาต", prominent: false) {
                authorization = await WorkoutExport.requestAuthorization()
                if authorization == .authorized {
                    SyncState.watchExport = true
                    await dashboard.syncWatch(force: true)
                }
            }
        } else if isOnWatch {
            button("เอาออก", prominent: false) { await dashboard.clearWatch() }
        } else {
            button("ส่งเลย", prominent: true) {
                SyncState.watchExport = true
                await dashboard.syncWatch(force: true)
            }
        }
    }

    private func button(_ title: String, prominent: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Brand.blue : Color.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    (prominent ? Brand.blue : Color.secondary).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: What the row says

    private struct RowState {
        var symbol: String
        var tint: Color
        var title: String
        var detail: String
    }

    private var state: RowState {
        if !WorkoutExport.isSupported {
            return RowState(symbol: "minus", tint: .secondary,
                         title: "ส่งไม่ได้", detail: "เครื่องนี้ส่งแผนเข้านาฬิกาไม่ได้")
        }
        if let note = dashboard.watchNote {
            return RowState(symbol: "exclamationmark", tint: .orange, title: "ส่งไม่ได้", detail: note)
        }
        if authorization != nil && authorization != .authorized {
            return RowState(symbol: "minus", tint: .secondary,
                         title: "ส่งไม่ได้", detail: "ยังไม่ได้อนุญาตให้ส่งแผนเข้านาฬิกา")
        }
        if isOnWatch {
            return RowState(symbol: "checkmark", tint: .green,
                         title: "อยู่บน Apple Watch แล้ว", detail: onWatchDetail)
        }
        return RowState(symbol: "arrow.up", tint: Brand.blue,
                     title: "ยังไม่ได้ส่งเข้านาฬิกา",
                     detail: SyncState.watchExport ? "รอบซิงก์ถัดไปจะส่งให้" : "ปิดการส่งอัตโนมัติอยู่")
    }

    /// "ตั้งไว้ 06:30 น. · โครงครบ 65 นาที" — the time it was scheduled for and how much of the
    /// plan the watch is actually carrying.
    private var onWatchDetail: String {
        let minute = SyncState.watchStartMinuteOfDay
        var parts = [String(format: "ตั้งไว้ %02d:%02d น.", minute / 60, minute % 60)]
        if let minutes = day.plan?.totalMinutes, minutes > 0 {
            parts.append("โครงครบ \(minutes.formatted(0)) นาที")
        }
        return parts.joined(separator: " · ")
    }
}
