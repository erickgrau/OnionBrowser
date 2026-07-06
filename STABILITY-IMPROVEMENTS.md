# OnionBrowser Stability Improvements

This document summarizes the critical stability fixes implemented in OnionBrowser version 3.4.1 to resolve issues preventing reliable use of .onion services, particularly for shopping and authentication workflows on iOS 27 beta.

## Overview

The fixes address the core problems of cart disappearance, PGP token timeouts, and login session loss that were preventing reliable use of .onion marketplaces and services. These improvements make OnionBrowser a stable platform for accessing .onion services on iOS 27 beta.

## Key Fixes Implemented

### Session Persistence
- **Cookie Preservation**: Fixed cookie wipe on every navigation and preserved all Set-Cookie headers
- **Shared Cookie Jars**: Write parsed cookies to both URLSession and WebKit cookie stores for consistency
- **Disk-Backed Storage**: Enable persistent cookie storage so sessions survive app restarts
- **SameSite Cookies**: Set mainDocumentURL to ensure SameSite cookies are sent on .onion requests

### Tab Management
- **Background Handling**: Changed default from clearOnBackground to forgetOnShutdown to prevent losing sessions during app switches
- **Page Reload Prevention**: Prevent page reloads on foreground that reset PGP token challenges

### Tor Connection Stability
- **iOS 27 Compatibility**: Switched to modern ProxyConfiguration API to fix SOCKS proxy issues
- **Timeout Handling**: Implemented proper timeout handling to prevent indefinite hangs
- **Error Recovery**: Added cache fallback when live fetches fail

### Cache Behavior
- **Fallback Only**: Cache acts as fallback only (not primary source) to prevent redirect loops
- **Configurable TTL**: 24-hour default TTL with user-configurable settings

### Authentication Workflows
- **CSRF Protection**: Fixed SameSite cookie handling for CSRF-protected login flows
- **Multi-Step Flows**: Enable complex authentication flows to complete successfully
- **PGP Token Support**: Preserve sessions during PGP token verification workflows

## Technical Details

### Cookie Handling Improvements
```swift
// Parse ALL cookies from response headers
let cookies = HTTPCookie.cookies(withResponseHeaderFields: rawHeaders, for: finalURL)

// Write to both cookie stores for consistency
Self.sharedCookieStorage?.setCookies(cookies, for: finalURL, mainDocumentURL: finalURL)
let webStore = webView?.configuration.websiteDataStore.httpCookieStore
for cookie in cookies {
    webStore?.setCookie(cookie)
}
```

### Tor Connection Management
```swift
// Modern ProxyConfiguration API for iOS 27 compatibility
config.proxyConfigurations = [.init(socksv5Proxy: proxy)]

// Timeout handling to prevent hangs
config.waitsForConnectivity = false
config.timeoutIntervalForRequest = 60
config.timeoutIntervalForResource = 90
```

### Cache Behavior
```swift
// Cache is a FALLBACK, not the primary source
func serveFromCacheOrFail(_ fallbackError: Error) {
    // Only serve from cache when Tor can't be reached
    // This prevents redirect loops in authentication flows
}
```

## User Experience Improvements

### Shopping Cart Persistence
- Carts no longer disappear when users switch apps for PGP token decryption

### PGP Token Verification
- Token verification no longer resets when switching between apps, eliminating restarts

### Login Session Management
- Authentication sessions persist across app switches and restarts

### Multi-Step Authentication
- Complex login flows with multiple redirects now complete successfully

## Testing and Validation

### iOS 27 Beta Compatibility
- Verified SOCKS proxy configuration works with modern ProxyConfiguration API
- Confirmed no hangs or connection issues on iOS 27
- Tested app switching scenarios with PGP token workflows

### Session Persistence Testing
- Verified cookies persist through app backgrounding/foregrounding
- Confirmed sessions survive app restarts
- Tested multi-tab session consistency

### Authentication Flow Testing
- Validated complex login flows with multiple redirects
- Tested CSRF token handling in authentication
- Verified PGP token workflows complete successfully

## Configuration

### Tab Security Settings
```
Settings.tabSecurity = .forgetOnShutdown  // Recommended setting
// NOT .clearOnBackground which wipes tabs on every app switch
```

### Cache Configuration
```
Settings.torCacheSeconds = 24 * 60 * 60  // 24 hours default
// Set to 0 to disable caching if needed
```

### Timeout Settings
```swift
config.timeoutIntervalForRequest = 60   // 60 seconds for requests
config.timeoutIntervalForResource = 90  // 90 seconds for resources
config.waitsForConnectivity = false     // Error promptly on connectivity issues
```

## Impact

These fixes transform OnionBrowser from an unstable browser that couldn't reliably complete shopping or authentication workflows to a stable platform that can handle complex .onion site interactions, including:

1. Multi-step login processes with CSRF protection
2. Shopping cart management through app switches for PGP token decryption
3. PGP token verification without session loss
4. Session persistence across app restarts
5. Reliable Tor connectivity on iOS 27 beta

The improvements maintain the privacy-focused design of OnionBrowser while significantly improving usability and reliability for real-world use cases.