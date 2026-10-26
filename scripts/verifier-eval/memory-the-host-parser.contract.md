Memory: the host parser keeps a small scrollback; phone history is served on demand

Cut the host parser's memory. Memory audit P1 (docs/eval/memory-2026-10-22.md): SessionParser.swift:61 keeps 5,000 lines of scrollback per session, measured at 352 MB across sessions. Keep about 200 lines in the parser and serve longer history (the phone's scroll-back) on demand from the session's own log or transcript, so nothing the user sees today is lost.

Acceptance checks:
- Measured before/after host memory with the audit's method (no leaks/sample/footprint attach outside the suite's own bounded checks), numbers in the report
- The phone can still scroll back as far as today; a test proves history beyond the parser's lines is served
- Screen reads, prompt detection and stall checks behave as before (their tests pass)
- New tests proven under scripts/test-under-load.sh
- bash scripts/test.sh passes

Boundaries:
- Sources/VibeHost (SessionParser and where history is served), the phone history route and their tests
- Don't touch the app's terminal views (separate task)
- No debuggers

Context:
Read docs/eval/memory-2026-10-22.md first (finding 1 and its fix sketch). The host was just changed today by host-orders-text-enter (InputOrder) and host-a-session-ending (PTY read source); stay out of the input path.
