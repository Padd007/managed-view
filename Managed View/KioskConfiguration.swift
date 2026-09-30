import Foundation
import CoreFoundation

/// Validates MDM input before any of it reaches the browser. No device discovery or networking.
struct KioskConfiguration {
    struct ConfigurationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let homeURL: URL
    let allowedHosts: Set<String>
    let switches: [String: String]
    let integers: [String: Int]
    let userAgent: String

    static func parse(_ values: [String: Any]) throws -> KioskConfiguration {
        func string(_ key: String, default fallback: String = "") throws -> String {
            guard let value = values[key] else { return fallback }
            guard let text = value as? String else {
                throw ConfigurationError(message: "\(key) must be a string.")
            }
            return text
        }

        var switches: [String: String] = [:]
        for key in ["MAINTENANCE_MODE", "BROWSER_MODE", "BROWSER_BAR_NO_EDIT",
                    "PRIVATE_BROWSING", "QR_CODE", "DETECT_SCROLL", "AUTO_OPEN_POPUP",
                    "RESET_TIMER_ON_HOME", "DECODE_URL"] {
            let value = try string(key, default: "OFF")
            guard value == "ON" || value == "OFF" else {
                throw ConfigurationError(message: "\(key) must be ON or OFF.")
            }
            switches[key] = value
        }
        let redirect = try string("REDIRECT_SUPPORT", default: "OFF")
        guard ["ON", "OFF", "ALT"].contains(redirect) else {
            throw ConfigurationError(message: "REDIRECT_SUPPORT must be ON, OFF or ALT.")
        }
        switches["REDIRECT_SUPPORT"] = redirect

        var integers: [String: Int] = [:]
        let limits: [String: ClosedRange<Int>] = [
            "LAUNCH_DELAY": 0...300, "RESET_TIMER": 0...86400,
            "RESET_TIMER_WARNING": 0...86400, "BRIGHTNESS": -1...100
        ]
        for (key, range) in limits {
            let fallback = key == "BRIGHTNESS" ? -1 : 0
            guard let raw = values[key] else { integers[key] = fallback; continue }
            let value: Int?
            if let text = raw as? String {
                value = Int(text)
            } else if let number = raw as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID() {
                // Reject fractional numbers rather than truncating them.
                value = Int(number.stringValue)
            } else {
                value = nil
            }
            guard let parsed = value, range.contains(parsed) else {
                throw ConfigurationError(message: "\(key) must be a whole number in \(range).")
            }
            integers[key] = parsed
        }
        let timer = integers["RESET_TIMER"] ?? 0
        let warning = integers["RESET_TIMER_WARNING"] ?? 0
        guard warning == 0 || (timer > 0 && warning < timer) else {
            throw ConfigurationError(message: "RESET_TIMER_WARNING must be smaller than RESET_TIMER.")
        }

        var address: String
        // Any mapping key selects mapping mode. Never fall back to a static URL on a mapping error.
        let mappingMode = ["URL_TEMPLATE", "DEVICE_SERIAL", "CLUB_MAPPING"].contains { values[$0] != nil }
        if mappingMode {
            let template = try string("URL_TEMPLATE")
            let serial = try string("DEVICE_SERIAL").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !serial.isEmpty, !serial.contains("{{"), !serial.contains("}}") else {
                throw ConfigurationError(message: "DEVICE_SERIAL is missing or its Intune token has not resolved.")
            }
            let mappingJSON = try string("CLUB_MAPPING")
            guard mappingJSON.utf8.count <= 100_000,
                  let data = mappingJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let mapping = object as? [String: String], !mapping.isEmpty else {
                throw ConfigurationError(message: "CLUB_MAPPING must be a JSON object of serial numbers and string club codes.")
            }
            var normalized: [String: String] = [:]
            let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
            for (key, code) in mapping {
                let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard !normalizedKey.isEmpty, normalized[normalizedKey] == nil,
                      !code.isEmpty, code.utf8.count <= 32,
                      code.unicodeScalars.allSatisfy({ permitted.contains($0) }) else {
                    throw ConfigurationError(message: "CLUB_MAPPING contains a duplicate serial or invalid club code. Use 1–32 letters, digits, hyphens or underscores.")
                }
                normalized[normalizedKey] = code
            }
            guard let code = normalized[serial] else {
                throw ConfigurationError(message: "This iPad has no club assignment. Contact IT.")
            }
            guard template.contains("{clubCode}"),
                  let marker = template.range(of: "://") else {
                throw ConfigurationError(message: "URL_TEMPLATE must be an HTTPS URL containing {clubCode}.")
            }
            let authority = template[marker.upperBound...].prefix { !["/", "?", "#"].contains($0) }
            guard !authority.contains("{clubCode}"), !template.contains("#") else {
                throw ConfigurationError(message: "Place {clubCode} only in the URL path or query, not the hostname or fragment.")
            }
            address = template.replacingOccurrences(of: "{clubCode}", with: code)
        } else {
            address = try string("URL")
        }
        if switches["DECODE_URL"] == "ON" {
            // Intune already parses XML entities. This only supports explicitly double-encoded query separators.
            address = address.replacingOccurrences(of: "&amp;", with: "&")
        }
        guard !address.contains("{"), !address.contains("}"),
              let url = URL(string: address), isSecureWebURL(url), let host = url.host else {
            throw ConfigurationError(message: "Configure a valid HTTPS URL without credentials, unresolved placeholders or a nonstandard port.")
        }

        var hosts: Set<String> = [host.lowercased()]
        if values["ALLOWED_HOSTS"] != nil {
            let json = try string("ALLOWED_HOSTS")
            guard json.utf8.count <= 10_000, let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let extra = object as? [String] else {
                throw ConfigurationError(message: "ALLOWED_HOSTS must be a JSON array of exact hostnames.")
            }
            for item in extra {
                let host = item.lowercased()
                guard validHostname(host) else {
                    throw ConfigurationError(message: "ALLOWED_HOSTS must contain hostnames only, without wildcards, paths or ports.")
                }
                hosts.insert(host)
            }
        }
        let userAgent = try string("USER_AGENT")
        guard userAgent.utf8.count <= 1024, !userAgent.contains("\r"), !userAgent.contains("\n") else {
            throw ConfigurationError(message: "USER_AGENT is invalid.")
        }
        return KioskConfiguration(homeURL: url, allowedHosts: hosts, switches: switches,
                                  integers: integers, userAgent: userAgent)
    }

    func permits(_ url: URL) -> Bool {
        Self.isSecureWebURL(url) && url.host.map { allowedHosts.contains($0.lowercased()) } == true
    }

    private static func isSecureWebURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host,
              validHostname(host.lowercased()), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return true
    }

    private static func validHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let characters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.unicodeScalars.allSatisfy { characters.contains($0) }
        }
    }
}
