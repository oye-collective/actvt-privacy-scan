//
//  ClaudeProcessRegistry.swift
//  ActvtSessionsKit
//

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Claude Code's own record of its running processes: one `<pid>.json` per
/// process in `sessions/`, beside the config directory's `projects/`, naming
/// the session it is running and when the process started (`procStart`).
///
/// A session is live when an entry names it, that pid exists, and the pid's
/// start time is the recorded one, so a pid the system has since reused for
/// something else doesn't count. Claude Code records the start the way its
/// platform reports it: field 22 of `/proc/<pid>/stat` on Linux (clock ticks
/// since boot), `LC_ALL=C TZ=UTC ps -o lstart=` on macOS
/// ("Mon Oct  5 12:55:14 2026").
struct ClaudeProcessRegistry: Sendable {
    let liveSessionIds: Set<String>

    /// The registry beside a `projects` root, or nil when there is none: an
    /// older Claude Code, or a root that isn't a config directory's
    /// `projects` (Claude Desktop's). Nothing can then be said about liveness.
    init?(projectsRoot: URL, isAlive: (_ pid: Int32, _ procStart: String) -> Bool = Self.isAlive(pid:procStart:)) {
        let directory = projectsRoot.standardizedFileURL.deletingLastPathComponent()
            .appendingPathComponent("sessions", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        var live = Set<String>()
        for name in names where name.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(name).path),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  isAlive(entry.pid, entry.procStart)
            else { continue }
            live.insert(entry.sessionId)
        }
        liveSessionIds = live
    }

    private struct Entry: Decodable {
        let pid: Int32
        let sessionId: String
        let procStart: String
    }

    /// Whether `pid` runs now and started when `procStart` says.
    static func isAlive(pid: Int32, procStart: String) -> Bool {
        guard pid > 0 else { return false }
        #if os(Linux)
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8) else { return false }
        return linuxStartTime(stat: stat) == procStart
        #else
        guard let started = darwinStartTime(pid: pid), let recorded = parseLstart(procStart) else { return false }
        return Int64(started.timeIntervalSince1970) == Int64(recorded.timeIntervalSince1970)
        #endif
    }

    /// Field 22 of a `/proc/<pid>/stat` line. The command name (field 2) is
    /// parenthesised and may hold spaces, so fields are counted after its
    /// closing parenthesis, where field 3 comes first.
    static func linuxStartTime(stat: String) -> String? {
        guard let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        return fields.count > 19 ? String(fields[19]) : nil
    }

    /// `ps -o lstart` in the C locale and UTC: "Mon Oct  5 12:55:14 2026".
    /// The day is space-padded, so runs of spaces are collapsed first.
    static func parseLstart(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: text.split(separator: " ").joined(separator: " "))
    }

    #if !os(Linux)
    static func darwinStartTime(pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
    #endif
}
