import Darwin
import Foundation
import os

@MainActor
enum StartupTiming {
    private static var logged = false

    static func logFirstWindow() {
        guard !logged else { return }
        logged = true
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return }
        let started = info.kp_proc.p_un.__p_starttime
        let start = Double(started.tv_sec) + Double(started.tv_usec) / 1e6
        DispatchQueue.main.async {
            let ms = Int((Date().timeIntervalSince1970 - start) * 1000)
            Logger(subsystem: "Helm", category: "startup").notice("startup: first window after \(ms) ms")
        }
    }
}
