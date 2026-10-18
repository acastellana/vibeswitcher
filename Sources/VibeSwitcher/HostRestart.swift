import AppKit
import SwiftUI

/// Restarting an outdated session host, the same from the window's header, the menu bar and Settings.
extension HostClient.RestartPlan {
    /// "Restart Session Host (keeps sessions)", or what it ends; "…" when it asks first.
    var title: String {
        switch self {
        case .handOver: return "Restart Session Host (keeps sessions)"
        case .endAndReplace(0): return "Restart Session Host"
        case .endAndReplace(let live): return "Restart Session Host… (ends \(Self.sessions(live)) in all projects)"
        }
    }

    var help: String {
        switch self {
        case .handOver: return "Updates the session host to this app's version; the sessions keep running."
        case .endAndReplace(0): return "Updates the session host to this app's version; no session is running."
        case .endAndReplace(let live):
            return "The session host is older than this app and can't keep its sessions across a restart: restarting it ends \(Self.sessions(live)) in all projects."
        }
    }

    /// Only a restart that ends sessions asks first.
    var needsConfirmation: Bool {
        if case .endAndReplace(let live) = self { return live > 0 }
        return false
    }

    static func sessions(_ count: Int) -> String { count == 1 ? "1 session" : "\(count) sessions" }
}

enum HostRestart {
    /// Restarts the host as `plan` says, after an alert when it ends sessions.
    static func confirmAndRestart(_ host: HostClient) {
        guard let plan = host.restartOffer else { return }
        if plan.needsConfirmation, case .endAndReplace(let live) = plan {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Restart the session host and end \(HostClient.RestartPlan.sessions(live))?"
            alert.informativeText = "The session host is older than this app and can't hand its sessions over to the new one. "
                + "Restarting it ends every session it runs, in all projects, not only this window's."
            alert.addButton(withTitle: "End \(HostClient.RestartPlan.sessions(live)) and Restart")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            // The sessions may have changed while the alert was up: restart only what was confirmed.
            guard host.restartOffer == plan else { return confirmAndRestart(host) }
        }
        host.restartHost()
    }
}

/// The header's restart button for an outdated host.
struct HostRestartButton: View {
    let plan: HostClient.RestartPlan
    let action: () -> Void

    var body: some View {
        Button(plan.title, action: action)
            .lineLimit(1)
            .help(plan.help)
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// VibeSwitcher › Restart Session Host: found without a selected session, or with the window's header hidden.
    @objc func restartSessionHost(_ sender: Any?) {
        HostRestart.confirmAndRestart(hostClient)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(restartSessionHost(_:)) else { return true }
        let plan = hostClient.restartOffer
        item.title = plan?.title ?? MainMenu.restartHostTitle
        item.toolTip = plan?.help ?? "The session host is this app's version."
        return plan != nil
    }
}

/// Settings › General › Session host: the restart, found with the window closed too.
struct HostRestartSection: View {
    @ObservedObject var host: HostClient

    var body: some View {
        Section {
            LabeledContent("Session host") {
                if let plan = host.restartOffer {
                    HStack {
                        Text("Older than this app").foregroundStyle(.orange)
                        HostRestartButton(plan: plan) { HostRestart.confirmAndRestart(host) }.controlSize(.small)
                    }
                } else {
                    Text(Self.status(host.state)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } footer: {
            SettingsFooter(host.restartOffer?.help ?? "Runs the window's sessions; it's updated with the app.")
        }
    }

    static func status(_ state: HostClient.State) -> String {
        switch state {
        case .connected: return "Up to date"
        case .connecting: return "Connecting…"
        case .notRunning: return "Not running"
        case .failed(let reason): return reason
        case .outdated: return "Older than this app"
        }
    }
}
