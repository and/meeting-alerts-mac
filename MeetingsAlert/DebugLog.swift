import Foundation

/// Diagnostic logging that is compiled out of release builds.
///
/// Release builds are produced without `-DDEBUG` (see `scripts/release.sh`), so calls
/// to this function cost nothing and emit nothing in the app users install.
@inline(__always)
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[MeetingsAlert] \(message())")
    #endif
}
