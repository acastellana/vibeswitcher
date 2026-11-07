# Secret sweep — 7 November 2026

The question: is a secret anywhere in the repository? **No real secret was found**: not in the tree at main, not in any
commit reachable from main, not in a commit message, and not in the two pushed commits on
`origin/security/harden-host-and-credentials` that main doesn't have. Every hit below is a made-up test value, a
public example value, a hash, or a false positive. Nothing in history needs rotating, and no history rewrite is
called for.

Values are never quoted here: a hit is named by its file (and blob or commit) and its kind, its value masked to its
first 4 characters and `…`. "Secret" means what the task said: an API key or token, a private key or seed phrase, a
password, a session cookie, a real wallet private key, or the owner's private data (a real email address outside an
attribution line, a home path with personal data, a keychain dump).

## What was scanned

| Scope | Count |
| --- | --- |
| Commits reachable from main (`4a57434b`, rescanned after passes at `391fbce5` and `d3f50c5d`) | 1,935 |
| Unique file versions (blobs) in those commits: every version of every file, fixtures, test data, `docs/lead/` and `docs/protocol/` included | 6,335 |
| Files in the tree at main | 1,194 |
| Commit messages | 1,935 |
| Pushed commits outside main (`origin/security/harden-host-and-credentials`), their 41 new blobs and 2 messages | 2 |
| Images added since the 2026-10-27 review (see [PUBLICATION-REVIEW.md](PUBLICATION-REVIEW.md), which OCR'd the 401 before them), OCR'd locally with Apple Vision | 12 |

`origin/project-lead` has no commits outside main. gitleaks and trufflehog aren't installed, and nothing was installed.

## Commands

1. `git rev-list --objects main`: every blob reachable from main, each with a path it was committed at.
2. A scanner (Python, run with `-I`) feeds those blobs through `git cat-file --batch` and runs every pattern over each
   whole blob, then over every message of `git log main`. It writes kind, blob, path, line, masked value, length and
   a hash of the value, never the value. Patterns:
   - SecretShapeLint's 16 shapes, copied verbatim from `Sources/VibeCore/SecretShapes.swift`: Slack and Discord
     webhooks, Slack, Stripe, AWS (ID and secret), Google, GitHub, GitLab, SendGrid, npm, PyPI, Hugging Face, age,
     Anthropic and OpenAI keys.
   - Wider nets: a PEM/OpenSSH/PGP private-key header, any `sk-ant-…`, any other `sk-…` of 20+ characters, JWTs,
     `Bearer …` tokens, 64 hex digits (an Ethereum or other raw private key) with or without `0x`, `password=`-style
     assignments, `api_key`/`client_secret`/`access_token` assignments, session cookies (`sessionKey`, `session_id`,
     `__Secure-…`, `cf_clearance`, `connect.sid`, `Cookie:` headers), mnemonic words, email addresses, `/Users/<name>`
     paths, keychain-dump markers (`keychain: "`, `"svce"<blob>=`, `security dump-keychain`,
     `find-generic-password … -w`), and an `OPENAI_API_KEY=` with a value.
3. A second pass over the same blobs: 12 or more words in a row from the BIP39 English wordlist (the repository's
   `Sources/VibeCore/WalletWordlist.swift`) as a seed phrase, the body length of every private-key block, and every
   distinct email address and `/Users/<name>`.
4. `git rev-list main | xargs -n 200 git grep -lE '"ciphertext"|"kdfparams"|OPENAI_API_KEY *= *[^ $]|sk-proj-…|sk-[A-Za-z0-9]{32,}|"sessionKey"|sk-ant-sid'`:
   a keystore, a speech-to-text key or a claude.ai session key in any commit of main.
5. `git log main --format=%ae/%ce` and `git log main --name-only`: authors, and every path ever committed, checked
   for `.env`, `.pem`, `.p12`, `.key`, `id_rsa`, keystores, keychains, databases, `.netrc` and `.npmrc`.
6. Steps 1 and 2 again over `git rev-list --objects origin/security/harden-host-and-credentials --not main`.
7. Vision OCR of the 12 images, its text grepped for keys, tokens, passwords, emails, home paths and seed words.

## Hits and how each is classified

| Kind | Hits (all versions) | In the tree at main | Distinct values | Classification |
| --- | --- | --- | --- | --- |
| Slack webhook, Discord webhook, GitLab, Google, SendGrid, PyPI, age, GitHub | 1–2 each | 0 | 1 each | Made up. Older versions of `Tests/VibeCoreTests/RedactionAgreementTests.swift` and `LoadRecorderTests.swift`, and `docs/eval/security.md`: alphabet runs (`AbCd…`, `0123…`), and the PyPI (`pypi…`, 53 chars) and age (`AGE-…`, 56 chars) ones are too short for a real token of their kind (a real PyPI token is a macaroon of 150+ characters, a real age key 74). These literals were later assembled at run time when SecretShapeLint arrived. |
| AWS access key ID | 9 | 0 | 2 | Public example: AWS's documented `AKIA…EXAMPLE` ID, and an `AKIA…` made of a repeated run (`RedactionLeakTests.swift`). |
| AWS secret access key | 2 | 0 | 1 | Public example: AWS's documented `wJal…EXAMPLEKEY` (`docs/eval/security.md`, old `RedactionAgreementTests.swift`). |
| Anthropic `sk-a…` | 10 | 5 | 5 | Made up: repeated or sequential bodies in `HeavyJobsTests.swift`, `PendingPromptTests.swift`, `LoadRecorderTests.swift` and `Tests/Tools/capture-claude-status-rows.py` (a repeated run, 56 chars, short of a real key's 100+). |
| Bearer token | 8 | 2 | 2 | Made up: `Bear…` over `aaaa…` and over a sequential run (redaction tests). |
| API key assignment | 9 | 3 | 3 | Made up: `ELEVENLABS_API_KEY=sk_single`-style words in `BriefingKeyTests.swift`; the capture script's repeated run above. |
| PEM / OpenSSH / PGP private key | 83 | 17 | 4 headers | Made up: redaction fixtures quote a header over a body of 1 to 43 characters (`MIIE…`, `lQOY…`, and `b3Bl…`, the public `openssh-key-v1` prefix), or a run built at run time. No block in any version has a whole 64-character body line. |
| 64 hex digits | 115 | 46 | 9 | False positive: the `Package.resolved` origin hash, the BIP39 wordlist's SHA-256, genesis hashes and a signing hash in wallet tests and `scripts/e2e/testdata/`, and repeated or sequential runs in `docs/protocol/vectors/`. None is a private key. |
| BIP39 phrase (12+ words) | 2 runs | 2 | 2 | Made up: the wordlist's own first 12 words in order (`VaultFormatTests.swift`, `WalletRequestFormatTests.swift`, `docs/protocol/vectors/result-invalid-key-in-detail.json`), and the 2048-word list itself (`VaultWordlist.swift`). |
| Mnemonic words | 51 | 7 | 2 | False positive: prose saying never to put a seed or recovery phrase in a request, and a test checking the sign page doesn't ask for one. |
| Password assignment | 141 | 30 | 23 | Made up or false positive: `hunt…`, `s3cr…`, `corr…` and repeated runs in redaction tests; the redaction code's own word lists (`Redaction.swift`); `UUID().uuidString` and `openssl rand` made at run time (`AppProofTests.swift`, `scripts/setup-signing.sh`); comments naming where the Wallet Manager's throwaway passphrase lives outside the repository (`scripts/e2e/wallet-e2e.sh`), whose test fakes it. |
| Keystore (`"ciphertext"`) | 107 versions | 1 file | 1 | Made up: `WalletE2EScriptTests.swift` writes a v3 keystore's shape holding a marker string, no key. |
| Session cookie | 226 | 4 | 2 | False positive: `sessionID = …` code in `AppDelegate.swift`. |
| Keychain dump | 61 | 4 | 2 | False positive: `security dump-keychain` on a scratch keychain the signing test makes (`scripts/test-signing.sh`), and a doc comment naming `find-generic-password -w`. |
| OpenAI key (`…T3BlbkFJ…`), any other `sk-…`, `sk-proj-…`, `OPENAI_API_KEY=`, JWT | 0 | 0 | 0 | No copy of the speech-to-text key, or any OpenAI key, was ever committed. |
| Email address | 1,735 | 91 | 14 | Attribution or made up: `nore…@anthropic.com` (all 1,153 in commit messages are Co-Authored-By lines), `@example.com`, `@example.invalid`, `@vibeswitcher.invalid`, `@explorer.example`, `@else.com`, `git@github.com`, a `users.noreply.github.com` address, and credential-URL fixtures (`s3cr…@github.com`, `oaut…@gitlab.com`). Neither of the owner's real addresses is in any file version or message. |
| `/Users/<name>` path | 26,658 | 753 | 14 names | Not a secret. Made-up names (`me`, `you`, `x`, `a`, `jane`, `someone`, `sandbox`, `bench`) in tests, and the owner's two macOS user names in tests, `docs/eval/` logs and scripts, `docs/lead/`, and one commit message (`07643cd7`). Those paths name the owner's projects (`~/dev/vibeswitcher`, `~/.vibeswitcher/lead/scratch`, `~/.claude/projects/…`, two pasted-image names), nothing more personal. Flagged for the user below. |
| Suspicious paths | — | — | — | None: no `.env`, `.pem`, `.p12`, `.key`, `id_rsa`, keystore, keychain, database, `.netrc` or `.npmrc` was ever committed. |
| OCR of the 12 new images | — | — | — | None: the text shows cost lines (`28M tokens`) and UI, with no key, token, password, email or home path. |

## For the lead and the user to decide

- **No rotation is needed**: no real credential was found, in history or in the tree.
- **The owner's macOS user names** appear in about 750 lines of the tree and in history (tests, `docs/eval/`,
  `docs/lead/`, one commit message). Commit metadata already publishes one of them through the work author address
  (about 1,800 commits) and a machine-local address in the rest. This is
  identifying, not a secret. Replacing the paths in the tree would be cosmetic while history and authorship keep them,
  so they were left alone. Hiding them for good would mean rewriting history and the author addresses, which this
  task doesn't do.

## What changed

`SecretShapes` gained a **Private key** shape: a PEM, OpenSSH or PGP private-key header followed by a whole body line
(64 base64 characters, indented or not, after a real newline or a string literal's `\n`). Until now nothing caught a committed private
key. SecretShapeLint has a new case, `aPrivateKeyIsItsHeaderAndABodyLine`, and a new sample in
`aLiteralIsNamedWithItsLineAndAnAssembledStringIsNot`. Both fail without the shape. `tell_lead` uses the same list,
so it now refuses a message holding a private key. Its masked copy in `.vibeswitcher/lead-mail.jsonl` masks only the
header and first body line, though, not the rest of the key.

## Limits

Patterns, length checks and OCR can't prove that no secret exists: an unknown format, an obfuscated value, or a key
split across a string could get past them. The private-key shape misses old encrypted PEM keys (`Proc-Type:` lines
before the body), PGP armor with `Version:` or `Comment:` lines, and a literal's `\r\n`; the sweep's own header
pattern (step 2) had no such gap. Only main's history, and the pushed branches visible locally, were
scanned. Whether GitHub holds other refs (for example closed pull requests) wasn't checked: nothing was fetched.
