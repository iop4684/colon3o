import Foundation
import ObjectiveC

/// Works around a LiveContainer bug that slowly used up every file descriptor.
///
/// When colon3o runs in LiveContainer as a shared app or in multitask mode, LiveContainer checks
/// every two seconds while the app is in the background whether any file the app has open is
/// locked (iOS ends apps that are suspended holding a lock on a shared file). Its check leaks one
/// descriptor per open file every time (it asks SQLite about each file, and for files that aren't
/// databases that call doesn't close what it opened). Within an hour or two of background
/// listening the app couldn't open anything: covers went blank, the library came up empty.
///
/// The check is replaced with one that opens nothing: it asks each descriptor the app already has
/// open whether this process holds a lock on it, and marks only those files the way
/// LiveContainer would.
enum LiveContainerFix {
    static func apply() {
        guard let fixClass = NSClassFromString("Dead10ccFix") else { return }  // Not in LiveContainer
        let selector = NSSelectorFromString("handleAppDidEnterBackgroundReal")
        guard let method = class_getInstanceMethod(fixClass, selector) else {
            Diagnostics.shared.log("LiveContainer's background file check has changed; left as it is", category: "app")
            return
        }
        let replacement: @convention(block) (AnyObject) -> Void = { _ in markLockedFiles() }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        Diagnostics.shared.log("Running in LiveContainer: replaced its background file check, which leaked open files",
                               category: "app")
    }

    /// LiveContainer's own name for "may be suspended while this file is locked".
    private static let attribute = "com.apple.runningboard.can-suspend-locked"
    /// F_GETLKPID: the lock a given process (here, this one) holds, from <sys/fcntl.h>.
    private static let getLockOfProcess: Int32 = 66

    private static func markLockedFiles() {
        let pid = getpid()
        var marked = Set<String>()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for fd in 0..<Int32(min(Int(getdtablesize()), 8192)) {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            var lock = flock()
            lock.l_type = Int16(F_WRLCK)
            lock.l_whence = Int16(SEEK_SET)
            lock.l_pid = pid
            guard fcntl(fd, getLockOfProcess, &lock) != -1, lock.l_type != Int16(F_UNLCK),
                  fcntl(fd, F_GETPATH, &path) != -1 else { continue }
            let file = String(cString: path)
            guard marked.insert(file).inserted else { continue }
            var value: UInt8 = 1
            setxattr(file, attribute, &value, 1, 0, 0)
        }
    }
}
