import Foundation

/// Detects and masks secret-looking values (API keys, tokens, credentials).
enum Secrets {

    /// Keys that usually hold secrets. Deliberately avoids bare "key"/"auth"
    /// to prevent false positives (keybindings, authorship…).
    private static let keyPattern = #"(?i)(api[-_.]?key|access[-_.]?key|secret|token|password|passwd|credential|private[-_.]?key|client[-_.]?secret|bearer|refresh)"#

    static func isSecretKey(_ key: String) -> Bool {
        key.range(of: keyPattern, options: .regularExpression) != nil
    }

    /// Mask values of secret keys in raw text (used for read-only source views).
    static func maskText(_ text: String, format: ConfigFormat) -> String {
        guard AppSettings.maskSecrets else { return text }
        switch format {
        case .json, .jsonc:
            return maskPattern(
                #"("(?:[^"\\]|\\.)*(?i:api[-_.]?key|secret|token|password|passwd|credential|private|bearer|refresh)(?:[^"\\]|\\.)*"\s*:\s*)"(?:\\.|[^"\\])*""#,
                in: text, replacement: #"$1"••••••••""#
            )
        case .toml:
            return maskPattern(
                #"((?i:[A-Za-z0-9_.-]*(?:api[-_.]?key|secret|token|password|passwd|credential|bearer|refresh)[A-Za-z0-9_.-]*)\s*=\s*)("[^"\n]*"|'[^'\n]*')"#,
                in: text, replacement: #"$1"••••••••""#
            )
        default:
            return text
        }
    }

    /// Does this file contain anything worth masking?
    static func containsSecrets(_ text: String, format: ConfigFormat) -> Bool {
        maskText(text, format: format) != text
    }

    private static func maskPattern(_ pattern: String, in text: String, replacement: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: replacement
        )
    }
}
