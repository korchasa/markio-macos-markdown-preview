import os

/// Shared `os.Logger` for the app. Subsystem `dev.markio` (per SDS §6); one
/// category per area. Used to surface failures that are otherwise best-effort
/// (JS-bridge calls, file opens) so they are visible in Console.app instead of
/// being silently swallowed — per the project's "fail fast, fail clearly" rule.
///
/// Convention: omit `privacy:` annotations at call sites (default privacy is
/// acceptable for this offline local viewer) — it keeps log lines under the
/// 100-column `swift-format` limit while still including paths/reasons.
enum Log {
    static let preview = Logger(subsystem: "dev.markio", category: "preview")
    static let app = Logger(subsystem: "dev.markio", category: "app")
}
