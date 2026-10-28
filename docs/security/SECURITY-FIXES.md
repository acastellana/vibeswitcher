# Security Fixes — 27 October 2026

*Translated from the Spanish original in PR #1.*

Fixes have been implemented for the four findings in [SECURITY-AUDIT.md](SECURITY-AUDIT.md). The original report describes the audited commit, before these local changes. This work does not install or relaunch the user's application.

## 1. Terminal server authorization

`HostServer` applies a common policy before reading, attaching, writing, resizing, creating, removing or terminating sessions. An unknown client gains no authority by sharing the UID. The app must prove its key; a session can access itself and its descendants, and a lead can access its team. The vault continues to restrict writing to protected roles.

`hello` filters the sessions; change emissions, bells and output are also filtered. Identity is re-checked on every message and before deferred replies. When it is lost, subscriptions and pending output are removed.

`HostConnection` repeats the `hello` after the cryptographic proof and does not present the app with an empty list received before authentication. Negotiation compatibility with older hosts that do not send challenges is preserved.

The tests that simulated legitimate clients without a key now use keys of the test host itself; no authentication exception has been added for tests. `HostCall` allows that key to be injected explicitly per call without sharing global state between parallel tests.

Code verification compares the cdhash of the process's specific architecture with that same architecture of the configured executable. This keeps the strict criterion for universal arm64e/arm64e.x1 binaries.

On a host rollback, the private launcher keeps the location of the original app via argv. The identity is not deduced from a state file that another process could edit. The existing rollback tests verify that the app authenticates again and recovers its sessions and terminals. That argument is only accepted when restoring a host, never on a fresh start. An external test tries to designate Node as the app and replace the host key: it is rejected. The external fixtures use private copies with the real app/helper layout, with no identity exceptions through arguments.

## 2. Hardened Runtime

`scripts/build-app.sh` signs the app and the three helpers with `--options runtime`, with no exceptions for DYLD and without disabling library validation. The test runs the script's real signing function on temporary copies, checks the four signatures and attempts `DYLD_INSERT_LIBRARIES` on each copy. It checks that the process reaches its expected entry point and that the injected constructor does not run; a mere crash does not count as proof of rejection.

## 3. Clipboard

The terminal's `clipboardCopy` delegate rejects writes requested by programs through OSC 52, including hidden or replayed output. Copying a selection through SwiftTerm's explicit action still uses `TerminalView.copy(_:)`, which is a different path.

The test feeds OSC 52 into the real parser and checks the text and the change counter of an `NSPasteboard` with a unique name. It does not use the personal clipboard.

## 4. Socket budgets

`HostFrameDecoder` limits the unconsumed bytes to one maximum frame plus the next read block. When the limit is exceeded, it releases the content and keeps the rejection state; it does not return a frame preceding the error.

The server processes frames between reads and handles at most 64 messages or 256 KiB per turn before yielding the queue. It continues with the frames already received even if the socket does not produce another event. The client also consumes frames between reads and limits the bytes handled per turn.

There is a configurable maximum of 128 connections and 256 sessions per host. Terminated sessions count toward the latter: removing them frees capacity. The error explains this without creating an additional process.

## Tests added

- `Tests/VibeHostTests/SecurityHardeningTests.swift`: rejection of operations without authentication, absence of output and notices for unknown clients, authenticated `hello`, and connection/session limits.
- `Tests/VibeHostTests/SessionAuthorizationTests.swift`: real processes of fake sessions: own access and lead access to worker; rejection of worker to lead and of access to another project.
- `Tests/VibeCoreTests/SocketBoundsTests.swift`: rejection of excessive buffer and acceptance of fragmented maximum frames.
- `Tests/VibeHostTests/SocketSchedulingTests.swift`: a pipeline of 128 requests yields the queue before exhausting the pipeline and then continues until it is processed in full, without losing frames.
- `Tests/VibeSwitcherTests/TerminalClipboardSecurityTests.swift`: real OSC 52 parser and isolated clipboard.
- `Tests/SecurityAudit/*.test.mjs`: external client without identity against a private host, and an injection test against the four signatures created by the distribution script.

## Validation

The extended selection passed: 209 tests in 50 suites. It includes the whole VibeHost module, negotiation/reconnection, rollback, concurrent input, paste, protocol, the new security checks and the lints required by `AGENTS.md`. The result contains three known, intentional issues of the harness, which tests fixture failures and checks that they are cleaned up; there are no new failures. In addition, 3 phone web tests and 2 external security tests passed.

Before the fixes, the authorization, buffer and clipboard tests reproduced the failures; the signing test failed because of the absence of runtime. Afterwards, the clipboard and read-turn fixes were removed using `git apply -R`: both tests failed with the previous behavior. The patches were reapplied and the extended validation was repeated successfully.

Two simultaneous runs under a 2-core load each passed 65 tests in 13 suites, including the long `TMPDIR` case, leaving no open processes. The extended repetition also passed: 162 tests in 39 suites in each of two simultaneous runs under the same load, with the three known, intentional harness issues and with no new failures or open processes. After restricting the identity argument to rollback, the 22 startup, recovery and authentication cases were repeated in two runs under load: both passed, with two known harness issues and no open processes. The extended selection of 209 cases was also repeated and passed. The two external tests were repeated under a 2-core load: both passed.

The final results and their logs are recorded in `.build/security-audit/`.

- `final-validation.log`: extended selection and web/external tests.
- `before-fixes.log` and `signing-before.log`: failures before fixing.
- `negative-controls.log`: reverse check of the clipboard and socket turn.
- `load-65-tests.log`: first repetition under load.
- `load-full.log` and `load-full-run-{1,2}.log`: extended repetition under load.
- `fresh-identity-before.log`: regression of the identity argument on a fresh start.
- `load-startup.log` and `load-startup-run-{1,2}.log`: final startup/rollback repetition.
- `load-external.log`: rejection of fake identity and injection under load.

`scripts/test.sh` and `scripts/test-under-load.sh` are used, with a temporary HOME.

On this Mac, the default build requires a Metal compiler that is not installed. The Swift validation uses the native system and the already installed SDK 26.5, adding the paths of the Testing framework and its macro from the Command Line Tools. The local wrapper used is at `.build/security-audit/toolchain/swift` and includes the rpaths of the Testing framework and `lib_TestingInterop`. The repository's tests continue to use whatever tools the Mac has configured. No tools were installed and the system SDKs were not changed.

The signing test uses temporary binaries and ad hoc signing; it neither queries nor modifies the Keychain. It is not a substitute for a test of the final release package or for notarization of a public distribution.

These fixes reduce the surfaces detected. Agents and commands continue to run as the user: worktrees, roles and the temporary HOME are not operating-system isolation against malicious projects.

## Changes made when landing PR #1

The project lead's review of PR #1 kept its authorization model (a session reaches itself and its descendants, a lead its team, the app everything), the identity re-checks, the socket bounds and the rollback identity, and changed the following before merging:

- **Apple Events under the hardened runtime.** The app sends Apple Events in-process (Terminal's tabs, Chrome's localhost tabs, onboarding). Under `--options runtime` they fail with -1743 and no prompt unless the signature carries `com.apple.security.automation.apple-events`. `scripts/build-app.sh` now signs the app, and only the app, with `Resources/VibeSwitcher.entitlements`; the helpers keep no entitlements (`AppEntitlementsTests`).
- **Session limit.** `maxSessions` counted ended sessions, which are kept for a day: a busy day's ended workers and verifiers could fill it and refuse every spawn. At the limit, the sessions that ended first are now forgotten to make room; only live sessions refuse a spawn (`HostSecurityHardeningTests`).
- **Refused proof.** When the host refuses the app's proof it shows the app no sessions. The window's header and Settings now say the host doesn't recognise this app, and why, instead of showing an empty list (`HostProofRefusedTests`). The upgrade from a host built before PR #1, handing over to this build, is covered by `UpgradeFromLeadHostTests`.
- **OSC 52.** Rather than dropping every program clipboard write, the app takes one only from the pane on screen in the key window whose terminal has the focus, once its replay is over; hidden views, views behind the chat, background panes and windows, and replays are refused (`TerminalClipboardSecurityTests`).
- **Refused input.** The host now answers input to a missing session, or one the connection may not reach, with an error for each write. The app tells the user once per session instead of once per key (`PasteDeliveryTests`).
- **Build.** `AppCode` declares `proc_archinfo` and `PROC_PIDARCHINFO` itself: the Command Line Tools SDK has neither, and the host didn't build with it (`AppCodeTests`).
- **test.sh.** The `Tests/SecurityAudit` run is skipped, saying so, when the build failed, rather than failing again or running an older host.
