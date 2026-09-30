import Foundation

var checks = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { fatalError("FAIL: \(message)") }
}
func reject(_ values: [String: Any], _ message: String) {
    do {
        _ = try KioskConfiguration.parse(values)
        fatalError("FAIL: accepted \(message)")
    } catch { checks += 1 }
}

let basic: [String: Any] = ["URL": "https://provider.example/display?club=0123"]
let policy = try KioskConfiguration.parse(basic)
check(policy.homeURL.absoluteString == "https://provider.example/display?club=0123", "static URL preserved")
check(policy.permits(URL(string: "https://provider.example/other")!), "same-host navigation")
for address in ["http://provider.example/", "https://evil.example/", "https://provider.example.evil.example/",
                "https://sub.provider.example/", "https://user:password@provider.example/",
                "https://provider.example:8443/", "file:///etc/passwd", "javascript:alert(1)"] {
    check(!policy.permits(URL(string: address)!), "deny navigation: \(address)")
}
var mapping: [String: Any] = [
    "URL_TEMPLATE": "https://provider.example/display?club={clubCode}",
    "DEVICE_SERIAL": " serial-a ",
    "CLUB_MAPPING": "{\"SERIAL-A\":\"0123\",\"SERIAL-B\":\"5678\"}"
]
check(try KioskConfiguration.parse(mapping).homeURL == policy.homeURL, "mapping preserves leading zeroes")
mapping["DEVICE_SERIAL"] = "SERIAL-B"
check(try KioskConfiguration.parse(mapping).homeURL.absoluteString.hasSuffix("club=5678"), "second device resolves independently")
mapping["URL"] = "https://provider.example/fallback"
mapping["DEVICE_SERIAL"] = "UNKNOWN"
reject(mapping, "unmapped serial must not fall back to URL")
mapping["DEVICE_SERIAL"] = "{{serialnumber}}"
reject(mapping, "unresolved Intune token")
mapping["DEVICE_SERIAL"] = "SERIAL-A"
mapping["CLUB_MAPPING"] = "{\"SERIAL-A\":1234}"
reject(mapping, "numeric club codes")
mapping["CLUB_MAPPING"] = "{\"SERIAL-A\":\"1234&admin=true\"}"
reject(mapping, "query injection in club code")
mapping["CLUB_MAPPING"] = "{\"SERIAL-A\":\"1234\",\"serial-a\":\"5678\"}"
reject(mapping, "ambiguous normalized serial")
mapping["CLUB_MAPPING"] = "{\"SERIAL-A\":\"1234\"}"
mapping["URL_TEMPLATE"] = "https://{clubCode}.example/"
reject(mapping, "hostname substitution")
mapping["URL_TEMPLATE"] = "https://provider.example/#{clubCode}"
reject(mapping, "fragment substitution")
mapping["URL_TEMPLATE"] = "https://provider.example/clubs/{clubCode}/display"
check(try KioskConfiguration.parse(mapping).homeURL.path == "/clubs/1234/display", "path substitution")
reject([:], "missing configuration")
reject(["URL": "https://provider.example", "DEVICE_SERIAL": "SERIAL-A"], "incomplete mapping mode")
for address in ["", "http://provider.example", "https://user@provider.example", "https://provider.example:8443",
                "https://provider.example/?club={{serialnumber}}", "javascript:alert(1)"] {
    reject(["URL": address], "invalid home URL")
}
var extra = basic
extra["ALLOWED_HOSTS"] = "[\"login.example\"]"
let loginPolicy = try KioskConfiguration.parse(extra)
check(loginPolicy.permits(URL(string: "https://login.example/signin")!), "explicit login host")
check(!loginPolicy.permits(URL(string: "https://login.example.evil.example/")!), "allowlist suffix attack")
for hosts in ["[\"*.example\"]", "[\"https://login.example\"]", "[\"login.example:443\"]", "{}", "[1]"] {
    extra["ALLOWED_HOSTS"] = hosts
    reject(extra, "invalid host list")
}
for (key, value) in [("LAUNCH_DELAY", -1 as Any), ("LAUNCH_DELAY", 301), ("LAUNCH_DELAY", true),
                     ("LAUNCH_DELAY", 1.5), ("BRIGHTNESS", 101), ("BROWSER_MODE", true), ("URL", 123)] {
    var bad = basic
    bad[key] = value
    reject(bad, "incorrect type/range for \(key)")
}
var timers = basic
timers["LAUNCH_DELAY"] = "5"
check(try KioskConfiguration.parse(timers).integers["LAUNCH_DELAY"] == 5, "integer string accepted")
timers["RESET_TIMER"] = 60
timers["RESET_TIMER_WARNING"] = 60
reject(timers, "warning must precede reset")
timers["RESET_TIMER_WARNING"] = 10
check(try KioskConfiguration.parse(timers).integers["RESET_TIMER_WARNING"] == 10, "valid timer")
print("Passed \(checks) configuration and navigation checks.")
