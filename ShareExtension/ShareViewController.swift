import UIKit

/// Share extension "YaLinkShare": nhận URL/chữ (vd. chia sẻ từ Google Maps) rồi mở app bằng
/// `yalink://share?text=<mã hoá %>`. Extension không được gọi `UIApplication.shared`, và mẹo `openURL:`
/// cũ không còn chạy: đi ngược chuỗi responder tới đối tượng UIApplication rồi gọi động
/// `openURL:options:completionHandler:`. Không được thì chép chữ vào bộ nhớ tạm và nhắc mở app.
final class ShareViewController: UIViewController {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        extractSharedText { [weak self] text in
            self?.handle(text)
        }
    }

    // MARK: - Giao diện tối giản (không storyboard)

    private func buildUI() {
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 320, height: 200)

        titleLabel.text = "Ya Link"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        detailLabel.text = "Đang gửi sang Ya Link…"
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        doneButton.setTitle("Xong", for: .normal)
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        doneButton.isHidden = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel, doneButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func doneTapped() { complete() }

    // MARK: - Lấy chữ/URL được chia sẻ

    /// Gom chữ (public.plain-text) và URL (public.url) từ các tệp đính kèm; gọi lại trên luồng chính.
    private func extractSharedText(_ done: @escaping (String?) -> Void) {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let group = DispatchGroup()
        let box = Collected()

        for item in items {
            if let s = item.attributedContentText?.string, !s.isEmpty { box.add(s, isURL: false) }
            for provider in item.attachments ?? [] {
                for (type, isURL) in [("public.url", true), ("public.plain-text", false)]
                where provider.hasItemConformingToTypeIdentifier(type) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: type, options: nil) { value, _ in
                        if let s = ShareViewController.string(from: value), !s.isEmpty { box.add(s, isURL: isURL) }
                        group.leave()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            let (texts, urls) = box.snapshot()
            // Chữ trước (thường đã chứa link); thêm URL nếu chữ chưa có
            var parts: [String] = []
            for t in texts where !parts.contains(t) { parts.append(t) }
            for u in urls where !parts.contains(where: { $0.contains(u) }) { parts.append(u) }
            let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            done(joined.isEmpty ? nil : joined)
        }
    }

    /// Hộp gom kết quả từ nhiều luồng (có khoá).
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        private var urls: [String] = []
        func add(_ s: String, isURL: Bool) {
            lock.lock(); defer { lock.unlock() }
            if isURL { urls.append(s) } else { texts.append(s) }
        }
        func snapshot() -> ([String], [String]) {
            lock.lock(); defer { lock.unlock() }
            return (texts, urls)
        }
    }

    nonisolated fileprivate static func string(from value: NSSecureCoding?) -> String? {
        if let url = value as? URL { return url.absoluteString }
        if let url = value as? NSURL { return url.absoluteString }
        if let s = value as? String { return s }
        if let s = value as? NSString { return s as String }
        if let d = value as? Data { return String(data: d, encoding: .utf8) }
        return nil
    }

    // MARK: - Mở app

    private func handle(_ text: String?) {
        guard let text = text else {
            titleLabel.text = "Không có gì để gửi"
            detailLabel.text = "Hãy chia sẻ một đường link hoặc đoạn chữ."
            doneButton.isHidden = false
            return
        }
        if let url = Self.appURL(text: text), openInApp(url) {
            complete()
            return
        }
        // Không mở được app: chép vào bộ nhớ tạm, app sẽ tự đọc khi mở
        UIPasteboard.general.string = text
        titleLabel.text = "Mở Ya Link để tiếp tục"
        detailLabel.text = "Đã chép nội dung vào bộ nhớ tạm. Mở Ya Link, app sẽ tự nhận."
        doneButton.isHidden = false
    }

    /// `yalink://share?text=…` — mã hoá mọi ký tự ngoài A-Z a-z 0-9 - . _ ~ (kể cả & = + /).
    static func appURL(text: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "yalink://share?text=" + encoded)
    }

    /// Đi ngược chuỗi responder tới UIApplication và gọi động `openURL:options:completionHandler:`
    /// (không dùng `UIApplication.shared` nên vẫn dịch được với APPLICATION_EXTENSION_API_ONLY=YES).
    private func openInApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        typealias OpenFn = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                let imp = current.method(for: selector)
                let open = unsafeBitCast(imp, to: OpenFn.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func complete() {
        guard !finished else { return }
        finished = true
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
