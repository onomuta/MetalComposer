#if canImport(AppKit)
import AppKit

/// NSFont on macOS, UIFont on iOS. The two share the API Text Image uses.
package typealias PlatformFont = NSFont
#else
import UIKit

package typealias PlatformFont = UIFont
#endif

/// The app's translation of `key` (from its Localizable.strings), formatted with `arguments`; the
/// English key itself when there is none. Hosts that embed the engine get English.
package func loc(_ key: String, _ arguments: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .main, comment: "")
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}
