#if canImport(AppKit)
import AppKit

/// NSFont on macOS, UIFont on iOS. The two share the API Text Image uses.
package typealias PlatformFont = NSFont
#else
import UIKit

package typealias PlatformFont = UIFont
#endif
