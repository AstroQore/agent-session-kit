import Darwin
import Foundation

/// Resolves the user's real home directory.
///
/// Session stores live in the *real* home directory, which is not always
/// what Foundation reports. In an unsandboxed process every "home" API
/// returns `/Users/<you>` and this is equivalent to `NSHomeDirectory()`;
/// under the macOS App Sandbox those APIs return the app's container
/// instead, where no CLI has ever written a rollout.
///
/// The implementation uses `getpwuid(getuid()).pw_dir`, empirically the
/// only Foundation-adjacent API that keeps returning the real home in
/// both cases. It exists as one named entry point so a host that later
/// gains or loses the sandbox does not have to audit every path in every
/// adapter.
///
/// This is a *convenience*, not a policy: the adapters take an explicit
/// `homeDirectory`, and tests point that at a temporary tree.
public enum RealHomeDirectory {
    public static var path: String {
        if let pw = getpwuid(getuid()) {
            let dir = String(cString: pw.pointee.pw_dir)
            if !dir.isEmpty { return dir }
        }
        return NSHomeDirectory()
    }

    public static var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}
