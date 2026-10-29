import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Holding Space alone in the composer's box dictates, as ⌥Space does: timed from the key-down on an injected clock
/// (never by its repeats), the spaces it typed taken out at the threshold, a tap or typing left as ever, and one ⌘Z
/// after a run taking out the transcript with no stray spaces. The box is the composer's own text view in a window
/// that's never shown; nothing records (`holdToTalk` only notes the calls).
@MainActor
struct SpaceHoldTests {
    /// The composer's text view as ComposerTextView wires it: its own undo manager, push to talk and the clock.
    final class Box: NSObject, NSTextViewDelegate {
        let view = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 40), styleMask: [.titled], backing: .buffered, defer: true)
        let undo = UndoManager()
        let clock = DictationTests.FakeClock()
        var held: [Bool] = []
        var cancels = 0
        var ready = true

        init(_ text: String) {
            super.init()
            // AppKit groups each event's changes; here each key is a group of its own (`key`), the same.
            undo.groupsByEvent = false
            view.isEditable = true
            view.isRichText = false
            view.allowsUndo = true
            view.delegate = self
            view.schedule = clock.schedule
            view.holdToTalk = { [unowned self] in held.append($0) }
            view.cancelTalk = { [unowned self] in cancels += 1 }
            view.spaceHoldReady = { [unowned self] in ready }
            window.contentView = view
            window.makeFirstResponder(view)
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        /// One key going down (or up), as an event of its own.
        func key(_ type: NSEvent.EventType, _ character: Character = " ", code: Int = kVK_Space, flags: NSEvent.ModifierFlags = [],
                 repeat: Bool = false) {
            let text = String(character)
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: `repeat`,
                                         keyCode: UInt16(code))!
            guard type == .keyDown else { return view.keyUp(with: event) }
            undo.beginUndoGrouping()
            view.keyDown(with: event)
            undo.endUndoGrouping()
        }

        /// The clock reaching the threshold: what it was asked to call then (a cancelled one does nothing).
        func reachThreshold() {
            #expect(clock.pending.allSatisfy { $0.delay == DictationLimits.spaceHold })
            let due = clock.pending
            clock.pending = []
            due.forEach { $0.work() }
        }

        /// A transcript landing at the cursor, as the composer's inbox puts it in.
        func deliver(_ text: String) {
            undo.beginUndoGrouping()
            DictationInsert.insert(text, into: view)
            undo.endUndoGrouping()
        }
    }

    @Test func aTapTypesOneSpaceAndStartsNothing() {
        let box = Box("hello")
        box.key(.keyDown)
        #expect(box.view.string == "hello ", "the space is typed as the key goes down, not later")
        box.key(.keyUp)
        box.reachThreshold()
        #expect(box.view.string == "hello ")
        #expect(box.held.isEmpty)
        #expect(box.view.spaceHold == .idle)
        box.key(.keyDown, "a", code: kVK_ANSI_A)
        #expect(box.view.string == "hello a")
    }

    @Test func aHoldPastTheThresholdTakesOutItsSpacesAndLettingGoEndsTheRun() {
        let box = Box("hello")
        box.key(.keyDown)
        box.key(.keyDown, repeat: true)
        box.key(.keyDown, repeat: true)
        #expect(box.view.string == "hello   ", "before the threshold its repeats type, as ever")
        #expect(box.held.isEmpty)
        box.reachThreshold()
        #expect(box.view.string == "hello")
        #expect(box.view.selectedRange() == NSRange(location: 5, length: 0))
        #expect(box.held == [true])
        #expect(box.view.talking)
        box.key(.keyDown, repeat: true)
        box.key(.keyDown, repeat: true)
        #expect(box.view.string == "hello", "repeats during the run are swallowed")
        box.key(.keyUp)
        #expect(box.held == [true, false])
        #expect(box.view.spaceHold == .idle)
        #expect(box.cancels == 0)
    }

    /// Key repeat off (or slow): the one key-down is enough, the clock times it.
    @Test func itIsTimedFromTheKeyDownWithoutRepeats() {
        let box = Box("")
        box.key(.keyDown)
        box.reachThreshold()
        #expect(box.view.string == "")
        #expect(box.held == [true])
    }

    @Test func theBoxAfterARunIsItsTextPlusTheTranscriptAndOneUndoTakesTheTranscriptOut() {
        let box = Box("")
        for character in "hello" { box.key(.keyDown, character, code: kVK_ANSI_A) }
        box.key(.keyDown)
        box.key(.keyDown, repeat: true)
        box.reachThreshold()
        box.key(.keyUp)
        box.deliver("world")
        #expect(box.view.string == "hello world")
        box.undo.undo()
        #expect(box.view.string == "hello", "one ⌘Z takes out the transcript, and brings back no spaces")
        box.undo.undo()
        #expect(box.view.string.count < 5 && "hello".hasPrefix(box.view.string), "the next one takes out typing from before the press")
    }

    /// A selection Space replaced comes back, selected, as before the press (the transcript replaces it, as ⌥Space's does).
    @Test func aSelectionTheSpaceReplacedComesBack() {
        let box = Box("hello there")
        box.view.setSelectedRange(NSRange(location: 6, length: 5))
        box.key(.keyDown)
        #expect(box.view.string == "hello  ")
        box.reachThreshold()
        #expect(box.view.string == "hello there")
        #expect(box.view.selectedRange() == NSRange(location: 6, length: 5))
        #expect(box.held == [true])
    }

    /// Spelling correction set off by the space ("teh " made "the "): undone with the spaces, the box as before the press.
    @Test func aCorrectionTheSpaceSetOffIsUndoneWithIt() {
        let box = Box("teh")
        box.key(.keyDown)
        box.undo.beginUndoGrouping()
        box.view.insertText("the", replacementRange: NSRange(location: 0, length: 3))
        box.undo.endUndoGrouping()
        #expect(box.view.string == "the ")
        box.reachThreshold()
        #expect(box.view.string == "teh")
        #expect(box.held == [true])
    }

    /// The box changed some other way while Space was down (undoing doesn't get back to it): left as it is, not started.
    @Test func aBoxThatUndoingDoesNotBringBackIsLeftAsItIs() {
        let box = Box("hello")
        box.key(.keyDown)
        // As the composer replaces its text from outside (another draft, a history step): its undo emptied too.
        box.view.string = "something else"
        box.undo.removeAllActions()
        box.reachThreshold()
        #expect(box.view.string == "something else")
        #expect(box.held.isEmpty)
        #expect(box.view.spaceHold == .idle)
    }

    @Test func anotherKeyBeforeTheThresholdCancelsItAndTypes() {
        let box = Box("hello")
        box.key(.keyDown)
        box.key(.keyDown, "a", code: kVK_ANSI_A)
        box.key(.keyUp)
        box.reachThreshold()
        #expect(box.view.string == "hello a")
        #expect(box.held.isEmpty)
        #expect(box.view.spaceHold == .idle)
    }

    @Test func aKeyMidRunEndsItAsEscDoes() {
        let box = Box("hello")
        box.key(.keyDown)
        box.reachThreshold()
        #expect(box.held == [true])
        box.key(.keyDown, "a", code: kVK_ANSI_A)
        #expect(box.cancels == 1)
        #expect(!box.view.talking)
        #expect(box.view.string == "hello", "the key that ended it isn't typed")
        box.key(.keyDown, repeat: true)
        #expect(box.view.string == "hello", "Space's repeats still do nothing until it comes up")
        box.key(.keyUp)
        #expect(box.held == [true], "letting go sends nothing after the cancel")
        #expect(box.view.spaceHold == .idle)
        box.key(.keyDown)
        box.key(.keyUp)
        #expect(box.view.string == "hello ")
        // Esc mid-run, the same.
        box.key(.keyDown)
        box.reachThreshold()
        box.key(.keyDown, "\u{1b}", code: kVK_Escape)
        #expect(box.cancels == 2)
        box.key(.keyUp)
        #expect(box.held == [true, true])
    }

    @Test func markedTextOrAModifierNeverStartsIt() {
        // ⇧Space, ⌃Space, ⌘Space: typed (or the system's), never timed.
        for flags: NSEvent.ModifierFlags in [.shift, .control, .command] {
            let box = Box("hello")
            box.key(.keyDown, flags: flags)
            box.key(.keyDown, repeat: true)
            box.reachThreshold()
            box.key(.keyUp)
            #expect(box.held.isEmpty, "\(flags)")
            #expect(box.view.spaceHold == .idle)
        }
        // A modifier going down while Space is held short of the threshold: typing.
        let shifted = Box("hello")
        shifted.key(.keyDown)
        shifted.view.flagsChanged(with: NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: 0,
                                                         windowNumber: shifted.window.windowNumber, context: nil, characters: "",
                                                         charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_Shift))!)
        shifted.reachThreshold()
        #expect(shifted.view.string == "hello ")
        #expect(shifted.held.isEmpty)
        // An input method composing: its Space is the input method's.
        let composing = Box("")
        composing.undo.beginUndoGrouping()
        composing.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        composing.undo.endUndoGrouping()
        #expect(composing.view.hasMarkedText())
        composing.key(.keyDown)
        composing.reachThreshold()
        #expect(composing.held.isEmpty)
        #expect(composing.view.spaceHold == .idle)
    }

    @Test func turnedOffSpacesTypeAsBefore() {
        let box = Box("hello")
        box.ready = false
        box.key(.keyDown)
        box.key(.keyDown, repeat: true)
        box.key(.keyDown, repeat: true)
        box.reachThreshold()
        box.key(.keyUp)
        #expect(box.view.string == "hello   ")
        #expect(box.held.isEmpty)
        // No dictation in the box (benches, tests): the same.
        let none = Box("")
        none.view.spaceHoldReady = nil
        none.key(.keyDown)
        #expect(none.clock.pending.isEmpty)
        #expect(none.view.string == " ")
    }

    /// Dictation got busy (or the focus went) while Space was down: the spaces stay, nothing starts.
    @Test func notReadyAtTheThresholdLeavesTheSpaces() {
        let box = Box("hello")
        box.key(.keyDown)
        box.ready = false
        box.reachThreshold()
        #expect(box.view.string == "hello ")
        #expect(box.held.isEmpty)
        let left = Box("hello")
        left.key(.keyDown)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: left.window)
        left.reachThreshold()
        #expect(left.view.string == "hello ")
        #expect(left.held.isEmpty)
    }

    @Test func theSettingIsOnAtFirstKeptAndSaidInTheTooltips() {
        let temp = Scratch()
        let defaults = temp.defaults("space-hold")
        func controller() -> DictationController {
            DictationController(keyStore: AppProof.MemorySecret(nil), recorder: DictationTests.FakeRecorder(),
                                microphone: DictationTests.FakeMicrophone(), defaults: defaults, findKey: { nil }, background: { $0() })
        }
        let dictation = controller()
        #expect(dictation.holdSpace)
        #expect(dictation.canHoldSpace)
        #expect(dictation.shortcuts == "Space or ⌥Space")
        dictation.holdSpace = false
        #expect(!dictation.canHoldSpace)
        #expect(dictation.shortcuts == "⌥Space")
        #expect(!controller().holdSpace)
        #expect(DictationSettings.holdSpaceHelp.contains("many spaces"))
    }
}
