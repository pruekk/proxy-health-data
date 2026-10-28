import SwiftUI

/// One group's window, with what is in it and what the choice costs.
///
/// The numbers matter more than the options here: a group holding 232 documents and one holding
/// 68,000 deserve different answers, and nobody can give one without being told which is which.
struct RetentionGroupSheet: View {
    let group: RetentionGroup
    let current: Int
    let metrics: [MetricSummary]
    let onPick: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int

    init(group: RetentionGroup, current: Int, metrics: [MetricSummary], onPick: @escaping (Int) -> Void) {
        self.group = group
        self.current = current
        self.metrics = metrics
        self.onPick = onPick
        _selection = State(initialValue: current)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.summary).font(.system(size: 13.5)).foregroundStyle(.secondary)

                    Picker("", selection: $selection) {
                        ForEach(group.options, id: \.self) { option in
                            Text(group.label(option)).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 14)

                    Text(group.note)
                        .font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(.secondary)
                        .padding(.top, 14)

                    if !metrics.isEmpty {
                        Text("ที่เก็บอยู่ตอนนี้").font(.system(size: 10.5, weight: .bold)).kerning(0.9)
                            .foregroundStyle(.secondary).padding(.top, 24).padding(.bottom, 4)
                        VStack(spacing: 0) {
                            ForEach(metrics) { metric in
                                HStack {
                                    Text(name(metric.type)).font(.system(size: 13))
                                    Spacer()
                                    Text((metric.count ?? 0).formatted(0))
                                        .font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 9)
                                if metric.id != metrics.last?.id { Divider() }
                            }
                        }
                    }

                    Text("ต้นฉบับอยู่ที่ Apple Health เสมอ — ลบไปแล้วกดซิงก์ใหม่ทั้งหมดเพื่อดึงกลับได้ เท่าที่ Health ยังเก็บไว้")
                        .font(.system(size: 11.5)).lineSpacing(3).foregroundStyle(.tertiary)
                        .padding(.top, 22)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 40)
            }
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("ยกเลิก") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("บันทึก") { onPick(selection) }.disabled(selection == current)
                }
            }
        }
    }

    /// Thai names come from the catalog where there is one, so a new metric is named server-side.
    private func name(_ type: String) -> String {
        let display = AppConfig.display
        let rows = display.body + display.vitals + display.coverage
        return rows.first { $0.key == type }?.name ?? type
    }
}
