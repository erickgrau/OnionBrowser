# Chibitek OnionBrowser fork — developer notes

Working notes for this fork: a dual-mode iOS browser that behaves like Safari for
regular sites and routes `.onion` through a built-in Tor. Target device runs the
**iOS 27 beta**, which is the source of most of the surprises below.

Branches: work on `development`, fast-forward `main` to match, push both. `main` is
the GitHub default. The upstream OnionBrowser remote was removed; re-add with
`git remote add upstream https://github.com/OnionBrowser/OnionBrowser.git` if needed.

## How `.onion` routing works (scheme handler — the only workable path)

`.onion` requests are rewritten to a custom `torhttps://` / `torhttp://` scheme that
WebKit *will* load, intercepted by `TorSchemeHandler` (a `WKURLSchemeHandler`), fetched
over URLSession through Tor's SOCKS proxy, and the HTML/CSS rewritten so subresources
resolve back through the same scheme. Verified in the simulator rendering a real onion
fully (HTML, CSS, color images, QR codes, links).

- Flag: `Tab.useNativeProxy` (default **`false`** = scheme handler). The native-proxy
  code path is kept only for reference; see the dead-end note below.
- Regular http/https tabs use normal WKWebView networking (dual mode: only `.onion`
  goes through Tor).
- `.onion` names resolve remotely through Tor because URLSession with modern
  `proxyConfigurations` does SOCKS5h — verified on device (NETDIAG pulled a real onion
  200/171KB).

### Why native WebView proxy does NOT work (dead end, proven)

Setting the SOCKS proxy on `WKWebsiteDataStore.proxyConfigurations` and loading a plain
`https://<addr>.onion` fails with **bad URL (-1000)** even with the proxy attached and
live (confirmed by logging `proxied=true` at the moment of `webView.load`). iOS/CFNetwork
rejects the reserved `.onion` TLD (RFC 7686) at URL validation, before any proxying. This
is why the scheme handler exists: `torhttps://` is a scheme WebKit accepts, and URLSession
(unlike WKWebView) *does* allow `.onion` through the proxy. Don't re-attempt native proxy
for `.onion`.

### Scheme-handler rendering fixes that made real sites work (were blank before)

- Strip `Content-Encoding`/`Transfer-Encoding`/`Content-Length` before delivery —
  URLSession already decoded the body; a leftover gzip header blanks the page.
- Resolve rewritten subresource URLs via `absoluteURL` (host-less `torhttps:/path` never
  loaded).
- Insert the injected `<base>` after `<head>`, not before `<!DOCTYPE>` (quirks mode).
- Append tor-scheme twins to `.onion` CSP host sources (else subresources are blocked).
- Injected interception JS (`TorSchemeHandler.interceptionScript`) rewrites dynamic
  fetch/XHR/link-clicks to the tor scheme. It had off-by-one substring offsets producing
  `torhttpss://` / `torhttpp://` → "unsupported URL (-1002)" on every click; fixed to
  replace only the scheme prefix and only for `.onion`.

Known limitation: heavy JS SPAs (e.g. DuckDuckGo's onion) may still render blank because
a custom scheme gets an opaque origin that breaks some web APIs. Server-rendered / mostly
static onion sites render fine. Onion reachability is flaky — many onions simply don't
respond; `start:` with no `response:` in the log means the onion is down/slow, not a bug.

## iOS 27 beta gotchas (each cost real debugging time)

1. **URLSession SOCKS proxy: the two APIs flip which one works per OS.**
   - Legacy `URLSessionConfiguration.connectionProxyDictionary` with `SOCKSEnable`
     issues the request and **never calls back** on iOS 27 (start fires, no response,
     no error — a silent hang). It worked on iOS 26.x.
   - Modern `URLSessionConfiguration.proxyConfigurations = [.init(socksv5Proxy:)]`
     works on iOS 27. Commit `96168a57` had switched to the legacy dict to dodge an
     *earlier* beta's broken modern API; 27 reversed it.
   - Lesson: don't hardcode one proxy API; the working one changes across betas.

2. **WebKit drops `URLProtocol` marker properties between `load()` and
   `decidePolicyFor` on iOS 27.** The universal-link workaround relied on that marker
   to avoid re-processing its own re-issued navigation, so every page load
   cancel-reloaded itself forever (thousands of identical rewrites in the console;
   totally blank on device). Fix: also match the re-issued navigation by URL, and only
   apply the workaround to plain http/https.

3. **Simulator (26.5) ≠ device (27).** The rendering/hang bugs did NOT reproduce in the
   26.5 simulator. Always confirm on the physical iOS 27 device.

## Why the old scheme-handler approach was abandoned as default

`TorSchemeHandler` rewrote `.onion` requests to `torhttp`/`torhttps` custom schemes,
fetched them via URLSession+SOCKS, then rewrote the HTML/CSS/CSP so subresources also
went through the scheme. It fetched main HTML fine (200s) but rendered blank on real
sites because:

- SPAs (e.g. DuckDuckGo's onion) never got their JS chunks executing correctly.
- Redirects, CSP host-source matching, and relative-URL resolution were fragile.

Real bugs were fixed in it before the pivot (kept behind the flag): stripping
`Content-Encoding`/`Transfer-Encoding`/`Content-Length` before delivery (WebKit was
told the body was gzip while it was already decoded → blank), resolving subresource
URLs via `absoluteURL`, inserting the injected `<base>` after `<head>` (not before
`<!DOCTYPE>`), and appending tor-scheme twins to `.onion` CSP host sources.

## Page persistence across app switching (cache)

Problem: iOS stops the background task (~30s after backgrounding) → `terminate()`
stops Tor; iOS also reclaims the WKWebView content process. So returning to a tab used
to restart Tor and refetch the whole page through a fresh circuit.

Fix: `TorSchemeHandler` keeps an **in-memory** (never on disk, for privacy),
LRU-bounded cache of fully-rewritten `.onion` responses.

The cache is a **FALLBACK, not the primary source** — this matters. Always fetch fresh
when Tor is reachable; serve cache only when the fetch errors or Tor is unreachable
(e.g. mid-restart after an app switch). Cache-FIRST caused a redirect loop: a market
entry page that redirects through a verification/signin flow (site A → signin → back to
A) kept getting served the stale cached entry page on every bounce, so it never resolved
— looked like the site was broken though it was reachable. Fetching fresh lets
redirect/auth flows settle while still surviving app switches (Tor down → cache fills in).
- TTL: `Settings.torCacheSeconds` (default 24h; `0` disables). `TorSchemeHandler.clearCache()`
  wipes it.
- Session uses `waitsForConnectivity = false` so a dropped Tor connection errors promptly
  (→ cache fallback) instead of hanging with no response. 60s request / 90s resource
  timeout for slow onion connects.
- `webViewWebContentProcessDidTerminate` reloads (cache fills in if Tor is down).
- `refresh(forceReload:)` sends `Cache-Control: no-cache` — wired to reload button,
  pull-to-refresh, Cmd-R, new-circuit.

## Features in place

- **Tor toggle**: Settings → "Built-in Tor for .onion Sites" (`SettingsViewController`).
  Flips `Settings.useBuiltInTor` live in both directions, starting/stopping Tor and
  reiniting tabs.
- **Onion toolbar icon (top right, `torBt`)**: green = Tor connected, red = enabled but
  not connected, accent/purple = built-in Tor off. Set in
  `BrowsingViewController.updateChrome()`.
- **Bookmark import**: Bookmarks screen → down-arrow button → document picker for
  Netscape-format `.html` (Safari via Mac, Chrome, Onion Browser exports).
  `BookmarksViewController` + `MozillaBookmarks`.
- **DEBUG status strip**: own row under the URL bar showing app version/build, Tor
  status, SOCKS port, `Scheme:` (yes = scheme handler, no = native proxy),
  `builtInTor`, tab count. DEBUG builds only.

## Build / deploy / test workflow

Physical device is "Portatus XVII Pro Max", id `00008150-0002402A2220401C`, iOS 27.0.
Bundle id `com.chibitek.onionbrowser`, team `DF9FB764AR`.

```sh
# Build for device (use generic/platform=iOS if the device is busy)
xcodebuild -workspace OnionBrowser.xcworkspace -scheme OnionBrowser -configuration Debug \
  -destination 'platform=iOS,id=00008150-0002402A2220401C' -allowProvisioningUpdates build

# Install + launch over WiFi (no cable needed)
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/OnionBrowser-*/Build/Products/Debug-iphoneos/OnionBrowser.app | head -1)
xcrun devicectl device install app --device 00008150-0002402A2220401C "$APP"
xcrun devicectl device process launch --terminate-existing --console \
  --device 00008150-0002402A2220401C com.chibitek.onionbrowser   # --console streams logs

# Simulator (faithful for code logic, but NOT for iOS 27 network/WebKit behavior)
xcrun simctl openurl <UDID> "onionhttps://<addr>.onion"   # onionhttps:// scheme opens THIS app
xcrun simctl io <UDID> screenshot out.png
```

Notes:
- `devicectl` has **no** `open-url` command — you can't drive a URL to the device
  headlessly. Use the simulator for URL-driven tests, or the device's restored tabs.
- The workspace/Pods aren't checked into the worktree cleanly; a `pod install` needs
  `LANG=en_US.UTF-8` set or CocoaPods 1.16 crashes on ASCII-8BIT normalization.
- Device build fix: `EAGER_LINKING = NO` for pod targets (in the Podfile post_install),
  else the Tor pod fails to link ("can't link a dylib with itself") on device.

## Build number

`OBBundleVersion` = `<minutes since 2026-06-24>.<decimalized short git hash>` generated
by `build-util/mk_build_versions.sh` in the OBVersion target. The fractional part
identifies the exact commit — handy for spotting a stale install from a screenshot.
Incremental builds sometimes skip regenerating `version.h`; a clean build refreshes it.
