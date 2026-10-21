import AppKit
import SwiftUI
import VibeCore

/// Brief me: a spinner while the briefing is written, a stop button while it's read; pressing again stops it.
struct BriefMeButton: View {
    @ObservedObject var model: BriefingModel
    /// Pressed (whatever it did): the window's toolbar opens its panel.
    var pressed: () -> Void = {}

    var body: some View {
        Button {
            model.press()
            pressed()
        } label: {
            BriefingPhaseIcon(phase: model.phase)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Brief me")
        .accessibilityValue(Self.state(model.phase))
        .help(Self.help(model.phase))
    }

    static func state(_ phase: BriefingModel.Phase) -> String {
        switch phase {
        case .idle: return ""
        case .writing: return "Writing the briefing"
        case .speaking: return "Reading it aloud"
        }
    }

    static func help(_ phase: BriefingModel.Phase) -> String {
        switch phase {
        case .idle: return "Brief me: 30 seconds, spoken, on what happened lately across your projects"
        case .writing: return "Writing the briefing… click to cancel"
        case .speaking: return "Stop reading the briefing"
        }
    }
}

/// What Brief me shows for its phase: a speech bubble, a spinner while it's written (a static hourglass with Reduce
/// Motion), a stop square while it's read.
struct BriefingPhaseIcon: View {
    let phase: BriefingModel.Phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch phase {
        case .writing:
            if reduceMotion {
                Image(systemName: "hourglass").accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
            }
        case .speaking:
            Image(systemName: "stop.fill").accessibilityHidden(true)
        case .idle:
            Image(systemName: "text.bubble").accessibilityHidden(true)
        }
    }
}

/// The lead's Team tab header: Brief me on <project> (pressing it again cancels or stops it, as the toolbar's does),
/// and the briefing's panel under it, from the press until it's closed.
struct ProjectBriefingBar: View {
    @ObservedObject var model: BriefingModel

    var body: some View {
        let name = model.projectName ?? "this project"
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    model.press()
                } label: {
                    HStack(spacing: 6) {
                        BriefingPhaseIcon(phase: model.phase).frame(width: 16, height: 16)
                        Text("Brief me on \(name)").lineLimit(1).truncationMode(.middle)
                    }
                }
                .controlSize(.small)
                .accessibilityLabel("Brief me on \(name)")
                .accessibilityValue(BriefMeButton.state(model.phase))
                .help(Self.help(model.phase, name: name))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if !model.panelHidden, model.phase == .writing || model.briefing != nil {
                Divider()
                BriefingPanel(model: model) { model.panelHidden = true }
            }
        }
    }

    static func help(_ phase: BriefingModel.Phase, name: String) -> String {
        switch phase {
        case .idle: return "Brief me on \(name): 30 seconds, spoken, on what landed, what's running, what's blocked and its questions for you"
        case .writing: return "Writing the briefing… click to cancel"
        case .speaking: return "Stop reading the briefing"
        }
    }
}

/// The briefing's text (selectable), when it was written, and Play / Stop.
struct BriefingPanel: View {
    @ObservedObject var model: BriefingModel
    /// The menu bar's panel has a close button; the toolbar's popover closes by itself.
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model.projectName.map { "Briefing on \($0)" } ?? "Briefing").font(.headline).lineLimit(1)
                if let briefing = model.briefing {
                    Text(Self.written(briefing)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if model.briefing != nil {
                    Button { model.playOrStop() } label: {
                        Label(model.phase == .speaking ? "Stop" : "Play",
                              systemImage: model.phase == .speaking ? "stop.fill" : "play.fill")
                    }
                    .controlSize(.small)
                    .disabled(model.phase == .writing)
                    .help(model.phase == .speaking ? "Stop reading" : "Read it again")
                }
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark").accessibilityLabel("Close the briefing") }
                        .buttonStyle(.borderless)
                        .help("Close the briefing")
                }
            }
            if model.phase == .writing {
                Text(model.projectName.map { "Writing what happened in \($0)…" } ?? "Writing what happened lately…")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let briefing = model.briefing {
                Text(briefing.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach([model.briefing?.notice, model.voiceNotice].compactMap { $0 }, id: \.self) { notice in
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Written 14:32" (and the language when it isn't the one asked for, the template's English).
    static func written(_ briefing: BriefingText) -> String {
        "Written " + Date(timeIntervalSince1970: briefing.at).formatted(date: .omitted, time: .shortened)
    }
}

/// The main window's toolbar item: the button, its panel in a popover.
struct BriefMeToolbarItem: View {
    @ObservedObject var model: BriefingModel
    @State private var shown = false

    var body: some View {
        BriefMeButton(model: model) { shown = model.phase != .idle || model.briefing != nil }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                BriefingPanel(model: model).frame(width: 380)
            }
            // Brief Me from the window's menu opens the panel too.
            .onChange(of: model.revealed) { shown = model.phase != .idle || model.briefing != nil }
    }
}
