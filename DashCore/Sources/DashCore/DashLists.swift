import Foundation

/// Danh sách gốc của đồng hồ (docs/protocol/link-a-dash.md, "Lists (favourites, fuel)").
/// Enter / giữ Enter không tới điện thoại; menu gốc của đồng hồ mở danh sách 3 (yêu thích) và 4 (trạm xăng).
public enum DashList {
    public static let favourites = 3
    public static let fuel = 4
    /// Tối đa 30 mục mỗi danh sách.
    public static let maxItems = 30
    public static let maxNameBytes = 128
}

/// Một mục để gửi cho đồng hồ.
public struct DashListItem: Equatable {
    public var name: String
    /// Khoảng cách tính bằng mét (0 nếu chưa có vị trí).
    public var distanceMeters: Double
    /// 0 = không có hướng, 1…8 = B, ĐB, Đ, ĐN, N, TN, T, TB.
    public var octant: UInt8

    public init(name: String, distanceMeters: Double, octant: UInt8 = 0) {
        self.name = name
        self.distanceMeters = distanceMeters
        self.octant = octant
    }
}

public enum DashLists {
    /// Hướng la bàn (độ, 0 = Bắc, theo chiều kim đồng hồ) → 1…8 (1 = N, 2 = NE, … 8 = NW).
    public static func octant(bearingDeg: Double) -> UInt8 {
        var b = bearingDeg.truncatingRemainder(dividingBy: 360)
        if b < 0 { b += 360 }
        let slot = Int((b + 22.5) / 45) % 8
        return UInt8(slot + 1)
    }

    /// Góc phương vị (độ) từ điểm 1 tới điểm 2.
    public static func bearing(fromLat lat1: Double, lon lon1: Double, toLat lat2: Double, lon lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        var deg = atan2(y, x) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }

    /// Mét → (giá trị, đơn vị): dưới 1 km hiện "m" làm tròn, từ 1 km hiện "km" một số lẻ.
    public static func formatDistance(meters: Double) -> (value: Float, unit: String) {
        let m = max(0, meters)
        if m < 1000 { return (Float(m.rounded()), "m") }
        return (Float((m / 100).rounded() / 10), "km")
    }

    /// Toàn bộ khung của một danh sách: số lượng (7 / 8) rồi từng mục (98 / 99). Tối đa 30 mục.
    public static func frames(listId: Int, items: [DashListItem]) -> [Frame] {
        let used = Array(items.prefix(DashList.maxItems))
        var out = [PhoneCommand.listCount(listId: listId, count: used.count)]
        for (i, item) in used.enumerated() {
            let d = formatDistance(meters: item.distanceMeters)
            out.append(PhoneCommand.listItem(listId: listId, index: i, octant: item.octant,
                                             name: item.name, distance: d.value, unit: d.unit))
        }
        return out
    }
}

public extension PhoneCommand {
    private static func f32le(_ value: Float) -> [UInt8] {
        let bits = value.bitPattern
        return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8(bits >> 24)]
    }

    /// Số mục của danh sách: lệnh 7 (yêu thích, listId 3) hoặc 8 (trạm xăng, listId 4); flag 1, `[n lo, n hi, 00]`, n ≤ 30.
    static func listCount(listId: Int, count: Int) -> Frame {
        let n = max(0, min(DashList.maxItems, count))
        return Frame(command: listId == DashList.favourites ? 7 : 8, flag: 1,
                     payload: [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), 0])
    }

    /// Một mục: lệnh 98 (listId 3) hoặc 99 (listId 4), flag 1.
    /// Payload: index u16 LE, listId u16 LE, octant u8, nameLen u8, unitLen u8, f32 LE khoảng cách, unit, name.
    /// Tên cắt ≤ 128 byte UTF-8 đúng ranh giới ký tự.
    static func listItem(listId: Int, index: Int, octant: UInt8, name: String, distance: Float, unit: String) -> Frame {
        let nameBytes = utf8Prefix(name, maxBytes: DashList.maxNameBytes)
        let unitBytes = utf8Prefix(unit, maxBytes: 16)
        let idx = UInt16(truncatingIfNeeded: index)
        let lid = UInt16(truncatingIfNeeded: listId)
        var payload: [UInt8] = [UInt8(idx & 0xFF), UInt8(idx >> 8), UInt8(lid & 0xFF), UInt8(lid >> 8),
                                min(octant, 8), UInt8(nameBytes.count), UInt8(unitBytes.count)]
        payload += f32le(distance)
        payload += unitBytes
        payload += nameBytes
        return Frame(command: listId == DashList.favourites ? 98 : 99, flag: 1, payload: payload)
    }

    /// Ô rẽ riêng của đồng hồ (chỉ khi đang dẫn đường, chế độ 0): lệnh 4, flag 1,
    /// turnIcon u8, f32 khoảng cách, unitLen u8, roadLen u8, unit, road. (documented — not yet observed)
    static func turnBox(icon: UInt8, distance: Float, unit: String, road: String) -> Frame {
        let unitBytes = utf8Prefix(unit, maxBytes: 16)
        let roadBytes = utf8Prefix(road, maxBytes: 128)
        let payload = [icon] + f32le(distance) + [UInt8(unitBytes.count), UInt8(roadBytes.count)] + unitBytes + roadBytes
        return Frame(command: 4, flag: 1, payload: payload)
    }

    /// Giờ còn lại cho ô rẽ: lệnh 1, flag 1, `[etaMin lo, hi, 00, 00]`. (documented — not yet observed)
    static func eta(minutes: Int) -> Frame {
        let m = max(0, min(65535, minutes))
        return Frame(command: 1, flag: 1, payload: [UInt8(m & 0xFF), UInt8(m >> 8), 0, 0])
    }
}
