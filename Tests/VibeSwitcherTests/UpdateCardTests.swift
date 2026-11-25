import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The update card's model: Install & Restart only on a ready version (main holds it), once per click; Later snoozes
/// it; a version waiting on the lead's merge turns ready in place when a later check finds it merged.
@MainActor
struct UpdateCardTests {
    func offer(waiting: Int, newest: String = String(repeating: "b", count: 40)) -> AppUpdate.Offer {
        AppUpdate.Offer(installed: String(repeating: "a", count: 40), head: newest, tip: newest, newest: newest,
                        changes: [AppUpdate.Change(id: newest, subject: "Chat: faster"), AppUpdate.Change(id: String(repeating: "c", count: 40), subject: "Lead: merge_remote tests first")],
                        waiting: waiting)
    }

    @Test func installGoesOnlyOnAReadyVersionOncePerClick() {
        let desk = UpdateDesk()
        var installs: [AppUpdate.Offer] = [], laters: [AppUpdate.Offer] = [], shows = 0, closes = 0
        desk.install = { installs.append($0) }
        desk.later = { laters.append($0) }
        desk.show = { shows += 1 }
        desk.close = { closes += 1 }

        // Waiting on the lead's merge: the click does nothing.
        let waiting = offer(waiting: 2)
        desk.present(waiting)
        #expect(desk.offer == waiting && shows == 1)
        desk.installClicked()
        #expect(installs.isEmpty)

        // The merge landed: the same card turns ready, the list as it was opened.
        desk.showAll = true
        let ready = offer(waiting: 0)
        desk.present(ready)
        #expect(desk.offer?.ready == true && desk.showAll)
        desk.installClicked()
        desk.installClicked()
        #expect(installs == [ready] && desk.installing)
        // It didn't start: why, on the card, and the button back.
        desk.refused("The checkout is on elsewhere, not main.")
        #expect(desk.note == "The checkout is on elsewhere, not main." && !desk.installing)
        desk.installClicked()
        desk.started()
        #expect(installs.count == 2 && desk.shown == nil && closes == 1)

        // Later: snoozed, and the card goes.
        desk.present(ready)
        desk.laterClicked()
        #expect(laters == [ready] && desk.shown == nil && closes == 2)

        // A newer version starts with the short list again; a check that finds nothing takes a shown card away.
        desk.present(offer(waiting: 0, newest: String(repeating: "d", count: 40)))
        #expect(!desk.showAll)
        desk.withdraw()
        #expect(desk.shown == nil && closes == 3)
        desk.presentNothing(nil)
        #expect(desk.shown == .nothing(nil))
    }

    /// The minute's looks while a version waits on the lead's merge don't bring the card forward, nor reopen one the
    /// user closed; it comes forward when it turns ready, a newer version, or Check for Updates….
    @Test func aWaitingCardIsntBroughtForwardByEachLook() {
        let waiting = offer(waiting: 2), ready = offer(waiting: 0)
        let presentation = UpdateChecks.presentation
        // First found: shown.
        #expect(presentation(waiting, true, false, nil, nil) == .front)
        // Up, looked at again each minute: in place.
        #expect(presentation(waiting, true, false, waiting, UpdateChecks.key(waiting)) == .inPlace)
        // Closed by the user: not reopened for the same version and state.
        #expect(presentation(waiting, true, false, nil, UpdateChecks.key(waiting)) == .not)
        // The merge landed: forward, whether the card was up or closed.
        #expect(presentation(ready, true, false, waiting, UpdateChecks.key(waiting)) == .front)
        #expect(presentation(ready, true, false, nil, UpdateChecks.key(waiting)) == .front)
        // Snoozed (Later): not shown by the schedule; Check for Updates… shows it all the same.
        #expect(presentation(ready, false, false, nil, nil) == .not)
        #expect(presentation(ready, false, true, nil, UpdateChecks.key(ready)) == .front)
        // A newer version: shown.
        #expect(presentation(offer(waiting: 0, newest: String(repeating: "d", count: 40)), true, false, nil, UpdateChecks.key(ready)) == .front)
    }

    /// Install & Restart's shell started but the build failed, or its password was cancelled: the app still runs this
    /// build, and the next scheduled check brings the card back for the same version (a closed card isn't reopened).
    @Test func aVersionWhoseInstallDidntTakeComesBackAtTheNextCheck() {
        let ready = offer(waiting: 0)
        var memory = UpdateChecks.CardMemory()
        #expect(memory.presentation(ready, show: true, asked: false, up: nil) == .front)
        // Closed by the user: the schedule leaves it be.
        #expect(memory.presentation(ready, show: true, asked: false, up: nil) == .not)
        memory.installStarted()
        #expect(memory.presentation(ready, show: true, asked: false, up: nil) == .front)
        #expect(memory.presentation(ready, show: true, asked: false, up: nil) == .not)
        // Snoozed before the click: still not by the schedule, but Check for Updates… shows it.
        memory.installStarted()
        #expect(memory.presentation(ready, show: false, asked: false, up: nil) == .not)
        #expect(memory.presentation(ready, show: false, asked: true, up: nil) == .front)
    }

    /// `present(front: false)` updates the card without bringing it forward.
    @Test func presentingInPlaceDoesntShowTheWindow() {
        let desk = UpdateDesk()
        var shows = 0
        desk.show = { shows += 1 }
        desk.present(offer(waiting: 2))
        desk.present(offer(waiting: 1), front: false)
        #expect(shows == 1 && desk.offer?.waiting == 1)
    }

    @Test func subjectsLoseTheirAreaButNotANamesCase() {
        #expect(UpdateCardView.shortSubject("Chat: faster replies", area: "Chat") == "Faster replies")
        #expect(UpdateCardView.shortSubject("Lead: merge_remote tests first", area: "Lead") == "merge_remote tests first")
        #expect(UpdateCardView.shortSubject("Fix it: now", area: "Other") == "Fix it: now")
    }

    /// A GitHub change names who pushed it; a card kept from before handles (no `pusher` in its JSON) reads as one
    /// without them.
    @Test func aGitHubChangeNamesItsPusher() throws {
        #expect(UpdateCardView.pushedBy("laptop-dev") == "pushed by @laptop-dev")
        let old = try JSONDecoder().decode(AppUpdate.Change.self, from: Data(#"{"id":"abc","subject":"Chat: faster"}"#.utf8))
        #expect(old == AppUpdate.Change(id: "abc", subject: "Chat: faster") && old.pusher == nil)
        let named = AppUpdate.Change(id: "abc", subject: "Chat: faster", pusher: "laptop-dev")
        #expect(try JSONDecoder().decode(AppUpdate.Change.self, from: JSONEncoder().encode(named)) == named)
    }
}
