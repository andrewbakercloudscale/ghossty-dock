// Renders a file with the file viewer's real page and scheme handler
// (Resources/viewer, DockViewerScheme.swift) in an off-screen WKWebView, and
// prints what the page shows: its class, its text, and any page errors
// (tests/viewer-test.sh checks them).
//
// usage: VIEWER_PAGE=<page folder> viewer-render <file> [<file>...]

import AppKit
import WebKit

final class Probe: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var errors: [String] = []
    var loaded = false

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        errors.append(String(describing: message.body))
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { loaded = true }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: any Error) {
        errors.append("did not load: \(e.localizedDescription)"); loaded = true
    }
}

guard let page = ProcessInfo.processInfo.environment["VIEWER_PAGE"] else {
    FileHandle.standardError.write(Data("VIEWER_PAGE is not set\n".utf8))
    exit(2)
}
DockViewerScheme.pageFolder = URL(filePath: page).standardizedFileURL

_ = NSApplication.shared
for path in CommandLine.arguments.dropFirst() {
    let file = URL(filePath: path).standardizedFileURL
    let probe = Probe()
    let config = WKWebViewConfiguration()
    config.setURLSchemeHandler(DockViewerScheme(), forURLScheme: "dockview")
    config.userContentController.add(probe, name: "viewer")
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
    view.navigationDelegate = probe
    var c = URLComponents()
    c.scheme = "dockview"; c.host = "app"; c.path = "/viewer.html"; c.fragment = file.path
    view.load(URLRequest(url: c.url!))
    let deadline = Date().addingTimeInterval(10)
    while !probe.loaded && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    // The page renders after it fetches the file.
    var out = ""
    let until = Date().addingTimeInterval(5)
    while Date() < until {
        var done = false
        view.evaluateJavaScript("document.getElementById('doc').className + '\\n' + document.getElementById('doc').innerText") { r, _ in
            out = (r as? String) ?? ""; done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if out.count > 2 { break }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
    print("== \(file.path)")
    print(out)
    for e in probe.errors { print("ERROR: \(e)") }
    if out.count <= 2 { print("ERROR: nothing rendered") }
}
