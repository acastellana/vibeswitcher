import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import VibeCore

/// ⚙︎ › Phone Access…: turn it on, pair a phone, choose what the phone may do, see what it did.
struct PhoneAccessView: View {
    @ObservedObject var access: PhoneAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $access.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Phone access over Tailscale").font(.headline)
                    Text("See your sessions, their screens and notifications on your phone. Only devices on your tailnet, "
                         + "logged in as you and paired below, can connect.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            statusLine
            if access.state == .on {
                Divider()
                pairingSection
                Divider()
                Toggle(isOn: $access.inputAllowed) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow replies and key presses from the phone")
                        Text("Your sessions can run commands on this Mac, so this is remote control of it. The tab is brought "
                             + "to the front before typing; nothing is typed while the Mac is locked. Every input is logged "
                             + "and announced here.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle("Phone notifications only while I'm away from the Mac", isOn: $access.pushOnlyWhenAway)
                devicesSection
                activitySection
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    @ViewBuilder private var statusLine: some View {
        switch access.state {
        case .off:
            EmptyView()
        case .starting:
            HStack { ProgressView().controlSize(.small); Text("Starting…").foregroundStyle(.secondary) }
        case .on:
            if let url = access.url {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text(url.absoluteString).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
        case .failed(let message):
            Text(message).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var pairingSection: some View {
        if let pairing = access.pairing, let url = access.pairingURL {
            HStack(alignment: .top, spacing: 16) {
                if let qr = Self.qrCode(for: url.absoluteString) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 150, height: 150)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan with your phone's camera (Tailscale on), or open the address above and type:")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text(Self.grouped(pairing.code)).font(.system(size: 26, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(pairing.expires.timeIntervalSince(context.date)))
                        Text(left > 0 ? "Valid for \(left / 60):\(String(format: "%02d", left % 60)), once"
                                      : "Expired")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Cancel") { access.cancelPairing() }.controlSize(.small)
                }
            }
        } else {
            HStack {
                Text("Add a phone").font(.callout)
                Spacer()
                Button("Pair a Phone…") { access.startPairing() }
            }
        }
    }

    @ViewBuilder private var devicesSection: some View {
        if !access.devices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Paired devices").font(.subheadline.weight(.semibold))
                ForEach(access.devices) { device in
                    HStack {
                        Image(systemName: device.push != nil ? "bell.fill" : "iphone").foregroundStyle(.secondary)
                            .help(device.push != nil ? "Gets notifications" : "No notifications")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name)
                            Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))"
                                 + (device.lastSeen.map { " · last seen \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { access.remove(device) }.controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder private var activitySection: some View {
        if !access.recentActivity.isEmpty {
            DisclosureGroup("Activity log") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(access.recentActivity, id: \.self) { line in
                            Text(line).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            .font(.callout)
        }
    }

    static func grouped(_ code: String) -> String {
        code.count == 8 ? "\(code.prefix(4))-\(code.suffix(4))" : code
    }

    static func qrCode(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
