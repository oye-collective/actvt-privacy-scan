//
//  ClaudeProcessRegistry.swift
//  ActvtSessionParsers
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
public struct ClaudeProcessRegistry: Sendable {
    public let liveSessionIds: Set<String>
    /// What each live session's process says it is doing, for the sessions
    /// whose Claude Code writes it (2.1.221 and later). When two processes
    /// run one session, one at work is the answer.
    public let activities: [String: Activity]

    /// The registry beside a `projects` root, or nil when there is none: an
    /// older Claude Code, or a root that isn't a config directory's
    /// `projects` (Claude Desktop's). Nothing can then be said about liveness.
    public init?(projectsRoot: URL, isAlive: (_ pid: Int32, _ procStart: String) -> Bool = Self.isAlive(pid:procStart:)) {
        let directory = projectsRoot.standardizedFileURL.deletingLastPathComponent()
            .appendingPathComponent("sessions", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        var live = Set<String>()
        var activities: [String: Activity] = [:]
        for name in names where name.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(name).path),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  isAlive(entry.pid, entry.procStart)
            else { continue }
            live.insert(entry.sessionId)
            if let activity = Activity(status: entry.status, waitingFor: entry.waitingFor, needs: entry.needs,
                                       kind: entry.kind),
               activities[entry.sessionId] != .working {
                activities[entry.sessionId] = activity
            }
        }
        liveSessionIds = live
        self.activities = activities
    }

    private struct Entry: Decodable {
        let pid: Int32
        let sessionId: String
        let procStart: String
        /// `busy`, `shell`, `idle` or `waiting` (Claude Code 2.1.221 and later;
        /// `shell` while a shell command it started runs, which its own UI
        /// shows as working, 2.1.318).
        let status: String?
        /// Why it waits, only while `waiting`: `permission prompt`,
        /// `input needed`, `sandbox request` or `dialog open`.
        let waitingFor: String?
        /// What the user has to do, when Claude Code says (2.1.318): set on
        /// the dialogs it notifies about, such as a notice to acknowledge.
        let needs: String?
        /// `interactive` for a terminal or IDE session; the others (`bg`,
        /// `daemon`, `daemon-worker`) are runs nobody sits at.
        let kind: String?
    }

    /// What a Claude Code process says it is doing, from its own entry. Only
    /// Claude Code 2.1.221 and later write it; older entries say nothing.
    public enum Activity: Sendable, Equatable {
        /// `busy` or `shell`: working on a turn, however quiet its transcript is.
        case working
        /// `idle`: the turn is over and it sits at the prompt.
        case atPrompt
        /// `waiting` at a permission prompt, for an answer, or on a dialog that
        /// says what the user has to do (`needs`): the user is needed now.
        case needsUser
        /// `waiting` on a dialog the user opened themselves (`/model`,
        /// `/config`), which needs nothing of them.
        case inDialog
        /// A run nobody sits at (`claude -p`, the Agent SDK) that isn't busy.
        case unattended

        init?(status: String?, waitingFor: String?, needs: String? = nil, kind: String?) {
            let attended = kind == nil || kind == "interactive"
            switch status {
            case "busy", "shell": self = .working
            case "idle": self = attended ? .atPrompt : .unattended
            case "waiting":
                if !attended { self = .unattended }
                else { self = waitingFor == "dialog open" && needs == nil ? .inDialog : .needsUser }
            default: return nil
            }
        }
    }

    /// A process's own account of itself: the session it runs, and what it is
    /// doing when its Claude Code says.
    public struct Declaration: Sendable, Equatable {
        public let sessionId: String
        public let activity: Activity?

        public init(sessionId: String, activity: Activity?) {
            self.sessionId = sessionId
            self.activity = activity
        }
    }

    /// What process `pid` declares, from its entry in a config directory's
    /// registry (`<configDirectory>/sessions/<pid>.json`), when that entry was
    /// written for this very process: its `procStart` is `startedAt`, to the
    /// second. A pid reused since, or an entry left by a process that died,
    /// says nothing. Read every time it is asked, because one process can move
    /// to another session (`/clear`, `/resume`), and its status changes with
    /// every turn. macOS entries only: Linux records `procStart` in clock ticks.
    public static func declaredSession(pid: Int32, startedAt: Date, configDirectory: URL) -> Declaration? {
        let path = configDirectory.appendingPathComponent("sessions/\(pid).json").path
        guard let data = FileManager.default.contents(atPath: path),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.pid == pid,
              let recorded = parseLstart(entry.procStart),
              Int64(recorded.timeIntervalSince1970) == Int64(startedAt.timeIntervalSince1970)
        else { return nil }
        return Declaration(sessionId: entry.sessionId,
                           activity: Activity(status: entry.status, waitingFor: entry.waitingFor, needs: entry.needs,
                                              kind: entry.kind))
    }

    /// Whether `pid` runs now and started when `procStart` says.
    public static func isAlive(pid: Int32, procStart: String) -> Bool {
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
    /// One formatter for every read: the app asks on each sample, per running
    /// Claude Code process, and making a formatter cost more than the rest of
    /// the read (213 → 80 µs, B-057).
    private static let lstartFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()

    static func parseLstart(_ text: String) -> Date? {
        lstartFormatter.date(from: text.split(separator: " ").joined(separator: " "))
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
