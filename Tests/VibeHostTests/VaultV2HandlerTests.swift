import Foundation
import Testing
import VibeCore
@testable import VibeHost

/// The host's record of the user's actions (`VaultV2Handler`, the engine plan's EN-D11): the app's alone; on Linux any
/// host's; on the Mac only a node's host (one with a server child, `HostServer.isMacNodeHost`), never the Mac app's.
/// Its rules are the Linux vault's (`LeadVaultV2.answer`): an action recorded once, its retry answered as recorded
/// already. Both systems: what the Mac's host job runs of the record.
struct VaultV2HandlerTests {
    private let record = LeadVaultV2.Request.recordUserAction(action: "8d1f6e1c-2a3b-4c5d-8e9f-0a1b2c3d4e5f", kind: "set", subject: nil,
                                                             digest: String(repeating: "a", count: 64))

    @Test func aNodesHostRecordsTheUsersActionOnceAndAnswersItsRetry() {
        let book = LeadVault.Book()
        #expect(VaultV2Handler.answer(record, from: .app, vault: book, nodeHost: true, viaConnector: true) == .recorded(first: true))
        #expect(VaultV2Handler.answer(record, from: .app, vault: book, nodeHost: true, viaConnector: true) == .recorded(first: false))
        // The Mac: `.app` from a socket's peer that proved itself isn't the server child (the review of 2026-11-21).
        let socket = VaultV2Handler.answer(record, from: .app, vault: book, nodeHost: true, viaConnector: false)
        if Platform.CodeIdentity.isAvailable { #expect(socket == .refused(HostProtocol.unauthorized)) } else { #expect(socket == .recorded(first: false)) }
        // Nothing but the app; nothing with no vault.
        #expect(VaultV2Handler.answer(record, from: .session("x"), vault: book, nodeHost: true, viaConnector: true) == .refused(HostProtocol.unauthorized))
        #expect(VaultV2Handler.answer(record, from: .unknown, vault: book, nodeHost: true, viaConnector: true) == .refused(HostProtocol.unauthorized))
        if case .refused = VaultV2Handler.answer(record, from: .app, vault: nil, nodeHost: true, viaConnector: true) {} else { Issue.record("a host with no vault recorded") }
    }

    /// The Mac app's host (no server child) keeps no record, as before; Linux's hosts all do.
    @Test func theMacAppsHostKeepsNoRecord() {
        let answer = VaultV2Handler.answer(record, from: .app, vault: LeadVault.Book(), nodeHost: false, viaConnector: true)
        #expect(!HostImages.isCheckedMacNode, "no Mac host is a node host until its start is checked")
        if Platform.CodeIdentity.isAvailable {
            #expect(answer == .refused("This session host keeps no record of the user's actions (the Mac app's)."))
        } else {
            #expect(answer == .recorded(first: true))
        }
    }
}
