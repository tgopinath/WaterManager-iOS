import SwiftUI
import WebKit
import SafariServices
import CoreLocation

/// The live Water Manager web app in a WKWebView, set up to behave like a native iPhone app:
/// edge swipe to go back, inline media, sound without a tap first, haptics from the page,
/// JavaScript alerts as iOS alerts, and outside links in Safari's in-app viewer.
/// Generated from the Kolam iOS shell template (kolam-design-system/ios/shell-template).
struct AppWebView: UIViewRepresentable {
    static let home: URL = {
        #if DEBUG
        // Debug builds only: `simctl launch <device> <bundle> -KolamStartURL "<url>"` opens another route (for screenshots).
        if let s = UserDefaults.standard.string(forKey: "KolamStartURL"), let u = URL(string: s) { return u }
        #endif
        return URL(string: "https://water-manager-beryl.vercel.app/")!
    }()
    /// Hosts that stay inside the app; every other http(s) link opens in Safari's viewer.
    static let appHosts: Set<String> = ["water-manager-beryl.vercel.app"]

    let url: URL
    @Binding var loading: Bool
    @Binding var failed: Bool
    let reloadToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // "WaterManager-iOS" + "Kolam-iOS" let the page's kolam-ios.js turn on the iOS look.
        config.applicationNameForUserAgent = "WaterManager-iOS/1.0 Kolam-iOS/1.0 Mobile/15E148"
        config.userContentController.add(context.coordinator, name: "haptic")
        // Location: the page's navigator.geolocation is answered by CoreLocation (one iOS prompt, no second
        // "this website would like to use your location" alert from WebKit).
        config.userContentController.addScriptMessageHandler(context.coordinator.geo, contentWorld: .page, name: "geo")
        config.userContentController.addUserScript(WKUserScript(source: GeoBridge.script, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: Self.shellScript(),
                                                                injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true))

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true      // swipe from the left edge to go back
        web.allowsLinkPreview = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = UIColor(named: "LaunchBackground")
        #if DEBUG
        web.isInspectable = true                             // Safari ▸ Develop, for debugging
        #endif
        web.load(URLRequest(url: url))
        context.coordinator.lastToken = reloadToken
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.lastToken != reloadToken {    // "Try Again" after being offline
            context.coordinator.lastToken = reloadToken
            web.load(URLRequest(url: url))
        }
    }

    /// window.KolamShell tells the kit it runs in this shell, and passes accessibility settings
    /// that have no CSS media query in WebKit yet.
    static func shellScript() -> String {
        let reduceTransparency = UIAccessibility.isReduceTransparencyEnabled ? "true" : "false"
        let boldText = UIAccessibility.isBoldTextEnabled ? "true" : "false"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return """
        window.KolamShell = { platform: 'ios', app: 'Water Manager', version: '\(version)', nativeBack: true,
          reduceTransparency: \(reduceTransparency), boldText: \(boldText) };
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let parent: AppWebView
        var lastToken = 0
        let geo = GeoBridge()
        var ranDebugJS = false
        init(_ parent: AppWebView) { self.parent = parent }

        // MARK: Loading state
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            #if DEBUG
            // Debug builds only: `-KolamJS "<line>"` runs one line of JavaScript after the first load (screenshot set-up).
            if !ranDebugJS, let js = UserDefaults.standard.string(forKey: "KolamJS") { ranDebugJS = true; webView.evaluateJavaScript(js) }
            #endif
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.failed = true }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()                                 // iOS reclaimed memory in the background
        }

        // MARK: Links: the app stays in the web view; other sites open in Safari's viewer
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.allow) }
            let scheme = url.scheme?.lowercased() ?? ""
            if ["mailto", "tel", "sms", "facetime", "maps", "itms-apps"].contains(scheme) {
                UIApplication.shared.open(url)
                return decisionHandler(.cancel)
            }
            let isApp = url.host.map { AppWebView.appHosts.contains($0) } ?? true
            if action.navigationType == .linkActivated && !isApp && (scheme == "https" || scheme == "http") {
                openInSafari(url, from: webView)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        // target="_blank" links and window.open()
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = action.request.url else { return nil }
            if let host = url.host, AppWebView.appHosts.contains(host) { webView.load(URLRequest(url: url)) }
            else { openInSafari(url, from: webView) }
            return nil
        }

        private func openInSafari(_ url: URL, from view: UIView) {
            guard let root = view.window?.rootViewController else { return }
            let safari = SFSafariViewController(url: url)
            safari.preferredControlTintColor = UIColor(named: "AccentColor")
            (root.presentedViewController ?? root).present(safari, animated: true)
        }

        // MARK: JavaScript alert() / confirm() as iOS alerts (WKWebView shows nothing otherwise)
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            present(alert, from: webView, orElse: completionHandler)
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            present(alert, from: webView) { completionHandler(false) }
        }
        private func present(_ vc: UIViewController, from view: UIView, orElse fallback: @escaping () -> Void) {
            guard let root = view.window?.rootViewController else { return fallback() }
            (root.presentedViewController ?? root).present(vc, animated: true)
        }

        // Camera and microphone for the app's own pages: iOS asks once; the page then gets it.
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(AppWebView.appHosts.contains(origin.host) ? .grant : .prompt)
        }

        // MARK: Haptics requested by the page (KolamIOS.haptic(kind))
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "haptic" else { return }
            switch message.body as? String ?? "light" {
            case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
            case "selection": UISelectionFeedbackGenerator().selectionChanged()
            case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case "soft": UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            case "rigid": UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }
}

/// Native location for the page: a small navigator.geolocation shim posts to "geo" and gets a reply
/// from CLLocationManager. permissions.query({ name: 'geolocation' }) reports the app's authorization.
final class GeoBridge: NSObject, WKScriptMessageHandlerWithReply, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: [([String: Any]) -> Void] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let body = message.body as? [String: Any] ?? [:]
        if body["op"] as? String == "state" { return replyHandler(state, nil) }
        if (body["high"] as? Bool) == true { manager.desiredAccuracy = kCLLocationAccuracyBest }
        waiting.append { replyHandler($0, nil) }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()   // continues in locationManagerDidChangeAuthorization
        case .denied, .restricted: finish(["error": 1, "message": "Location permission denied"])
        default: manager.requestLocation()
        }
    }

    private var state: String {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return "granted"
        case .denied, .restricted: return "denied"
        default: return "prompt"
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard !waiting.isEmpty else { return }
        switch m.authorizationStatus {
        case .notDetermined: return
        case .denied, .restricted: finish(["error": 1, "message": "Location permission denied"])
        default: m.requestLocation()
        }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        finish(["latitude": l.coordinate.latitude, "longitude": l.coordinate.longitude, "accuracy": l.horizontalAccuracy,
                "altitude": l.altitude, "timestamp": l.timestamp.timeIntervalSince1970 * 1000])
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        finish(["error": denied ? 1 : 2, "message": error.localizedDescription])
    }
    private func finish(_ reply: [String: Any]) {
        let w = waiting; waiting = []
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        w.forEach { $0(reply) }
    }

    /// The timeout only starts once permission is granted, so the iOS prompt never makes a request time out.
    static let script = """
    (function () {
      var h = window.webkit && webkit.messageHandlers && webkit.messageHandlers.geo, g = navigator.geolocation;
      if (!h || !g) return;
      function err(code, message) { return { code: code, message: message, PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 }; }
      g.getCurrentPosition = function (ok, fail, o) {
        o = o || {}; var done = false, timer = 0;
        function end(f) { if (done) return; done = true; clearTimeout(timer); f(); }
        h.postMessage({ op: 'state' }).then(function (s) {
          if (s === 'granted' && o.timeout > 0 && o.timeout !== Infinity)
            timer = setTimeout(function () { end(function () { fail && fail(err(3, 'Timeout')); }); }, o.timeout);
          return h.postMessage({ op: 'get', high: !!o.enableHighAccuracy });
        }).then(function (r) {
          end(function () {
            if (r.error) return fail && fail(err(r.error, r.message));
            ok({ coords: { latitude: r.latitude, longitude: r.longitude, accuracy: r.accuracy, altitude: r.altitude,
                           altitudeAccuracy: null, heading: null, speed: null }, timestamp: r.timestamp });
          });
        }, function (e) { end(function () { fail && fail(err(2, String(e))); }); });
      };
      var watches = 0;
      g.watchPosition = function (ok, fail, o) { g.getCurrentPosition(ok, fail, o); return ++watches; };
      g.clearWatch = function () {};
      if (navigator.permissions && navigator.permissions.query) {
        var q = navigator.permissions.query.bind(navigator.permissions);
        navigator.permissions.query = function (d) {
          if (!d || d.name !== 'geolocation') return q(d);
          return h.postMessage({ op: 'state' }).then(function (s) {
            return { name: 'geolocation', state: s, onchange: null, addEventListener: function () {}, removeEventListener: function () {} };
          });
        };
      }
    })();
    """
}
