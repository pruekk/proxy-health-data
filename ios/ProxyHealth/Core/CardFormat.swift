import Foundation

/// Number and label formatting for the readiness and battery cards. Pure, so the exact strings
/// on screen — the minus sign, the colon, the Thai names — are unit tested rather than eyeballed
/// in the simulator.
public enum ReadinessFormat {
    /// "+2%", "−24%", "±0%". A typographic minus rather than a hyphen, to match the design, and
    /// a plus-minus at zero so the row never reads as if the change were positive.
    public static func change(percent: Double?) -> String? {
        guard let percent else { return nil }
        let rounded = Int(percent.rounded())
        let sign = rounded > 0 ? "+" : rounded < 0 ? "−" : "±"
        return "\(sign)\(abs(rounded))%"
    }

    /// Minutes as h:mm. Sleep is read as a duration, not as 304 minutes.
    public static func clock(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    /// The measured value with the unit the factor is read in.
    public static func value(key: String, value: Double) -> String {
        switch key {
        case "hrv": "\(round(value, 1)) ms"
        case "restingHeartRate": "\(round(value, 0)) bpm"
        case "sleep": clock(value)
        case "load": "\(round(value, 0)) นาที"
        default: round(value, 1)
        }
    }

    /// Thai names for the short labels used on the card.
    public static func thaiName(_ key: String) -> String {
        switch key {
        case "hrv": "ความแปรปรวนจังหวะหัวใจ"
        case "restingHeartRate": "ชีพจรขณะพัก"
        case "sleep": "เวลาที่หลับจริง"
        case "load": "โหลดการซ้อม 7 วัน"
        default: key
        }
    }

    private static func round(_ value: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", value)
    }
}

public enum BatteryFormat {
    /// What the server reports as missing, in words. An unknown key is passed through rather
    /// than dropped, so a new input added server-side is visible instead of silently ignored.
    public static func missingNames(_ keys: [String]) -> String {
        keys.map {
            switch $0 {
            case "sleep": "การนอนคืนล่าสุด"
            case "restingHeartRate": "ชีพจรขณะพัก"
            case "hourly": "ข้อมูลรายชั่วโมงของวันนี้"
            default: $0
            }
        }
        .joined(separator: ", ")
    }
}
