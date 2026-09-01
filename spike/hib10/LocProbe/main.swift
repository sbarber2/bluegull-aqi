// bluegull-aqi-hib.10 question 5: does a HEADLESS, launchd-started helper with
// no location grant produce a usable permission prompt?
//
// This is the last unmeasured thing in the hib epic, and under hib.6 -- where
// the helper becomes the SOLE location owner -- it is the entire first-run
// experience. The 2026-08-12 spike came close but never ran this case: it
// tested (A) a helper launched by hand with `open`, which prompted fine, and
// (B) a helper launched by launchd WITH THE GRANT ALREADY IN PLACE, which
// needed no prompt. The untested cell is launchd-started AND ungranted.
//
// EXPERIMENTAL DESIGN -- one variable only. This deliberately reuses the exact
// shape the 2026-08-12 spike proved works when user-launched: an LSUIElement
// .app bundle with a real Info.plist carrying NSLocationWhenInUseUsageDescription,
// not the bare `tool` target the other spike agents use. If a bare tool failed
// to prompt we could not tell "headless processes cannot prompt" from "an
// embedded __info_plist section is not read for usage descriptions" -- and with
// only one shot per bundle id, an ambiguous result is a wasted experiment.
// Known-good bundle shape, one variable changed: who started the process.
//
// ONE SHOT. The locationd grant this may create cannot be removed -- tccutil
// has no authority over it and fails -10814 (hib.2). Re-running honestly means
// bumping the numeric suffix on the bundle id in project.yml, which is the only
// available reset.

import AppKit
import CoreLocation
import os

let log = Logger(subsystem: "solutions.bluegull.hib10", category: "locprobe")

func stamp(_ date: Date = Date()) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

func describe(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: "notDetermined(0)"
    case .restricted: "restricted(1)"
    case .denied: "denied(2)"
    case .authorizedAlways: "authorizedAlways(3)"
    @unknown default: "unknown(\(status.rawValue))"
    }
}

final class Probe: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let started = Date()
    private var sawCallback = false

    func run() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "(none)"

        // ppid tells us who started us. 1 means launchd, which is the whole
        // point; anything else means this was run by hand and the result does
        // not answer the question.
        log.notice("""
        PROBE_START pid=\(pid, privacy: .public) ppid=\(getppid(), privacy: .public) \
        bundle=\(bundleID, privacy: .public) at=\(stamp(self.started), privacy: .public)
        """)

        manager.delegate = self

        let before = manager.authorizationStatus
        log.notice("""
        STATUS_BEFORE \(describe(before), privacy: .public) \
        servicesEnabled=\(CLLocationManager.locationServicesEnabled(), privacy: .public)
        """)

        guard before == .notDetermined else {
            // The grant already exists, so this bundle id is burnt and the
            // result is meaningless. Say so loudly rather than reporting a
            // false pass.
            log.error("""
            ABORT bundle=\(bundleID, privacy: .public) already has a decided status \
            \(describe(before), privacy: .public) -- this identifier is spent, \
            bump the suffix in project.yml for a real first-run test
            """)
            exit(3)
        }

        log.notice("REQUESTING_AUTHORIZATION at=\(stamp(), privacy: .public) -- watch for a prompt now")
        manager.requestWhenInUseAuthorization()

        // If no delegate callback arrives at all, that is the finding: a
        // headless process cannot even get an answer, let alone a prompt.
        // Bounded so this cannot sit forever holding a launchd transaction --
        // the same defect fixed in the shipping app as 10h.22.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, !self.sawCallback else { return }
            log.error("""
            NO_CALLBACK after 120s -- status still \(describe(self.manager.authorizationStatus), privacy: .public). \
            A headless launchd-started process got NO authorization response at all.
            """)
            exit(4)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        sawCallback = true
        let elapsed = Date().timeIntervalSince(started)
        let status = manager.authorizationStatus
        log.notice("""
        AUTH_CHANGED \(describe(status), privacy: .public) \
        after=\(String(format: "%.1f", elapsed), privacy: .public)s at=\(stamp(), privacy: .public)
        """)

        switch status {
        case .notDetermined:
            log.notice("...still undecided; prompt presumably on screen and unanswered")
        case .authorizedAlways:
            log.notice("GRANTED -- requesting a fix to confirm it is real, not just a status")
            manager.requestLocation()
        case .denied, .restricted:
            log.error("REFUSED status=\(describe(status), privacy: .public) -- see the write-up for what this means for hib.6")
            exit(0)
        @unknown default:
            exit(0)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        log.notice("""
        GOT_FIX accuracy=\(Int(l.horizontalAccuracy), privacy: .public)m \
        after=\(String(format: "%.1f", Date().timeIntervalSince(self.started)), privacy: .public)s \
        -- a headless launchd-started helper resolved location from a cold grant
        """)
        exit(0)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log.error("FIX_FAILED \(error.localizedDescription, privacy: .public)")
        exit(0)
    }
}

let probe = Probe()
NSApplication.shared.setActivationPolicy(.accessory)
probe.run()
NSApplication.shared.run()
