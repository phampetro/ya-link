import CoreGraphics
import DashRender
import Foundation
import UIKit

/// Bộ ảnh nền: lưu trong Documents/backgrounds (đã thu nhỏ), tự đổi ảnh mỗi `interval` giây,
/// ảnh mới hiện dần đè lên ảnh cũ trong 0,8 s. Enter ở trang chủ gọi `next`.
/// Chưa chọn ảnh nào thì dùng 2 ảnh mặc định (biển, đồng cỏ).
@MainActor
final class PhotoStore: ObservableObject {
    static let fadeDuration: TimeInterval = 0.8

    /// Số ảnh người dùng đã chọn (0 = đang dùng ảnh mặc định).
    @Published private(set) var count = 0
    /// Ảnh nhỏ để hiện ở Cài đặt (ảnh đã chọn, hoặc ảnh mặc định).
    @Published private(set) var thumbs: [UIImage] = []
    @Published var interval: TimeInterval = UserDefaults.standard.double(forKey: "bgInterval").nonZero ?? 8 {
        didSet { UserDefaults.standard.set(interval, forKey: "bgInterval") }
    }

    private var images: [CGImage] = []
    private var index = 0
    private var previous: CGImage?
    private var changedAt: TimeInterval = -100

    private var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("backgrounds")
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let user = files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap {
            (try? Data(contentsOf: $0)).flatMap { ImageEncoder.load($0) }
        }
        count = user.count
        images = user.isEmpty ? DefaultPhotos.make() : user
        thumbs = images.map { UIImage(cgImage: $0) }
        index = 0
        previous = nil
    }

    /// Thay toàn bộ bộ ảnh (từ PhotosPicker). Ảnh được thu nhỏ còn cạnh dài 960 px rồi lưu JPEG.
    func replace(with datas: [Data]) {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, d) in datas.enumerated() {
            guard let img = ImageEncoder.load(d, maxPixel: 960) else { continue }
            let jpg = ImageEncoder.jpeg(img, quality: 0.85)
            try? Data(jpg).write(to: dir.appendingPathComponent(String(format: "%03d.jpg", i)))
        }
        load()
    }

    /// Xoá bộ ảnh đã chọn và dùng lại 2 ảnh nền mặc định của app (biển, đồng cỏ).
    func resetToDefault() {
        try? FileManager.default.removeItem(at: dir)
        load()
    }

    func next(now: TimeInterval) {
        guard images.count > 1 else { return }
        previous = images[index]
        index = (index + 1) % images.count
        changedAt = now
    }

    /// Tự đổi ảnh khi hết thời gian. Trả true nếu vừa đổi.
    func tick(now: TimeInterval) -> Bool {
        guard images.count > 1, now - changedAt >= interval else { return false }
        next(now: now)
        return true
    }

    func isFading(now: TimeInterval) -> Bool { now - changedAt < Self.fadeDuration }

    func current(now: TimeInterval) -> (photo: CGImage?, previous: CGImage?, fade: Double) {
        guard !images.isEmpty else { return (nil, nil, 1) }
        let fade = min(1, max(0, (now - changedAt) / Self.fadeDuration))
        return (images[index], fade < 1 ? previous : nil, fade)
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
