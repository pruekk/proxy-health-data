import SwiftUI

/// What the readiness score is made of. Lives behind the ⓘ rather than on the card, but the
/// caveat matters: a score of 53 means nothing next to someone else's 53.
struct ReadinessInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Weight: Identifiable {
        let name: String
        let unit: String
        let percent: Int
        var id: String { name }
    }

    private let weights = [
        Weight(name: "HRV", unit: "ms — ยิ่งสูงยิ่งฟื้นตัวดี", percent: 30),
        Weight(name: "การนอน", unit: "ชั่วโมง:นาที ที่หลับจริง", percent: 30),
        Weight(name: "ชีพจรพัก", unit: "bpm — ยิ่งต่ำยิ่งดี", percent: 25),
        Weight(name: "โหลด 7 วัน", unit: "นาทีออกกำลังเฉลี่ยต่อวัน", percent: 15),
    ]

    private let bands = [
        ("0–34", "พักฟื้น", "ควรพัก หรือขยับเบา ๆ เท่านั้น", Color.red),
        ("35–54", "ระวัง", "เหมาะกับซ้อมเบาหรือพัก", Color.orange),
        ("55–79", "พร้อม", "ซ้อมตามแผนได้", Brand.exercise),
        ("80–100", "พร้อมมาก", "รับโหลดหนักได้", Color.green),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("คะแนน 0–100 จาก 4 ปัจจัย เทียบกับค่าฐาน 90 วันของคุณเอง ไม่ใช่ค่ามาตรฐานประชากร — เลข 53 ของคุณกับของคนอื่นจึงเทียบกันไม่ได้")
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)

                    section("สัดส่วนน้ำหนัก")
                    VStack(spacing: 11) {
                        ForEach(weights) { weight in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(weight.name).font(.system(size: 13, weight: .medium))
                                    Text(weight.unit).font(.system(size: 11)).foregroundStyle(.tertiary)
                                }
                                .frame(width: 128, alignment: .leading)
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Brand.track)
                                        Capsule().fill(Brand.gradient)
                                            .frame(width: geometry.size.width * Double(weight.percent) / 100)
                                    }
                                }
                                .frame(height: 7)
                                Text("\(weight.percent)%")
                                    .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                                    .frame(width: 38, alignment: .trailing)
                            }
                        }
                    }
                    Text("HRV กับชีพจรพักจับความเหนื่อยสะสมได้เร็วที่สุด การนอนถ่วงหนักเท่า HRV เพราะคืนเดียวเปลี่ยนวันถัดไปได้ทั้งวัน ส่วนโหลดเป็นบริบท ไม่ใช่อาการ เลยถ่วงน้อยสุด")
                        .font(.system(size: 12)).lineSpacing(3).foregroundStyle(.secondary).padding(.top, 12)

                    section("ระดับคะแนน")
                    VStack(spacing: 0) {
                        ForEach(bands, id: \.0) { range, label, advice, color in
                            HStack(spacing: 10) {
                                Circle().fill(color).frame(width: 7, height: 7)
                                Text(range).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                                    .frame(width: 58, alignment: .leading)
                                Text(label).font(.system(size: 12.5, weight: .semibold))
                                    .frame(width: 70, alignment: .leading)
                                Text(advice).font(.system(size: 12.5)).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8)
                            if range != bands.last?.0 { Divider() }
                        }
                    }

                    section("เมื่อข้อมูลไม่ครบ")
                    Text("คิดจากปัจจัยที่มี แล้วเฉลี่ยน้ำหนักใหม่ตามสัดส่วนเดิม เช่นถ้าไม่มีการนอน อีก 3 ตัวจะถูกปรับจาก 30/25/15 เป็น 43/36/21 — ต้องมีอย่างน้อย 2 ใน 4 ไม่งั้นจะไม่แสดงคะแนน")
                        .font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(.secondary)

                    section("ข้อจำกัด")
                    VStack(alignment: .leading, spacing: 7) {
                        bullet("ไม่มีมาตรฐานกลางสำหรับคะแนนแบบนี้ Whoop, Garmin, Oura ใช้สูตรต่างกันและไม่เปิดเผย น้ำหนักข้างบนเป็นการเลือกของเรา")
                        bullet("ค่าฐานต้องมีข้อมูลอย่างน้อย 2 วันถึงจะคำนวณได้ ช่วงแรกที่เพิ่งเริ่มใช้จะยังไม่นิ่ง")
                        bullet("ไม่ใช่คำแนะนำทางการแพทย์")
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 40)
            }
            .navigationTitle("วิธีคำนวณความพร้อมซ้อม")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("เสร็จ") { dismiss() } } }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .bold)).kerning(0.9)
            .foregroundStyle(.secondary)
            .padding(.top, 24).padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("•").font(.system(size: 12.5)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(.secondary)
        }
    }
}
