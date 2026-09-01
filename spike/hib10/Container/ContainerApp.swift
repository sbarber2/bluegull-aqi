// bluegull-aqi-hib.10 spike container.
//
// Stands in for BluegullAQI purely as the thing that owns the agent and can
// register it. Deliberately ugly and deliberately separate from the real app:
// this project exists to be thrown away once hib.1 is answered.
//
// Not LSUIElement, unlike the real app -- the spike needs a window and a Dock
// icon so it can actually be driven and, more importantly, so "quit it" is
// unambiguous. Questions 2 and 3 both hinge on the container being genuinely
// not running.

import ServiceManagement
import SwiftUI
import os

let log = Logger(subsystem: "solutions.bluegull.hib10", category: "container")

/// The two experiments, each an independently registrable agent so a single
/// reboot can answer both -- reboots are the slow part of this spike.
enum Variant: String, CaseIterable, Identifiable {
    case checkin = "solutions.bluegull.hib10.checkin"
    case register = "solutions.bluegull.hib10.register"
    case locprobe = "solutions.bluegull.hib10.locprobe"
    case machsvc = "solutions.bluegull.hib10.machsvc"

    var id: String { rawValue }
    var plistName: String { "\(rawValue).plist" }

    var title: String {
        switch self {
        case .checkin: "B — activity declared in the plist (LaunchEvents + CHECK_IN)"
        case .register: "A — activity registered in code (hib.5's proposal)"
        case .locprobe: "Q5 — headless first-run location prompt (ONE SHOT)"
        case .machsvc: "hib.11 — can this app start the agent on demand?"
        }
    }

    var note: String {
        switch self {
        case .checkin: "No RunAtLoad, no KeepAlive. If this wakes, the epic's design is real."
        case .register: "RunAtLoad, to give the code somewhere to run once. Watch for a SECOND pid."
        case .locprobe: "Fires ~30s after registering. WATCH THE SCREEN. Burns the bundle id either way."
        case .machsvc: "No RunAtLoad, no KeepAlive, no activity. If it runs, a connection started it."
        }
    }

    var service: SMAppService { SMAppService.agent(plistName: plistName) }
}

/// Lets the whole experiment be driven from a script instead of by clicking:
/// `HIB10_ACTION=register /Applications/Hib10Container.app/Contents/MacOS/Hib10Container`.
/// SMAppService resolves its plists relative to `Bundle.main`, so this has to
/// run from inside the installed bundle -- it cannot be a separate CLI tool.
/// Runs before any window appears and exits immediately, which also makes
/// "the container app is not running" trivially true for questions 2 and 3.
func runHeadlessActionIfRequested() {
    guard let action = ProcessInfo.processInfo.environment["HIB10_ACTION"] else { return }

    // The probe is excluded from the blanket action on purpose: it is
    // single-use, so it must never be registered as a side effect of
    // registering the other two. HIB10_ACTION=register-probe asks for it
    // explicitly, by name.
    let targets: [Variant]
    switch true {
    case action.hasSuffix("-probe"): targets = [.locprobe]
    case action.hasSuffix("-machsvc"): targets = [.machsvc]
    default: targets = Variant.allCases.filter { $0 != .locprobe && $0 != .machsvc }
    }
    let verb = action
        .replacingOccurrences(of: "-probe", with: "")
        .replacingOccurrences(of: "-machsvc", with: "")

    for variant in targets {
        let service = variant.service
        do {
            switch verb {
            case "ping":
                pingMachServices()
                exit(0)
            case "register": try service.register()
            case "unregister": try service.unregister()
            case "status": break
            default:
                FileHandle.standardError.write(Data("unknown HIB10_ACTION \(action)\n".utf8))
                exit(2)
            }
            print("\(verb) \(variant.rawValue): OK -> status=\(describe(service.status))")
            log.notice("\(verb, privacy: .public) \(variant.rawValue, privacy: .public): OK status=\(describe(service.status), privacy: .public)")
        } catch {
            let ns = error as NSError
            print("\(verb) \(variant.rawValue): FAILED \(ns.domain) \(ns.code) — \(ns.localizedDescription) -> status=\(describe(service.status))")
            log.error("\(verb, privacy: .public) \(variant.rawValue, privacy: .public): FAILED \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(ns.localizedDescription, privacy: .public)")
        }
    }
    exit(0)
}

/// hib.11. Tries each candidate mach service name in turn and reports what
/// happened. A refusal here is as informative as a success -- if the sandbox
/// blocks the app-group-prefixed name, hib.6's first-run design has to be
/// reworked before it is built, which is the point of asking now.
func pingMachServices() {
    let names = [
        "group.solutions.bluegull.aqi.hib10",   // app-group prefix: clean for review
        "G5DWPBWHQ5.hib10.svc",                 // team-id prefix: the fallback
    ]

    for name in names {
        let group = DispatchGroup()
        group.enter()
        var outcome = "no reply"

        let conn = xpc_connection_create_mach_service(name, nil, 0)
        xpc_connection_set_event_handler(conn) { event in
            // Errors arrive on this handler too. XPC_ERROR_CONNECTION_INVALID
            // is what a blocked or unknown name produces, and is the result
            // that would sink the design.
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                let desc = xpc_copy_description(event)
                outcome = "ERROR \(String(cString: desc))"
                free(desc)
            }
        }
        xpc_connection_resume(conn)

        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "ping", "hib.11")
        // NOT DispatchQueue.main: this runs from init(), before NSApplication
        // starts, and the group.wait() below blocks the calling thread -- which
        // is main. Dispatching the reply to main too would deadlock until the
        // timeout and read as "no reply" from a mechanism that worked fine.
        xpc_connection_send_message_with_reply(conn, msg, DispatchQueue.global()) { reply in
            if xpc_get_type(reply) == XPC_TYPE_DICTIONARY {
                let served = xpc_dictionary_get_string(reply, "served_by").map { String(cString: $0) } ?? "?"
                outcome = "REPLY from pid \(xpc_dictionary_get_int64(reply, "pid")) via \(served)"
            } else {
                let desc = xpc_copy_description(reply)
                outcome = "ERROR \(String(cString: desc))"
                free(desc)
            }
            group.leave()
        }

        _ = group.wait(timeout: .now() + 10)
        print("ping \(name): \(outcome)")
        log.notice("PING name=\(name, privacy: .public) outcome=\(outcome, privacy: .public)")
    }
}

func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown(\(status.rawValue))"
    }
}

@main
struct Hib10ContainerApp: App {
    init() { runHeadlessActionIfRequested() }

    var body: some Scene {
        Window("hib.10 spike", id: "main") {
            ContentView()
                .frame(minWidth: 620, minHeight: 420)
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @State private var transcript: [String] = []
    @State private var statuses: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("bluegull-aqi-hib.10")
                .font(.headline)
            Text("Register, then quit this app. Everything after that is launchd's doing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Variant.allCases) { variant in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(variant.title).font(.subheadline.bold())
                        Text(variant.note).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Register") { act("register", variant) { try variant.service.register() } }
                            Button("Unregister") { act("unregister", variant) { try variant.service.unregister() } }
                            Button("Status") { refresh(variant) }
                            Spacer()
                            Text(statuses[variant.rawValue] ?? "—")
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                    .padding(6)
                }
            }

            // The registered path is what SMAppService actually resolved, which
            // is worth seeing: registration records where the app was, so a
            // later move (Downloads -> Applications, say) is a real failure mode
            // and one worth catching here rather than blaming on the activity.
            Text("Bundle: \(Bundle.main.bundleURL.path)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            ScrollView {
                Text(transcript.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
        }
        .padding()
        .onAppear { Variant.allCases.forEach(refresh) }
    }

    private func act(_ what: String, _ variant: Variant, _ body: () throws -> Void) {
        do {
            try body()
            say("\(what) \(variant.rawValue): OK")
            log.notice("\(what, privacy: .public) \(variant.rawValue, privacy: .public): OK")
        } catch {
            // Question 1's most likely failure shape: register() throwing
            // because the plist carries a key SMAppService won't accept. The
            // NSError domain/code matters more than the message here, so print
            // both rather than localizedDescription alone.
            let ns = error as NSError
            say("\(what) \(variant.rawValue): FAILED \(ns.domain) \(ns.code) — \(ns.localizedDescription)")
            log.error("\(what, privacy: .public) \(variant.rawValue, privacy: .public): FAILED \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
        }
        refresh(variant)
    }

    private func refresh(_ variant: Variant) {
        statuses[variant.rawValue] = describe(variant.service.status)
    }

    private func say(_ line: String) {
        transcript.append("\(Date().formatted(date: .omitted, time: .standard))  \(line)")
    }
}
