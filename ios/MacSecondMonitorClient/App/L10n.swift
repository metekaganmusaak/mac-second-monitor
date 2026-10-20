import Foundation

/// Formatting for localized strings with arguments. Keys stay literal at the call sites
/// (`String(localized: "key")`) so Xcode can find them in the String Catalog.
enum L10n {
    static func format(_ format: String, _ arguments: any CVarArg...) -> String {
        String(format: format, locale: .current, arguments: arguments)
    }
}
