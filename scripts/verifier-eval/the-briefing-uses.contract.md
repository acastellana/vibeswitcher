The briefing uses ELEVENLABS_API_KEY from the user's shell when no key is saved

A user who already has ELEVENLABS_API_KEY in their shell never has to paste the key into Settings. When no key is saved in the Keychain, the briefing (Mac and phone) uses the one from the user's login shell environment, or from ~/.config/elevenlabs/key.env. Settings › Briefing shows where the key comes from ("From your shell: ELEVENLABS_API_KEY", "Saved in your Keychain", or "None: the Mac's voice reads it"). A key typed in Settings still wins, and Remove clears only the saved one.

Acceptance checks:
- The key is looked up in this order: the Keychain item (as today); then ELEVENLABS_API_KEY from the user's login shell, read once per app launch and refreshed when Settings opens, through the same login-shell environment the app already reads for sessions (no new shell per briefing); then ~/.config/elevenlabs/key.env (a KEY=value or `export KEY=value` line, nothing executed). The value is held in memory only and never written to defaults, logs, power.json, the phone or any file.
- Settings › Briefing shows the source line with the variable or file name, never the value, plus a 'Save to Keychain' button when the source is the shell or file. Test voice works with a shell-sourced key.
- Tests with injected key sources (no real shell or Keychain): each source alone, the order, the env file's parsing (quotes, export, comments, CRLF), a malformed file ignored, and the value never appearing in the Settings text or the phone reply (plain and base64).
- Full suite twice via scripts/test.sh (web tests included), output to files and grepped. Screenshot of the Settings section in each of the three states.

Boundaries:
- Sources/VibeSwitcher/Briefing/, the Briefing section of SettingsWindow, Sources/VibeCore where the key store is defined (AppProof.KeychainSecret's callers, not its storage), the login-shell environment reader the app already has, Tests/
- Don't change how the Keychain item is stored or its access; never read the user's real shell or Keychain in tests; never log or print the value; never install
- Git: `git merge project-lead` to update, never rebase; report(summary:) once with the commit and screenshots

Context:
2026-10-21 11:4x (lead). The user asked why Settings asks for the ElevenLabs key when it's already in their environment. The lead checked by name only: ELEVENLABS_API_KEY is exported in ~/.zshrc and also present in ~/.config/elevenlabs/key.env. A Finder-launched app doesn't inherit .zshrc variables, which is why the app couldn't see it. The app already reads the user's login-shell environment to launch sessions; find that code and reuse it. Today the key lives in the login Keychain under service dev.vibeswitcher.app-proof, account elevenlabs-api-key, with app-only access (LeadVaultAppProof.swift).

2026-10-21 12:0x (lead): the worker reported done at e42ccae. The audit is held only because the Mac is on battery under the user's 50 % limit (40 % at 12:0x); start it when AC power returns. For the verifier: check that no path logs or stores the value; that the shell read can't run on the main thread or more than once per launch plus once per Settings open; that the env-file parser executes nothing; and that a Keychain key always wins.
