import UIKit
import WebKit

/// The web probe (docs/probe-app.md#web-probe): shown instead of the touch
/// surface when the app is launched with `-ProbeWeb YES`. An app's own
/// `WKWebView` that does not start at the screen's corner: it is inset by
/// `inset` from the safe area on every side, below a native label, so a page
/// element's frame in the web content process and its place on the screen
/// differ by that offset. The page has a button and a field near its top and
/// a second button far below the web view's height, for `scroll`. What the
/// page receives is recorded in `probe.web.last`.
final class ProbeWebViewController: UIViewController, WKScriptMessageHandler {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "ProbeWeb") || zooms || framed || embedded }
    /// `-ProbeWebEmbedded YES`: a small web view embedded in native content,
    /// as many apps show one, with a native button at the screen's centre:
    /// the app, not the page, holds the display centre, so the page is a
    /// process the tree reaches only through the app's remote element.
    static var embedded: Bool { UserDefaults.standard.bool(forKey: "ProbeWebEmbedded") }
    static let nativeIdentifier = "probe.web.native"
    /// The embedded web view's height.
    static let embeddedHeight: CGFloat = 220
    /// `-ProbeWebFrame YES`: a page whose button and field are inside an
    /// iframe, below a button of the page itself, for pages with frames.
    static var framed: Bool { UserDefaults.standard.bool(forKey: "ProbeWebFrame") }
    /// `-ProbeWebZoom YES`: the same page, but it may zoom and its field's
    /// text is 12 points, so focusing the field makes iOS zoom in on it and
    /// the field becomes wider than the display.
    static var zooms: Bool { UserDefaults.standard.bool(forKey: "ProbeWebZoom") }
    static let lastIdentifier = "probe.web.last"
    static let webIdentifier = "probe.web.view"
    /// The web view's distance from the safe area's leading, trailing and
    /// bottom edges, and from the label above it.
    static let inset: CGFloat = 40

    private let last = UILabel()
    private var web: WKWebView?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemOrange
        last.text = "Last: none"
        last.textAlignment = .center
        last.backgroundColor = .systemBackground
        last.accessibilityIdentifier = Self.lastIdentifier
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "probe")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.accessibilityIdentifier = Self.webIdentifier
        web.isInspectable = true
        self.web = web
        let guide = view.safeAreaLayoutGuide
        if Self.embedded {
            layOutEmbedded(web, guide: guide)
            web.loadHTMLString(Self.page, baseURL: nil)
            return
        }
        for subview in [last, web] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            last.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            last.leadingAnchor.constraint(equalTo: guide.leadingAnchor), last.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            last.heightAnchor.constraint(equalToConstant: 44),
            web.topAnchor.constraint(equalTo: last.bottomAnchor, constant: Self.inset),
            web.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Self.inset),
            web.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Self.inset),
            web.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Self.inset),
        ])
        web.loadHTMLString(Self.framed ? Self.framedPage : Self.zooms ? Self.zoomingPage : Self.page, baseURL: nil)
    }

    /// The label at the top, a native button at the centre of the screen,
    /// and the web view in the lower part, inset by 16 points.
    private func layOutEmbedded(_ web: WKWebView, guide: UILayoutGuide) {
        view.backgroundColor = .systemBackground
        var native = UIButton.Configuration.filled()
        native.title = "Native button"
        let button = UIButton(configuration: native, primaryAction: UIAction { [weak self] _ in
            self?.last.text = "Last: native"
            self?.last.accessibilityValue = "native"
        })
        button.accessibilityIdentifier = Self.nativeIdentifier
        for subview in [last, button, web] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            last.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            last.leadingAnchor.constraint(equalTo: guide.leadingAnchor), last.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            last.heightAnchor.constraint(equalToConstant: 44),
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor), button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 220), button.heightAnchor.constraint(equalToConstant: 60),
            web.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            web.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            web.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            web.heightAnchor.constraint(equalToConstant: Self.embeddedHeight),
        ])
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let what = message.body as? String else { return }
        last.text = "Last: \(what)"
        last.accessibilityValue = what
    }

    /// A fixed-width page that does not zoom, so frames stay predictable.
    /// The spacer puts the bottom button about 1500 points below the top.
    static let page = """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <style>
    * { box-sizing: border-box; }
    body { font: 17px -apple-system; margin: 12px; background: #eef; }
    button, input { font: 17px -apple-system; width: 100%; height: 48px; margin: 8px 0; }
    .spacer { height: 1400px; background: linear-gradient(#ccf, #fcc); }
    </style></head>
    <body>
    <h1>Web probe</h1>
    <button id="top" onclick="say('web-top')">Top button</button>
    <label for="field">Web field</label>
    <input id="field" placeholder="Type here" oninput="say('web-field:' + this.value)">
    <div class="spacer" aria-hidden="true"></div>
    <button id="bottom" onclick="say('web-bottom')">Bottom button</button>
    <script>function say(what) { window.webkit.messageHandlers.probe.postMessage(what); }</script>
    </body></html>
    """

    /// The page for `-ProbeWebZoom YES`: zoom allowed, and 12-point text in
    /// the field, which iOS zooms to when the field takes focus.
    static let zoomingPage = page
        .replacingOccurrences(of: ", maximum-scale=1, user-scalable=no", with: "")
        .replacingOccurrences(of: "button, input { font: 17px -apple-system;", with: "button { font: 17px -apple-system; } input { font: 12px -apple-system; } button, input {")

    /// The page for `-ProbeWebFrame YES`: a button of the page, then an
    /// iframe (same origin, `srcdoc`) holding its own button and field.
    static let framedPage = """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <style>
    * { box-sizing: border-box; }
    body { font: 17px -apple-system; margin: 12px; background: #efe; }
    button { font: 17px -apple-system; width: 100%; height: 48px; margin: 8px 0; }
    iframe { width: 100%; height: 260px; border: 2px solid #393; }
    </style></head>
    <body>
    <h1>Frame probe</h1>
    <button id="outer" onclick="window.webkit.messageHandlers.probe.postMessage('web-outer')">Page button</button>
    <iframe title="Inner frame" srcdoc="
    <style>body{font:17px -apple-system;margin:8px;background:#ffe} button,input{font:17px -apple-system;width:100%;height:48px;margin:8px 0;box-sizing:border-box}</style>
    <button id='inner' onclick='window.webkit.messageHandlers.probe.postMessage(&quot;web-frame-button&quot;)'>Frame button</button>
    <label for='innerField'>Frame field</label>
    <input id='innerField' placeholder='Frame input' oninput='window.webkit.messageHandlers.probe.postMessage(&quot;web-frame-field:&quot; + this.value)'>
    "></iframe>
    </body></html>
    """
}
