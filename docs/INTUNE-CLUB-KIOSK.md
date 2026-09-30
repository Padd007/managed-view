# Club kiosk configuration

This fork resolves club-specific URLs locally. It does not discover the device hostname or serial itself: Intune supplies the serial through managed app configuration. No redirect service is required.

## Deployment

1. Build/sign this fork under your organisation's own bundle ID. Do not reuse the original app's identity. Keep signing credentials outside Git.
2. Distribute the signed app through an approved route and make it managed by Intune. An Xcode-installed development build alone does not prove managed configuration delivery.
3. Create an iOS/iPadOS **Managed devices** app configuration policy targeting your app and assign it to the kiosk device group.
4. Supply the settings below. All four are **String** values, including the JSON objects/arrays.
5. Use Intune's device restriction policy to enforce Single App Mode on your app's bundle ID. This fork does not request or release Autonomous Single App Mode itself.

| Key | Example | Meaning |
| --- | --- | --- |
| `URL_TEMPLATE` | `https://provider.example/display?club={clubCode}` | Fixed HTTPS origin with a club placeholder in the path or query |
| `DEVICE_SERIAL` | `{{serialnumber}}` | Intune substitutes each receiving device's serial |
| `CLUB_MAPPING` | `{"SERIAL-A":"0123","SERIAL-B":"5678"}` | Full serial-to-club mapping; club codes are strings to preserve leading zeroes |
| `ALLOWED_HOSTS` | `["login.provider.example"]` | Optional additional exact hosts for navigation and embedded frames; the homepage host is always included |

Use **one policy**, containing all club mappings, across the fleet. Every device receives the complete mapping. Keep the real mapping in Intune, not this public repository. Do not put secrets in these settings or in URLs.

Changing the mapping/template updates the browser after Intune delivers the changed configuration. The app discards old browser history and clears the persistent web session when its configured home URL changes. It also clears the persistent session at app startup. This deliberately requires any website login to be re-established after an app restart.

To use a single fixed URL instead, set `URL` to its full HTTPS address and omit **all three** mapping keys. If any mapping key is present, mapping mode takes precedence. An incomplete mapping never falls back to `URL`.

## Intune XML example

Use the inner dictionary for Intune's XML configuration editor. Replace only the example domain and serial-to-club mapping. Keep `{{serialnumber}}` exactly as shown.

```xml
<dict>
  <key>URL_TEMPLATE</key>
  <string>https://provider.example/display?club={clubCode}</string>
  <key>DEVICE_SERIAL</key>
  <string>{{serialnumber}}</string>
  <key>CLUB_MAPPING</key>
  <string>{"SERIAL-A":"0123","SERIAL-B":"5678"}</string>
  <key>ALLOWED_HOSTS</key>
  <string>["login.provider.example"]</string>
  <key>BROWSER_MODE</key>
  <string>OFF</string>
</dict>
```

If your URL contains multiple query parameters, use `&amp;` instead of `&` in XML. Intune's XML parser decodes that once; no extra `DECODE_URL` setting is normally necessary.

## Security behaviour and compatibility changes

- Normal iPadOS certificate validation always applies. `DISABLE_TRUST` is ignored; there is no certificate bypass.
- HTTPS is required, using the default port or explicit port 443. URLs with embedded credentials, unresolved placeholders or malformed hostnames are rejected.
- Website navigation, redirects checked by WebKit delegates, QR destinations and popups must use the homepage host or an exact additional allowed hostname. Subdomains are **not** automatically allowed. Do not list a URL, wildcard or port in `ALLOWED_HOSTS`.
- This is a browser navigation restriction, **not a network firewall**. It does not restrict every image, script, fetch request or other subresource loaded by approved web content. The website and any required network-level controls still need review.
- No developer-hosted fallback page. Missing configuration shows a local waiting message; invalid or unmapped configuration shows a local error and removes the previous browser.
- External `managedview://` deep links are disabled. Intune controls the destination.
- `REMOTE_LOCK`, `QUERY_URL_STRING` and `DISABLE_APP_CONFIG_LISTENER` no longer apply. Intune controls lockdown, and configuration changes/removal are always observed.
- Application debug logging of URLs, configuration and QR values is removed. This does not control logging performed by the website or operating system.
- Serial matching ignores surrounding whitespace and letter case. Club codes must contain 1–32 ASCII letters, digits, hyphens or underscores. Duplicate serials after normalisation are rejected.
- Existing UI switches remain ON/OFF strings; malformed types are rejected. `LAUNCH_DELAY` allows 0–300 seconds, reset timers 0–86400 seconds and brightness -1–100. Warning time must be smaller than reset time.
- Optional QR scanning, browser navigation controls and popup support remain off by default. `REDIRECT_SUPPORT=ALT` allows at most three additional web views.
- The app still uses Apple WebKit. Keep iPadOS updated independently of app updates.

## Development tests

On the Mac, from the repository directory:

```sh
bash Tests/run-tests.sh
```

This compiles the same Foundation-only parser used in the app and exercises mapping, URL validation, allowlisting, malformed configuration, leading zeroes, unexpanded tokens and timer ranges.

An Actions workflow also runs these checks and builds an unsigned iPad simulator app. If workflows are disabled for the fork, enable Actions in GitHub before expecting results. No signing secrets are required for this workflow.

An app run directly from Xcode will display **Waiting for configuration from Intune** until configured. To test the UI in an iOS simulator before managed deployment, terminate the app and use the simulator's defaults command (replace the bundle ID with your test app's actual ID), then launch it again:

```sh
xcrun simctl spawn booted defaults write YOUR.BUNDLE.ID com.apple.configuration.managed -dict URL https://provider.example/display
```

This is a simulator-only test; it is not a mechanism for production iPads.

Before production, test on a managed physical iPad:

1. Configuration arrives after app launch; no manual first webpage launch is needed.
2. Two devices receive the same policy and resolve different clubs, including a code with a leading zero.
3. Missing serial, unresolved token, bad JSON and wrong value types show errors without displaying an old club or crashing.
4. Remove/reapply the policy; browsing stops and then recovers.
5. Change a device's club while it has an active session; old history/session is cleared and the correct page appears.
6. Invalid/self-signed certificates fail, including when a legacy `DISABLE_TRUST` value is supplied.
7. Off-list links, redirects, QR URLs and popups are blocked; approved login redirects still work.
8. Test restart, Wi-Fi loss/recovery and the real website's authentication, forms and session clearing while locked by Intune.

Automated checks do not replace physical-device, Intune, website or InfoSec review.
