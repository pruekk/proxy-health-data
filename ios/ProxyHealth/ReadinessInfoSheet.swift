import SwiftUI

/// What the readiness score is made of. Lives behind the ⓘ rather than on the card, but the
/// caveat matters: a score of 53 means nothing next to someone else's 53.
struct ReadinessInfoSheet: View {
    enum Section { case readiness, battery }

    var section: Section = .readiness
    @Environment(\.dismiss) private var dismiss

    private struct Weight: Identifiable {
        let name: String
        let unit: String
        let percent: Int
        var id: String { name }
    }

    // Same abbreviations as the card, with the Thai meaning underneath, so the row labels are
    // never a guess.
    private let weights = [
        Weight(name: "HRV", unit: "ความแปรปรวนจังหวะหัวใจ", percent: 30),
        Weight(name: "Sleep", unit: "เวลาที่หลับจริง", percent: 30),
        Weight(name: "RHR", unit: "ชีพจรขณะพัก", percent: 25),
        Weight(name: "Load", unit: "โหลดการซ้อม 7 วัน", percent: 15),
    ]

    private struct Glossary: Identifiable {
        let name: String
        let meaning: String
        let against: String
        let target: String
        var id: String { name }
    }

    private var glossary: [Glossary] {
        let target = AppConfig.sleepTargetMinutes
        return [
            .init(name: "HRV", meaning: "ความแปรปรวนจังหวะหัวใจ · สูง = ฟื้นตัวดี",
                  against: "เทียบค่าเฉลี่ย 90 วันของคุณ", target: "ค่าฐานของคุณเอง"),
            .init(name: "RHR", meaning: "ชีพจรขณะพัก · ต่ำ = ฟื้นตัวดี",
                  against: "เทียบค่าเฉลี่ย 90 วันของคุณ", target: "ค่าฐานของคุณเอง"),
            .init(name: "Sleep", meaning: "เวลาที่หลับจริง ไม่ใช่เวลาบนเตียง",
                  against: "เทียบเป้าหมายคงที่", target: "\(target / 60):\(String(format: "%02d", target % 60))"),
            .init(name: "Load", meaning: "นาทีออกกำลังเฉลี่ยต่อวัน",
                  against: "เทียบค่าเฉลี่ย 90 วันของคุณ", target: "ค่าฐานของคุณเอง"),
        ]
    }

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
                    if section == .battery { batteryContent } else { readinessContent }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 40)
            }
            .navigationTitle(section == .battery ? "วิธีคำนวณพลังงานร่างกาย" : "วิธีคำนวณความพร้อมซ้อม")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("เสร็จ") { dismiss() } } }
        }
    }

    private var batteryContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("พลังงานที่เหลืออยู่ตอนนี้ 0–100 ระหว่างนอนจะค่อย ๆ ไต่ขึ้นตามชั่วโมงที่หลับจริง โดยเริ่มจากระดับตอนเข้านอน จากนั้นระหว่างวันลดลงตามกิจกรรมและชีพจรที่สูงกว่าค่าพัก")
                .font(.system(size: 13.5)).lineSpacing(3).foregroundStyle(.secondary)

            section("คิดยังไง")
            VStack(alignment: .leading, spacing: 9) {
                formulaRow("ชาร์จตอนนอน", "+6 ต่อชั่วโมงที่หลับจริง · เข้านอน 40% + นอน 6:19 = ตื่นมา 78%")
                formulaRow("ยกยอด", "เริ่มจากระดับตอนเข้านอน คืนเดียวไม่เติมเต็มถ้าวันก่อนหมดแรง")
                formulaRow("งีบกลางวัน", "ชาร์จอัตราเดียวกัน แต่สูงสุด 15 ต่อครั้ง และ 20 ต่อวัน")
                formulaRow("ใช้พื้นฐาน", "−1 ต่อชั่วโมงที่ตื่น")
                formulaRow("ใช้จากกิจกรรม", "แคลอรีแอคทีฟ ÷ 30 · วิ่ง 600 kcal = −20")
                formulaRow("ใช้จากชีพจรสูง", "(ชีพจรเฉลี่ย − ชีพจรพัก − 15) ÷ 14 ต่อชั่วโมง")
                formulaRow("ชาร์จตอนพัก", "+1.5 ต่อชั่วโมงที่ชีพจรใกล้ค่าพักและแทบไม่ขยับ")
            }

            section("แถบอ่านยังไง")
            VStack(alignment: .leading, spacing: 7) {
                bullet("ช่องสว่าง คือพลังงานที่เหลืออยู่ตอนนี้")
                bullet("ช่องเทา คือส่วนที่ใช้ไปแล้ววันนี้ — นับจากตอนตื่น")
                bullet("ช่องจาง คือส่วนที่เมื่อคืนชาร์จไม่ถึง")
                bullet("ป้าย \"ประมาณ\" ขึ้นเมื่อคืนนั้นไม่มีข้อมูลการนอน (เช่น ไม่ได้ใส่นาฬิกา) ระบบจะใช้ค่ากลางของ 14 คืนล่าสุดแทน")
            }

            section("ข้อจำกัด")
            VStack(alignment: .leading, spacing: 7) {
                bullet("Garmin ใช้ HRV แบบจังหวะต่อจังหวะตลอดวัน ซึ่ง Apple Watch ไม่เปิดให้เข้าถึง ของเราจึงประมาณจากชีพจรเทียบค่าพักและแคลอรีแทน ตัวเลขจะไม่ตรงกับ Body Battery ของ Garmin")
                bullet("ข้อมูลรายชั่วโมงเริ่มเก็บเมื่อไม่นานมานี้ ช่วงแรกการเทียบกับ \"ปกติของเวลานี้\" จะยังไม่นิ่ง")
                bullet("ไม่ใช่คำแนะนำทางการแพทย์")
            }
        }
    }

    private func formulaRow(_ name: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(name).font(.system(size: 12.5, weight: .semibold)).frame(width: 118, alignment: .leading)
            Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var readinessContent: some View {
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

                    section("เทียบกับอะไร")
                    VStack(spacing: 0) {
                        ForEach(glossary) { item in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.system(size: 12.5, weight: .semibold))
                                    Text(item.meaning).font(.system(size: 11)).foregroundStyle(.secondary)
                                    Text(item.against).font(.system(size: 11)).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 8)
                                Text(item.target)
                                    .font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                            .padding(.vertical, 9)
                            if item.id != glossary.last?.id { Divider() }
                        }
                    }
                    Text("Sleep คิดจากเวลาที่หลับจริง ไม่ใช่เวลาที่อยู่บนเตียง สองค่านี้ต่างกันปกติ 1–2 ชั่วโมง การ์ดจึงแสดง หลับจริง/บนเตียง คู่กัน")
                        .font(.system(size: 12)).lineSpacing(3).foregroundStyle(.secondary).padding(.top, 12)
                    Text("Load คือสัดส่วนนาทีออกกำลังเฉลี่ย 7 วันล่าสุด ต่อค่าเฉลี่ย 90 วัน (acute:chronic ratio) ช่วง 0.8–1.3 เท่าได้คะแนนเต็ม สูงกว่านั้นคือซ้อมพุ่งเร็วเกินตัว ต่ำกว่าคือซ้อมน้อยลง ซึ่งหักคะแนนเบากว่า")
                        .font(.system(size: 12)).lineSpacing(3).foregroundStyle(.secondary).padding(.top, 8)

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

                    section("ทำไมเลขไม่ขยับระหว่างวัน")
                    Text("คะแนนนี้ตอบว่า \"เช้านี้ร่างกายพร้อมแค่ไหน\" จึงคิดครั้งเดียวตอนตื่นแล้วล็อกไว้ทั้งวัน ทันทีที่ได้ครบทั้งการนอน HRV และชีพจรพัก ถ้าข้อมูลยังมาไม่ครบจะคิดใหม่ไปเรื่อย ๆ แล้วล็อกเท่าที่มีตอนเที่ยง — เปิดแอปกี่ครั้งก็เห็นเลขเดิม และ AI ก็อ่านเลขเดียวกัน")
                        .font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(.secondary)

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
