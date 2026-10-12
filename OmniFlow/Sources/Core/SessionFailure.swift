import Foundation

/// Preserve the error the hook actually reported, without inventing a cause.
enum SessionFailure {
    static func message(from payload: [String: Any]) -> String {
        for key in ["error_details", "last_assistant_message", "message", "error_message"] {
            if let text = clean(payload[key]) { return text }
        }
        if let error = payload["error"] as? [String: Any], let text = clean(error["message"]) { return text }
        if let text = clean(payload["error"]) {
            return "The agent reported: \(text.replacingOccurrences(of: "_", with: " "))."
        }
        return "The agent stopped with an error but supplied no details. Check its session for the cause."
    }

    private static func clean(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(1200))
    }
}
