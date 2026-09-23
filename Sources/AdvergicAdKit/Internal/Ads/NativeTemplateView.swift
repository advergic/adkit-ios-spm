#if canImport(UIKit)
import UIKit

/// The layout native adapters bind assets into, built in code so the SDK ships no nib a host app
/// could collide with. Mirrors the Android template: icon + headline/advertiser row, body, media,
/// call-to-action.
///
/// Networks that register asset views for click/impression tracking (AdMob, Yandex) place this
/// inside their own ad view and register the subviews exposed here. `mediaContainer` receives
/// the network's own media view.
@_spi(AdvergicAdapters)
public final class AdvergicNativeTemplateView: UIView {

    public let iconView = UIImageView()
    public let headlineLabel = UILabel()
    public let advertiserLabel = UILabel()
    public let bodyLabel = UILabel()
    public let mediaContainer = UIView()
    public let callToActionButton = UIButton(type: .system)
    /// Small print some networks require on screen (Yandex's age rating, sponsor and warning).
    /// Empty and collapsed unless an adapter adds labels to it.
    public let disclosureStack = UIStackView()

    /// The "Ad" attribution every network's native policy requires to be visible.
    public let adBadge = UILabel()

    public static let mediaHeight: CGFloat = 180

    public override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    /// Fills the text and icon slots. Empty values collapse their row.
    public func bind(headline: String?, advertiser: String?, body: String?, callToAction: String?, icon: UIImage?) {
        headlineLabel.text = headline
        advertiserLabel.text = advertiser
        bodyLabel.text = body
        bodyLabel.isHidden = (body ?? "").isEmpty
        callToActionButton.setTitle(callToAction, for: .normal)
        callToActionButton.isHidden = (callToAction ?? "").isEmpty
        iconView.image = icon
        iconView.isHidden = icon == nil
    }

    /// A label styled for `disclosureStack`.
    public func addDisclosureLabel() -> UILabel {
        let label = UILabel()
        label.font = .systemFont(ofSize: 10)
        label.textColor = .gray
        label.numberOfLines = 0
        disclosureStack.addArrangedSubview(label)
        return label
    }

    /// Adds a network's media view, pinned to the media slot.
    public func setMedia(_ view: UIView) {
        mediaContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        mediaContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: mediaContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: mediaContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: mediaContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: mediaContainer.bottomAnchor),
        ])
    }

    /// Pins `view` to fill `container`.
    public static func pin(_ view: UIView, in container: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func build() {
        headlineLabel.font = .boldSystemFont(ofSize: 15)
        headlineLabel.numberOfLines = 2
        advertiserLabel.font = .systemFont(ofSize: 11)
        advertiserLabel.textColor = .gray
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.numberOfLines = 3
        callToActionButton.titleLabel?.font = .boldSystemFont(ofSize: 13)
        // The network's view handles the tap; a button that swallowed it would break click tracking.
        callToActionButton.isUserInteractionEnabled = false
        iconView.contentMode = .scaleAspectFit
        iconView.clipsToBounds = true
        iconView.layer.cornerRadius = 6

        adBadge.text = " Ad "
        adBadge.font = .boldSystemFont(ofSize: 10)
        adBadge.textColor = .white
        adBadge.backgroundColor = UIColor(red: 0.95, green: 0.65, blue: 0.1, alpha: 1)
        adBadge.layer.cornerRadius = 3
        adBadge.clipsToBounds = true
        adBadge.setContentHuggingPriority(.required, for: .horizontal)

        let badgeRow = UIStackView(arrangedSubviews: [adBadge, advertiserLabel])
        badgeRow.axis = .horizontal
        badgeRow.spacing = 6

        let titles = UIStackView(arrangedSubviews: [headlineLabel, badgeRow])
        titles.axis = .vertical
        titles.spacing = 2

        let header = UIStackView(arrangedSubviews: [iconView, titles])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 12

        let footer = UIStackView(arrangedSubviews: [UIView(), callToActionButton])
        footer.axis = .horizontal

        disclosureStack.axis = .vertical
        disclosureStack.spacing = 2

        let column = UIStackView(arrangedSubviews: [header, bodyLabel, mediaContainer, disclosureStack, footer])
        column.axis = .vertical
        column.spacing = 8
        column.isLayoutMarginsRelativeArrangement = true
        column.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        Self.pin(column, in: self)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
            mediaContainer.heightAnchor.constraint(equalToConstant: Self.mediaHeight),
        ])
    }
}

@_spi(AdvergicAdapters)
public extension UIView {
    /// The view controller presenting this view, for networks that present click-through
    /// screens from one. Nil until the view is in a hierarchy.
    var advergicViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    /// Top-most presented controller of the key window — the fallback when a view isn't mounted.
    static var advergicTopViewController: UIViewController? {
        let windows = UIApplication.shared.windows
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
#endif
