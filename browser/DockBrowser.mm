// Ghostty Dock's browser: Chromium (CEF) in a view, built as
// DockBrowser.framework and loaded only when a browser is first opened, so
// the app runs without it. The app calls the C functions at the bottom; a
// view tells it about its page with DockBrowserChanged notifications: its
// "url" and "title", a "popup" or "background" tab it asks for, or that it
// "closed" itself. DockBrowserAdopted brings a page opened by devtools.

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_focus_handler.h"
#include "include/wrapper/cef_library_loader.h"

static NSString* const kChanged = @"DockBrowserChanged";
// A page Chromium opened on its own (devtools' Target.createTarget, as
// Claude's new_page sends): its view, for the app to make a tab of.
static NSString* const kAdopted = @"DockBrowserAdopted";

// CEF needs NSApplication to say whether sendEvent: is on the stack. The
// app is Ghostty's plain NSApplication, so the methods are added to the
// class itself instead of a subclass.
static BOOL gHandlingSendEvent = NO;

@implementation NSApplication (DockBrowser)
- (BOOL)dockBrowser_isHandlingSendEvent { return gHandlingSendEvent; }
- (void)dockBrowser_setHandlingSendEvent:(BOOL)v { gHandlingSendEvent = v; }
- (void)dockBrowser_sendEvent:(NSEvent*)event {
  CefScopedSendingEvent scoped;
  [self dockBrowser_sendEvent:event];  // the original, after the swap
}
@end

static void TeachApplication() {
  Class app = [NSApplication class];
  auto add = [&](SEL name, SEL from) {
    Method m = class_getInstanceMethod(app, from);
    class_addMethod(app, name, method_getImplementation(m), method_getTypeEncoding(m));
  };
  add(@selector(isHandlingSendEvent), @selector(dockBrowser_isHandlingSendEvent));
  add(@selector(setHandlingSendEvent:), @selector(dockBrowser_setHandlingSendEvent:));
  method_exchangeImplementations(class_getInstanceMethod(app, @selector(sendEvent:)),
                                 class_getInstanceMethod(app, @selector(dockBrowser_sendEvent:)));
  class_addProtocol(app, @protocol(CrAppProtocol));
  class_addProtocol(app, @protocol(CrAppControlProtocol));
  class_addProtocol(app, @protocol(CefAppProtocol));
}

// The app's run loop drives CEF: CEF asks for work when it has some, and
// a timer catches anything it did not ask for.
static void PumpWork() { CefDoMessageLoopWork(); }

class DockApp : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit DockApp(int port) : port_(port) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  // For a page Chromium opens itself, which would otherwise get no
  // callbacks and a window of its own: see DockClient::OnAfterCreated.
  CefRefPtr<CefClient> GetDefaultClient() override;

  void OnBeforeCommandLineProcessing(const CefString& type, CefRefPtr<CefCommandLine> line) override {
    if (!type.empty()) return;
    if (port_ > 0) {
      line->AppendSwitchWithValue("remote-debugging-port", std::to_string(port_));
      line->AppendSwitchWithValue("remote-allow-origins", "http://127.0.0.1:" + std::to_string(port_));
    }
    // Its own keychain entry would ask for your password; the profile is
    // only for pages you test.
    line->AppendSwitch("use-mock-keychain");
  }

  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, std::max<int64_t>(delay_ms, 0) * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ PumpWork(); });
  }

 private:
  int port_;
  IMPLEMENT_REFCOUNTING(DockApp);
};

@interface DockBrowserView : NSView
- (instancetype)initWithBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)closing;
- (void)closed;
@end

class DockClient : public CefClient, public CefDisplayHandler, public CefFocusHandler, public CefLifeSpanHandler {
 public:
  explicit DockClient(DockBrowserView* view) : view_(view) {}

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

  // A page that loads or reloads (yours, or Claude driving it over the
  // debugging port) would take the keyboard from the terminal; only a
  // click in the page gives it the keyboard.
  bool OnSetFocus(CefRefPtr<CefBrowser>, FocusSource source) override {
    return source == FOCUS_SOURCE_NAVIGATION;
  }

  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString& url) override {
    if (frame->IsMain()) Post(@"url", url);
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override { Post(@"title", title); }

  // A link that opens a new tab or window opens as a tab of the panel
  // instead ("popup", or "background" for one opened behind).
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString& url, const CefString&,
                     WindowOpenDisposition disposition, bool, const CefPopupFeatures&, CefWindowInfo&,
                     CefRefPtr<CefClient>&, CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    Post(disposition == CEF_WOD_NEW_BACKGROUND_TAB ? @"background" : @"popup", url);
    return true;
  }

  // A page closing itself (window.close(), devtools' Target.closeTarget):
  // only its tab goes. Left to CEF, it would close the window the page is
  // in, which is the terminal's. The app's own close comes with no view.
  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    NSLog(@"DockBrowser: page %d closing itself, view %d", browser->GetIdentifier(), view_ != nil);
    [view_ closing];
    Post(@"closed", "");
    return true;
  }

  // Also where a page closed by devtools ends, without DoClose first.
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    NSLog(@"DockBrowser: page %d closed, view %d", browser->GetIdentifier(), view_ != nil);
    [view_ closed];
    Post(@"closed", "");
    view_ = nil;
  }

 private:
  void Post(NSString* key, const CefString& value) {
    NSString* text = [NSString stringWithUTF8String:value.ToString().c_str()] ?: @"";
    __weak DockBrowserView* view = view_;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (view) [[NSNotificationCenter defaultCenter] postNotificationName:kChanged object:view userInfo:@{key: text}];
    });
  }

  __weak DockBrowserView* view_;
  IMPLEMENT_REFCOUNTING(DockClient);
};

@implementation DockBrowserView {
  CefRefPtr<CefBrowser> _browser;
  // Chromium is closing the page itself: asking it to again is not ours.
  BOOL _closing;
}

- (instancetype)initWithURL:(NSString*)url {
  if (!(self = [super initWithFrame:NSMakeRect(0, 0, 800, 600)])) return nil;
  self.autoresizesSubviews = YES;
  CefWindowInfo info;
  info.SetAsChild((__bridge void*)self, CefRect(0, 0, 800, 600));
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  _browser = CefBrowserHost::CreateBrowserSync(info, new DockClient(self), url.UTF8String, settings, nullptr,
                                               nullptr);
  NSView* inner = _browser ? (__bridge NSView*)_browser->GetHost()->GetWindowHandle() : nil;
  inner.frame = self.bounds;
  inner.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  return self;
}

// A page Chromium made in a window of its own: its view moves here and the
// window goes out of sight.
- (instancetype)initWithBrowser:(CefRefPtr<CefBrowser>)browser {
  if (!(self = [super initWithFrame:NSMakeRect(0, 0, 800, 600)])) return nil;
  self.autoresizesSubviews = YES;
  _browser = browser;
  NSView* inner = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
  NSWindow* stray = inner.window;
  [inner removeFromSuperview];
  [stray orderOut:nil];
  inner.frame = self.bounds;
  inner.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self addSubview:inner];
  return self;
}

- (void)closing { _closing = YES; }
- (void)closed { _browser = nullptr; }

- (void)dealloc {
  NSLog(@"DockBrowser: view gone, page %d, closing %d", _browser ? _browser->GetIdentifier() : -1, _closing);
  if (_browser && !_closing) _browser->GetHost()->CloseBrowser(true);
}

- (void)loadURLString:(NSString*)url {
  if (_browser) _browser->GetMainFrame()->LoadURL(url.UTF8String);
}
- (void)goBack { if (_browser) _browser->GoBack(); }
- (void)goForward { if (_browser) _browser->GoForward(); }
- (void)reload { if (_browser) _browser->Reload(); }
@end

CefRefPtr<CefClient> DockApp::GetDefaultClient() { return new DockClient(nil); }

// Ours were made with a view; one without was opened by Chromium itself
// and given this client by GetDefaultClient.
void DockClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  if (view_) return;
  CefRefPtr<DockClient> client(this);
  dispatch_async(dispatch_get_main_queue(), ^{
    DockBrowserView* view = [[DockBrowserView alloc] initWithBrowser:browser];
    client->view_ = view;
    NSString* url = [NSString stringWithUTF8String:browser->GetMainFrame()->GetURL().ToString().c_str()] ?: @"";
    [[NSNotificationCenter defaultCenter] postNotificationName:kAdopted object:view userInfo:@{@"url": url}];
  });
}

static bool gStarted = false;

extern "C" {

// Loads Chromium and starts it, once. Empty on success, else what went
// wrong. `helper` is the "… Helper.app" executable inside the app.
__attribute__((visibility("default")))
const char* dock_browser_start(const char* framework, const char* helper, const char* cache, int port) {
  if (gStarted) return "";
  NSString* lib = [[NSString stringWithUTF8String:framework] stringByAppendingPathComponent:@"Chromium Embedded Framework"];
  if (!cef_load_library(lib.fileSystemRepresentation)) return "could not load Chromium Embedded Framework";
  TeachApplication();

  CefMainArgs args(0, nullptr);
  CefSettings s;
  s.no_sandbox = true;
  s.external_message_pump = true;
  CefString(&s.framework_dir_path) = framework;
  CefString(&s.browser_subprocess_path) = helper;
  CefString(&s.main_bundle_path) = NSBundle.mainBundle.bundlePath.UTF8String;
  CefString(&s.root_cache_path) = cache;
  CefString(&s.cache_path) = cache;
  if (!CefInitialize(args, s, new DockApp(port), nullptr)) return "Chromium did not start";
  gStarted = true;
  [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer*) { PumpWork(); }];
  return "";
}

// A new browser view showing `url`, retained for the caller.
__attribute__((visibility("default")))
void* dock_browser_new_view(const char* url) {
  if (!gStarted) return nullptr;
  return (__bridge_retained void*)[[DockBrowserView alloc] initWithURL:[NSString stringWithUTF8String:url]];
}

}
