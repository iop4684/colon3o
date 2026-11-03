import Foundation
import UIKit

/// Keeps colon3o's files readable while the iPhone is locked.
///
/// iOS can lock an app's files a few seconds after the phone locks (data protection), depending on
/// the class the files were given. Under LiveContainer the class comes from the host app, and
/// when it's the strict one, everything colon3o did in the background with the screen off (the
/// next song's cover, saving a playlist or an edit, reading the library) failed silently: covers
/// went missing and changes didn't stick, as if the app had lost its connection.
///
/// So colon3o's own folders and files are given the class iOS uses by default for apps ("until
/// the phone is first unlocked after a restart"). New files inherit it from their folder.
enum FileProtection {
    private static let doneKey = "fileProtection.relaxed.v1"

    /// Call at launch (the phone is unlocked then). The full walk over every file happens once;
    /// after that only the top folders are checked.
    static func relax() {
        observeLockState()
        let fileManager = FileManager.default
        let folders = [fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0],
                       fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                       fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]]
        let protection = (try? fileManager.attributesOfItem(atPath: folders[0].path))?[.protectionKey] as? FileProtectionType
        Diagnostics.shared.detail("File protection of Documents: \(protection?.rawValue ?? "unknown")", category: "app")
        let walkAll = !UserDefaults.standard.bool(forKey: doneKey)
        Task.detached(priority: .utility) {
            var changed = 0, failed = 0
            for folder in folders {
                apply(to: folder, changed: &changed, failed: &failed)
                guard walkAll, let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
                for case let url as URL in walker { apply(to: url, changed: &changed, failed: &failed) }
            }
            Diagnostics.shared.detail("File protection: \(changed) items set readable while locked, \(failed) failed"
                                   + (walkAll ? " (full pass)" : ""), category: "app")
            if walkAll, failed == 0 {
                await MainActor.run { UserDefaults.standard.set(true, forKey: doneKey) }
            }
        }
    }

    private static func apply(to url: URL, changed: inout Int, failed: inout Int) {
        let fileManager = FileManager.default
        let current = (try? fileManager.attributesOfItem(atPath: url.path))?[.protectionKey] as? FileProtectionType
        guard current == .complete || current == .completeUnlessOpen else { return }
        do {
            try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                          ofItemAtPath: url.path)
            changed += 1
        } catch {
            failed += 1
        }
    }

    /// Notes in the log when the files lock and unlock, to tell this apart from other problems.
    private static func observeLockState() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { _ in
            Diagnostics.shared.detail("Files are about to lock (phone locked)", category: "app")
        }
        center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { _ in
            Diagnostics.shared.detail("Files unlocked", category: "app")
        }
    }
}
