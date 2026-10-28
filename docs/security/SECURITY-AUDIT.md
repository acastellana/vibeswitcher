# Security Audit — VibeSwitcher

*Translated from the Spanish original in PR #1.*

- Date: 27 October 2026
- Repository: https://github.com/acastellana/vibeswitcher
- Commit examined: `dc2b9e31bf406e8b6055774ac3bbdadbbad84fd6`

Later update: all four findings have local fixes and regression tests. This document preserves the state before the fixes; the result of the implementation and its validation is in [SECURITY-FIXES.md](SECURITY-FIXES.md).

## Verdict

I would not consider this version safe for running untrusted projects or agents in an account with sensitive credentials and sessions. There are useful defenses and I have found no signs of covert exfiltration in the paths examined, but I have identified four security problems: two high priority and two medium. Two have dynamic reproductions on an isolated host; the other two are supported by code walkthrough.

The attacks described require code running as the Mac's user, or attacker-controlled terminal output. A remote unauthenticated intrusion from the Internet has not been demonstrated. Sharing a Unix user is a weak boundary: a process with those privileges can already modify many of the user's files. It matters especially here because the application runs project code, distinguishes roles and protects some operations through its own identity and keys.

This review is manual, oriented to attack surfaces, with bounded dynamic checks. It is not a line-by-line review of the whole repository, a certification, or a guarantee of the absence of vulnerabilities.

## Scope and method

The following were inspected: the manifest and pinned revisions; the HTTP servers, the Unix socket and its protocol; client identity and authentication; terminal creation and command execution; vault and Keychain access; permissions and private writes; agent rules; hook execution and branch code; preview proxy, cookies and tickets; mobile access and revocation; JavaScript and service worker; secret redaction; summaries and speech synthesis; build and signing scripts; and related existing tests.

`AGENTS.md` and `REVIEW.md` were followed. No applications or packages were installed, the keychain list was not changed, no user secrets were read, no real terminals or windows were touched, and the installed application was not run. SwiftPM downloaded the pinned dependencies to attempt the local build. The reproductions use fictitious data, their own sockets, an isolated HOME and an alternative lock: that host mode keeps the vault in memory only and does not query the user's Keychain.

## 1. HIGH / P1 — Unauthenticated clients can access other terminals

### Evidence

- `Sources/VibeHost/HostServer.swift:252` — `acceptAll` checks the UID and keeps clients with caller `.unknown`; the connection does not require resolving `proveApp`.
- `Sources/VibeHost/HostServer.swift:360` — `hello` returns all sessions.
- `Sources/VibeHost/HostServer.swift:363` — `spawn` does not check authorization.
- `Sources/VibeHost/HostServer.swift:386` — `attach` does not check authorization and makes the client primary before sending the replay.
- `Sources/VibeHost/HostServer.swift:425` — `screen`, `styledScreen` and `history` do not limit reading according to the caller or team membership.
- `Sources/VibeCore/LeadVault.swift:672` — `mayType` returns true if the session has no role in the vault, even for `.unknown`.

### Scenario

A project script or a process of the same user opens `host.sock`, asks for `hello` to discover the UUIDs, and reads `screen`/`history` or attaches to another session. For an ordinary session it can also enter text and Enter. If that terminal contains a shell, it can make it run commands; if it contains an agent, it can enter instructions that look like human input. The content of the local protocol is raw, without the filtering applied to the phone's screens. Reading is not restricted even to members of the same team. Attaching also allows interfering with the primary client and its automatic replies.

### Reproduction executed

`Tests/SecurityAudit/host-access.test.mjs` starts a private host and opens two connections from Node, without a key or `proveApp`. The first creates a fictitious terminal; the second discovers its UUID, reads `AUDIT_FAKE_SECRET` and sends a line. The terminal returns `AUDIT_RECEIVED:synthetic-input`. Result: confirmed.

### Limit

Writing to sessions with a role does go through additional rules; this test does not demonstrate direct writing to a protected lead. There is no escalation to root.

### Recommended fix

Deny by default `spawn`, `attach`, `screen`, `styledScreen`, `history`, `resize`, `remove` and `input` for `.unknown`. Define explicit permissions per operation and session for app, own session and lead. Apply that policy before changing primary or returning data. Add negative tests for ordinary sessions, different teams, branch code and clients without proof of identity.

## 2. HIGH / P1 — Signing without Hardened Runtime allows code injection

### Evidence

- `scripts/build-app.sh:129` — the four `codesign` calls do not include `--options runtime`; hardened library validation is not configured.
- `Sources/VibeHost/AppCode.swift:11` — the executable's signature/cdhash is used to recognize the application's code.
- `Sources/VibeHost/VaultStorage.swift:52` — vault persistence depends on a Keychain key accessible to the host.
- `Sources/VibeCore/LeadVaultAppProof.swift:34` — the app's identity accesses the key that answers the host's challenges.

### Scenario

A user process can launch a binary without Hardened Runtime with `DYLD_INSERT_LIBRARIES` pointing to its own library. The injected code runs inside the signed process: verifying the executable's signature does not establish that all its libraries are trustworthy. Therefore, the boundaries that trust that identity to safeguard keys or grant authority need additional hardening.

### Reproduction executed

`Tests/SecurityAudit/library-injection.test.mjs` compiles a minimal library in a temporary directory and loads it into the debug host. Its constructor prints `AUDIT_INJECTED signature_status=0` and exits before `main`. Status 0 comes from `SecCodeCheckValidity` of the running process. The executable's SHA-256 remains identical. `codesign` shows `flags=0x2(adhoc)`, without runtime. Result: simultaneous injection and dynamic validity confirmed.

### Limit

The test uses the locally compiled host, not an installed distribution package. The distribution script has the same runtime omission. No attempt was made to extract real keys, forge approvals or demonstrate a complete Keychain/TCC bypass. Those consequences require specific validation; the possibility of running injected code is demonstrated.

### Recommended fix

Sign the app and helpers with Hardened Runtime and keep library validation; do not enable DYLD or library-validation exceptions without a demonstrated need. Validate the final artifact's flags in CI. Repeat the test against the final package with a foreign library and verify rejection. Use an appropriate distribution identity and notarization for distribution. Keep the local signing key locked outside the signing operation: leaving it unlocked reduces protection against other processes of the user.

## 3. MEDIUM / P2 — OSC 52 output overwrites the clipboard without consent

### Evidence

- `Sources/VibeSwitcher/MainWindow/TerminalPane.swift:350` — `clipboardCopy` clears `NSPasteboard.general` and writes the received text without asking or verifying that the terminal is the visible one or that a user action exists.
- SwiftTerm 1.19.0, `Sources/SwiftTerm/Terminal.swift:2682` — `oscClipboard` decodes the OSC 52 sequence and calls the copy delegate.
- SwiftTerm 1.19.0, `Sources/SwiftTerm/Mac/MacTerminalView.swift:3321` — the delegate forwards that copy to the application.

### Scenario

A command, file or server response that prints an OSC 52 sequence can replace the clipboard with other text. The next paste may contain a command, an address or a recipient different from the expected one. It also matters in hidden attached terminals or when replaying past output: the `ReplayGate` control protects replies sent to the host, but not this side effect of `clipboardCopy`.

Harmless example of the sequence, for a future test with a fake clipboard:

```
ESC ] 52 ; c ; QVVESVRfQ0xJUEJPQVJE BEL
```

The base64 payload represents `AUDIT_CLIPBOARD`.

### Validation

Static walkthrough in the app's code and the exact downloaded dependency. The real clipboard was not modified during the audit. Reading the clipboard is correctly disabled through `clipboardRead -> nil`.

### Recommended fix

Disable OSC 52 writes by default, or ask permission per session upon a visible action. Reject them in replay and hidden terminals. Distinguish the user's explicit copy from requests that come from the program.

## 4. MEDIUM / P2 — Socket reading without a budget before validating frames

### Evidence

- `Sources/VibeHost/ClientConnection.swift:137` — `readAvailable` reads in a loop until `EAGAIN`, accumulating all bytes in `decoder` before calling `next`.
- `Sources/VibeCore/HostProtocol.swift:89` — `append` imposes no buffer limit.
- `Sources/VibeCore/HostProtocol.swift:99` — the 1 MiB maximum is checked in `next`, after the read loop finishes.
- `Sources/VibeHost/HostServer.swift:252` — there is no global client quota at accept and no session limit in the protocol's `spawn` path.

### Scenario

A client of the same user that writes continuously can make memory grow before an invalid frame is rejected, or monopolize the server thread while it keeps reading. Many connections or `spawn` requests multiply the cost and affect all hosted terminals. The existence of a per-frame or per-output-queue limit does not limit this input.

### Validation

Static analysis of the exact read -> append -> next order. No OOM, descriptor exhaustion or deliberate interruption of the Mac was provoked. The scale of consumption and the blocking time have not been measured.

### Recommended fix

Validate/consume frames after each block read, limit bytes and frames handled per queue turn, close connections with an excessive buffer, and set global client/session quotas. Test continuous input, partial frames and multiple clients with a bounded memory budget.

## Observed defenses

- Phone Access listens on loopback, checks Host and Tailscale account, and requires device tokens for authenticated APIs. Pairing has an expiry and a limited number of attempts; tokens are stored as hashes.
- Mobile input checks Mac lock, revocation, input permission and session identity, even between deferred writes.
- HTTP responses include a restrictive CSP, `no-store` and other headers. The HTTP server limits connections, sizes and receive times.
- Previews restrict destinations to localhost and use single-use tickets, HttpOnly cookies and revocable sessions. The development server's HttpOnly cookies are kept in a separate jar per preview session.
- The vault uses ChaChaPoly and Keychain keys; the app proves possession of a key through HMAC with a fresh challenge. The protection is useful, although it must be completed with the hardening of point 2.
- There are utilities for private writes 0600 and directories 0700, repair of permissions from earlier versions, and secret redaction on multiple surfaces. It should not be assumed that the filtering recognizes every secret.
- Internal Git execution disables transport, fsmonitor and external diff drivers, examines executable configurations and copies accepted hooks.
- The headless summary uses empty tools, restricted configuration and a separate folder. This reduces the impact of instructions in the notes.

## Design risks the user should know

- Roles, worktrees and the temporary HOME are not an operating-system sandbox. Branch code still runs with the user's UID and can access their files according to system permissions. `LeadVault.swift` itself documents it as a guard rail. For untrusted projects, use another macOS account or a VM with minimal credentials.
- Summaries send project notes to Claude. If an ElevenLabs key is available, voice may send the summary text to ElevenLabs. That key can be found automatically in the shell or in `key.env`. Deleting secret patterns does not remove confidential business information.
- A paired phone can keep reading screens and summaries with the Mac locked: the lock protects writing, not all reading. It is a documented decision. The phone's token is kept in `localStorage` until removed.
- Preview cookies that are not HttpOnly share a host across ports; scripts from another preview could read them. The README acknowledges this limitation. Do not use simultaneous previews of different trust with sensitive cookies.
- GitGuard accepts as baseline the hooks already present on first use. It is necessary to trust the repository's initial state, not only its changes.
- The vault's encryption detects tampering, but does not make the whole `~/.vibeswitcher` folder inaccessible to other processes of the same user.

## Dependencies and supply chain

`Package.swift` pins SwiftTerm exactly to 1.19.0. `Package.resolved` pins:

- SwiftTerm: `464df5207fc2432e16c9a23abe538187196daf5f`
- swift-argument-parser 1.8.2: `6a52f3251125d74daf04fcbd5e6f08a75d074382`

The resolution of this build left the lockfile unchanged.

The official advisory pages of both dependencies were consulted. SwiftTerm publishes GHSA-jq43-q8mx-r7mq / CVE-2022-23465. Commit `a94e6b24d24ce9680ad79884992e1dff8e150a31`, which the advisory identifies as the patch boundary, is an ancestor of the pinned revision: `git merge-base --is-ancestor` returned 0. I do not attribute that historical CVE to this revision. The swift-argument-parser page showed no public advisories. This consultation is not equivalent to an exhaustive scan of all CVE databases, nor does it validate precompiled binaries downloaded by other means.

Sources consulted on 27 October 2026:

- https://github.com/migueldeicaza/SwiftTerm/security/advisories
- https://github.com/migueldeicaza/SwiftTerm/security/advisories/GHSA-jq43-q8mx-r7mq
- https://github.com/apple/swift-argument-parser/security/advisories
- https://github.com/migueldeicaza/SwiftTerm/blob/main/SECURITY.md

## Tests, results and limits

1. Attempt at a focused Swift suite, using `scripts/test.sh` and a temporary HOME: The default build fails: the `metal` compiler does not exist in this Command Line Tools environment. The Swift tests were never run. The three existing web tests did pass (phone-briefing/menu/replies).

2. Attempt with `--build-system native`, through a temporary `swift` wrapper: It allowed compiling VibeCore, VibeHost and vibeswitcher-host. Compiling the graphical application failed due to the absence of `SwiftUIMacros.StateMacro` and its derived errors in SwiftUI. No sources were changed to work around it. Neither was the Swift suite run nor were all the required lints validated. The three existing web tests passed again.

3. Reproductions specific to this audit: `scripts/test.sh --web Tests/SecurityAudit`. Final result: 2 of 2 passed, confirming the vulnerable behavior of points 1 and 2. Passing these tests does NOT mean the app is safe: they are audit probes that expect to demonstrate the current access/injection. A fix will have to turn them into rejection tests.

4. Repetition through the repository's harness under light load:

   ```
   scripts/test-under-load.sh --load 1 --max-time 90 -- \
     bash scripts/test.sh --web Tests/SecurityAudit
   ```

   Result: exit 0, 2 of 2; the harness cleaned up the temporary processes.

Node was taken from the runtime already available in Codex; it was not installed. The reproduction scripts require macOS, clang and the already compiled host at the arm64 path of `.build`. The original logs were kept in `.build/security-audit/`.

The following were not run: the full suite, tests on the real Keychain, TCC/Accessibility, a real tailnet and phone, the packaged release application, long-running fuzzing, or destructive saturation tests. The correspondence of an external binary with this code has not been checked. No fixes were applied, no commit was created and no production code was changed.

## Recommended order

1. Resolve local protocol authorization and harden signing.
2. Disable OSC 52 writing by default and bound socket input.
3. Build the final package in a complete environment and run negative authorization/injection tests, the security suite and lints.
4. Validate mobile access, revocation and previews on a real device.
5. Until then, use only trusted projects or an isolated account/VM; keep mobile access and voice services disabled if they are not needed.

4 Important (2 high, 2 medium), 0 Nit
