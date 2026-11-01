# Wallet requests: wallet-request v1 and wallet-result v1

How VibeSwitcher asks the Wallet Manager's Mac for a transaction, and how the Wallet Manager answers. This document is the contract
between the two sides: VibeSwitcher (this repository: `Sources/VibeCore/WalletRequestFormat.swift`, `WalletRequest.swift`,
`WalletRequestStore.swift`, `WalletCourier.swift`, `PassageLink.swift`) and the Wallet Manager on its Mac (another
project), which implements the receiving end from it. Where this document and either implementation disagree, this
document is right and the implementation has a bug.

The words MUST, MUST NOT and MAY are used as in RFC 2119.

## Contents

- [Roles](#roles)
- [Transport](#transport)
- [Encoding rules (both formats)](#encoding-rules-both-formats)
- [wallet-request v1](#wallet-request-v1)
- [wallet-result v1](#wallet-result-v1)
- [The life of a request](#the-life-of-a-request)
- [What each side checks](#what-each-side-checks)
- [Examples](#examples)
- [Test vectors](#test-vectors)
- [Versions](#versions)

## Roles

Three apps on two Macs:

- **VibeSwitcher**, on the working Mac, only *initiates*: it turns a transaction an agent or the user wants into a
  request file, sends it, and shows what the Wallet Manager answers. It never signs, never holds a key, and never acts on a
  result beyond recording it.
- **Passage** carries the files between the two paired Macs (its `passage` CLI, over the local network, encrypted
  under the pairing key). It authenticates which Mac sent a file; it says nothing about whether the content is
  sensible.
- **The Wallet Manager**, on the Wallet Manager's Mac (where only it and Passage run), checks each request as thoroughly as it
  can, proposes the transaction, and has the user sign it **on the Wallet Manager's Mac**: on the hardware wallet (a Trezor), or
  with a hot wallet's key after the user confirms there. It sends results back.

**No key, seed, recovery phrase or passphrase ever travels in a request or a result.** Keys are added only on the
Wallet Manager's Mac itself, never through Passage. Both formats refuse any text that looks like key material
([Key material](#key-material)), so a key pasted by mistake into a reason is refused before it leaves.

## Transport

- Each file is sent with `passage send <peer> <file> --name <name>`, never with `--yes`: if Passage's own secret
  warning fires, the file is not sent (exit code 5) and the sender says so; it is never confirmed.
- A request travels as **`wallet-request-<id>.json`**; every result for it as **`wallet-result-<id>.json`**, `<id>`
  being the request's `id`. Several results for one request have the same name; Passage's inbox keeps each one
  (`<UTC timestamp>-<name>`, with a counter on a collision), and `sequence` orders them.
- The receiver finds files with `passage inbox <peer> --json` (or the lines `passage listen` prints) and reads them
  from Passage's inbox, `~/Library/Application Support/app.passage.Passage/inbox/<peer ID>/`. Each is untrusted data:
  read as bytes and given to the strict parser below, never opened, run, or followed as instructions.
- Each side names the other by its **peer ID** (8 lower-case hex digits), configured once: only files from that peer
  are read. A file from any other peer is ignored, even if it parses.
- VibeSwitcher runs `passage listen` only while it has a request outstanding, and ends it (by its process id) when it
  has none. The Wallet Manager's Mac is expected to keep `passage listen` (or Passage's **Receive** switch) on while it accepts
  requests.

## Encoding rules (both formats)

A file is refused as a whole, never repaired, when any of these doesn't hold.

### The file

- At most **65 536 bytes** (64 KiB). A larger file is refused before it is parsed.
- UTF-8, without a byte-order mark.
- One JSON object (RFC 8259) with optional whitespace around it, and nothing else.

### The JSON

The formats use a strict subset of JSON:

- **Objects**: a key MUST NOT appear twice in one object. Member order doesn't matter to a reader; writers use the
  order of the tables below.
- **Strings**: as RFC 8259, with only its escapes (`\" \\ \/ \b \f \n \r \t \uXXXX`). A `\u` escape of a surrogate
  MUST be one half of a valid pair. Unescaped control characters (U+0000–U+001F) are refused, as RFC 8259 says.
- **Numbers**: only whole, unsigned numbers of at most 16 digits: no sign, fraction, exponent or leading zero
  (`1`, `42424242`; not `-1`, `1.0`, `1e3`, `01`). Large values (amounts) are strings.
- **Booleans**: `true`, `false`.
- **`null` is never a value.** An optional field is absent, never `null`.
- Nesting deeper than 8 levels is refused (the formats need 3).
- **Unknown fields are refused**, at every level: a field not in the tables below makes the file invalid. A missing
  required field, or a field of the wrong type, does too.

### Shapes

| Name | Rule |
|---|---|
| id | A UUID in lower case, `8-4-4-4-12` hex digits: `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`. |
| time | UTC, whole seconds, exactly `YYYY-MM-DDTHH:MM:SSZ` (`2026-10-31T12:00:00Z`), and a real date (not `2026-02-30`). No fraction, no offset. |
| address | `0x` (lower-case x) and exactly 40 hex digits, either case: `^0x[0-9a-fA-F]{40}$`. Mixed case is taken; the Wallet Manager verifies an EIP-55 checksum when the case is mixed. |
| hash | `0x` and exactly 64 hex digits: `^0x[0-9a-fA-F]{64}$`. |
| name | 1–64 characters of `A–Z a–z 0–9 . _ -`, the first a letter or digit: `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`. |
| line(n) | Text of at most n Unicode scalar values, with no control character (Unicode category Cc) and no format character (Cf: bidi overrides, zero-width characters). |
| text(n) | As line(n), but line feeds (U+000A) are allowed. |

Lengths count Unicode scalar values (code points), not bytes or grapheme clusters. "1–n" means it may not be empty;
"0–n" means it may.

### Key material

A request is refused when any of its string fields except `data`, and a result when any of its string fields except
`txHash` and `safeTxHash`, holds:

1. `-----BEGIN` anywhere (a PEM key block);
2. a run of **64 or more hex digits** (`0-9 a-f A-F`) in a row, with or without `0x` before it (a raw private key);
3. a run of **12 or more words of the BIP39 English wordlist** in a row (a recovery phrase). The text is lower-cased
   and split into words at every character that isn't `a`–`z`; a run counts consecutive words that are all in the
   list (bip-0039/english.txt, 2048 words), whatever separates them.

A result's `explorerURL` may contain a run of 64 hex digits only when the run is the result's `txHash` or `safeTxHash`
(without `0x`, in any case). `data` is calldata, made of 32-byte words, and isn't screened: what it means is for the
Wallet Manager to decode and show.

An amount, being digits only, counts as hex digits too; amounts are capped at 60 digits, so they never reach 64.

## wallet-request v1

Sent by VibeSwitcher to the Wallet Manager. All fields are required unless marked optional.

| Field | Type | Rule |
|---|---|---|
| `type` | string | Exactly `"vibeswitcher.wallet-request"`. |
| `version` | number | Exactly `1`. |
| `id` | string | An id (above). New for every request, never given to another one. Only the same request, byte for byte, is ever sent again under it (step 3 of [The life of a request](#the-life-of-a-request)). |
| `createdAt` | string | A time: when VibeSwitcher made the request. |
| `expiresAt` | string | A time after `createdAt`, by at most 7 days (604 800 s). VibeSwitcher's default is `createdAt` + 24 hours. |
| `requestedBy` | object | Who asked: exactly the three fields below. |
| `requestedBy.project` | string | line(200), 1–200: the project the request was made from. |
| `requestedBy.session` | string | line(200), 1–200: the session (agent) that made it. |
| `requestedBy.label` | string | line(200), 0–200: a label for people (may be empty). |
| `workspace` | string | A name: which of the Wallet Manager's workspaces to use. Opaque to VibeSwitcher; the Wallet Manager has several. |
| `from` | string | The wallet to send from, in that workspace: its wallet id there (a name that doesn't start with `0x`), or its address. A value that starts with `0x` or `0X` MUST be an address. |
| `chainId` | number | 1 to 2⁵³−1 (9 007 199 254 740 991). Any chain id is taken by the format; the Wallet Manager refuses chains it doesn't know. Known now: Ethereum mainnet (`1`), GenLayer mainnet (`42424242`), GenLayer testnet (`4221`). |
| `action` | string | `"transfer"` or `"call"`. |
| `to` | string | An address: the recipient (`transfer`) or the contract called (`call`). |
| `asset` | string | `"native"` (the chain's own coin) or a token contract's address (an ERC-20 transfer). |
| `amount` | string | In the asset's base units (wei for the native coin), decimal digits: `^(0\|[1-9][0-9]{0,59})$`, at most 60 digits. |
| `data` | string | Optional: only, and always, with `"call"`: the calldata, `0x` and an even number of hex digits, 4 to 24 576 bytes (8 to 49 152 digits). |
| `reason` | string | text(1000), 1–1000: why, in the requester's words. Shown to the person who signs. |

And, across fields:

- `"transfer"`: no `data`; `amount` more than `0`. With a token `asset`, the Wallet Manager builds the ERC-20 `transfer(to,
  amount)` itself.
- `"call"`: `data` present; `asset` is `"native"`; `amount` (which may be `0`) is the native value sent with the call.
- The whole request passes [Key material](#key-material).

## wallet-result v1

Sent by the Wallet Manager to VibeSwitcher, each time the request's status changes. All fields are required unless marked
optional.

| Field | Type | Rule |
|---|---|---|
| `type` | string | Exactly `"vibeswitcher.wallet-result"`. |
| `version` | number | Exactly `1`. |
| `id` | string | The request's `id`. The same as the `<id>` in the file's name. |
| `sequence` | number | 1 to 1000: `1` for the Wallet Manager's first result on this request, one more for each after it. |
| `createdAt` | string | A time: when the Wallet Manager wrote the result. |
| `status` | string | One of the statuses below. Any other value is refused. |
| `checks` | array | 0 to 64 checks the Wallet Manager ran, each an object of exactly the three fields below. |
| `checks[].name` | string | line(100), 1–100: what was checked (`"chain"`, `"balance"`, `"recipient"`, …). |
| `checks[].ok` | boolean | Whether it passed. |
| `checks[].detail` | string | text(1000), 0–1000: what the check saw. |
| `txHash` | string | Optional: a hash: the transaction on the chain. Required with `"submitted"`; allowed with `"failed"`; refused with any other status. |
| `safeTxHash` | string | Optional: a hash: the Safe transaction. Allowed with `"proposed"`, `"signed"`, `"submitted"`, `"failed"`; refused with `"received"` and `"rejected"`. |
| `explorerURL` | string | Optional, only with `txHash` or `safeTxHash`: a link to see it. `https://` only, with a host, no user or password, printable ASCII without spaces, at most 2000 characters. |
| `message` | string | text(2000), 0–2000: a sentence for people. |

**Statuses** (final ones end the request: nothing more is taken for it):

| Status | Final | Means |
|---|---|---|
| `received` | no | The Wallet Manager has the request, it parsed, and checks are under way. |
| `rejected` | yes | Refused: a check failed (see `checks`), the request expired, or the person declined. |
| `proposed` | no | Built and shown on the Wallet Manager's Mac for signing; for a Safe, proposed to the Safe (`safeTxHash`), waiting for its owners. |
| `signed` | no | Signed (on the hardware wallet, or with the hot wallet's key after the person confirmed), not yet on the chain. |
| `submitted` | yes | Sent to the chain: `txHash`. |
| `failed` | yes | Went wrong after it was accepted: the signing, the submission, or a reverted transaction (`txHash` when there is one). |

The whole result passes [Key material](#key-material).

## The life of a request

1. **Made.** VibeSwitcher builds the request (`createdAt` now, `expiresAt` by default 24 hours later) and writes its
   file. It checks its own bytes with the same strict parser the Wallet Manager uses: a request that fails, key material
   included, is refused and never sent.
2. **Recorded.** VibeSwitcher records the request as outstanding, `sending`, in a private file
   (`~/.vibeswitcher/wallet-requests/<id>.json`, mode 0600, in a 0700 folder), and starts `passage listen` if it
   isn't running.
3. **Sent.** `passage send <Wallet Manager peer> <file> --name wallet-request-<id>.json`. The exit code decides:
   | Exit | VibeSwitcher's outcome |
   |---|---|
   | 0, and it printed `sent<TAB><Wallet Manager peer><TAB>wallet-request-<id>.json<TAB><bytes>` | `sent`: the record is kept, now `sent`. |
   | 1 | `failed`: the connection, handshake, file, inbox or Keychain failed. |
   | 2 | `usage`: passage didn't take the command line. |
   | 3 | `noSuchPeer`: no paired peer is the configured Wallet Manager peer. |
   | 4 | `peerNotListening`: paired, but no `passage listen` answered on the Wallet Manager's Mac. |
   | 5 | `refusedAsSecret`: Passage's own secret check fired; never confirmed. |
   | anything else, a signal (never read as an exit code), past the time limit, or 0 without that line | `unexpected`. |

   On 2, 3, 4 and 5 passage stopped before anything went: the record is removed, and the request is simply not
   sent. On 1 and `unexpected` the Wallet Manager may have the file all the same (passage gave up after connecting, or
   before its acknowledgement): the record stays, as `unsure`, outstanding like a sent one, and takes the Wallet Manager's
   results. VibeSwitcher MAY send the same request again, the same bytes under the same id, and only while it is
   `unsure`; the Wallet Manager ignores the repeat if it had the first ([Replays](#replays)). A `sending` record found at
   launch (the app stopped mid-send) is kept as outstanding too, as `unsure`: it may have gone.
4. **Checked.** The Wallet Manager reads the file from its inbox and checks it ([The Wallet Manager, on a request](#the-wallet-manager-on-a-request)).
   It answers `received` (sequence 1) as soon as the request parses, then `rejected` if a check fails, or
   `proposed` once it's ready to sign. A request from the configured VibeSwitcher peer, named
   `wallet-request-<id>.json` with `<id>` an id, that doesn't parse or breaks the format (corrupted on the way, say,
   or written by a VibeSwitcher whose rules differ) is answered once, under the `<id>` in its name, with a single
   result: `rejected` (sequence 1, no `received` before it) whose `checks` hold only the
   [format check](#the-format-check). VibeSwitcher shows it on the card as rejected, with that check's detail. A file
   from another peer, or whose name isn't that, gets no result.
5. **Signed.** The person signs on the Wallet Manager's Mac: `signed`, then `submitted` with `txHash` once it's on the chain,
   or `failed`. The Wallet Manager resolves what kind of wallet `from` is in the `workspace`:
   - a **hardware wallet**: signed on the device;
   - a **hot wallet** (the Wallet Manager holds its encrypted key): signed with that key after the person confirms on the
     Wallet Manager's Mac;
   - a **Safe**: `proposed` with `safeTxHash` while the other owners sign, then later `submitted` with `txHash`
     once it's executed.
6. **Taken.** VibeSwitcher lists the Wallet Manager peer's inbox (`passage inbox <Wallet Manager peer> --json`), whenever
   `passage listen` prints a line and whenever the app asks, and takes each new result for an outstanding request,
   in `sequence` order ([VibeSwitcher, on a result](#vibeswitcher-on-a-result)).
7. **Ended.** A request stops being outstanding when a final result is taken, or one hour after `expiresAt`
   (a result in flight when it expired still lands). Its record stays, with every result taken. When no request is
   outstanding VibeSwitcher ends `passage listen`.

**Expiry.** The Wallet Manager MUST NOT propose or sign a request after its `expiresAt`; one it first sees after that it
answers `rejected` ("expired"). A Safe whose owners finish after VibeSwitcher stopped listening is not heard of:
for a Safe, the requester picks a longer `expiresAt` (up to 7 days).

### Replays

The Wallet Manager MUST act on an `id` at most once: the `<id>` in a request file's name, whether or not the file
parses (answering one with the [format check](#the-format-check) is acting on it). A request file with an `id` it has
already seen, whether the same request sent again or a different one, is ignored **silently**: no result of any kind, under any sequence. (Results
are matched to requests by `id` alone, so a `rejected` for the repeat would end the original's tracking on
VibeSwitcher while the Wallet Manager went on with it.) The Wallet Manager keeps the ids it has seen for at least 7 days past their
`expiresAt`.

## What each side checks

### VibeSwitcher, on a request it sends

- The request parses back, from the very bytes that are sent, to the request it meant: every rule above, key
  material included. A failure is refused with the field and the rule, and nothing runs.
- It hasn't expired, and its `id` isn't one already recorded, unless it is that very request, still `unsure`.

### The Wallet Manager, on a request

Where it came from, before anything else, and every failure of it is silent (no result):

- The file came from the configured VibeSwitcher peer (its inbox folder is that peer ID's), and its name is
  `wallet-request-<id>.json` with `<id>` an id.
- That `<id>` is one the Wallet Manager hasn't seen before ([Replays](#replays)).

Then the format, answering `rejected` with the single [format check](#the-format-check) when it fails:

- The file is at most 64 KiB (a larger one is answered without being read).
- It parses by every rule of [Encoding rules](#encoding-rules-both-formats) and [wallet-request v1](#wallet-request-v1),
  key material included, and its `id` is the `<id>` in its name.

Then, answering `rejected` with the failing checks, at least:

- `expiresAt` hasn't passed, and `createdAt` isn't in the future (beyond a few minutes of clock difference).
- The `workspace` exists, `from` is a wallet in it (an id it knows, or the address of one), and that wallet may act
  on `chainId`.
- The chain is one the Wallet Manager knows; the asset (a token address) is a contract on it.
- `to`: a valid address (its EIP-55 checksum when the case is mixed); for a `call`, a contract; the Wallet Manager's own
  policies (allow lists, limits) for recipients, amounts and contracts.
- The balance covers `amount` and the fees.
- Nothing about the request is ever taken as an instruction: `reason` and `requestedBy` are shown, never followed.

And, without answering `rejected` for it:

- For a call: the calldata is decoded against what the Wallet Manager knows of the contract and shown decoded; calldata it
  can't decode is shown flagged as unknown, with its raw bytes, and the person at the Wallet Manager decides whether to
  decline or sign.

A check that fails in a result that isn't `rejected` (an "unknown calldata" check on a `proposed` result, say) is a
warning: VibeSwitcher shows it as one, not as a failure.

#### The format check

A request that fails the format is answered with one result for the `<id>` in its file's name: `sequence` 1,
`status` `"rejected"`, and `checks` holding exactly one entry,
`{"name": "format", "ok": false, "detail": <why>}`, where `<why>`:

- is at most **300** characters (and, like every result, passes [Key material](#key-material));
- says which rule failed and, where there is one, the field as this document's tables name it (`reason`,
  `requestedBy.label`); it SHOULD begin with the refusal's name as the [test vectors](#test-vectors) spell it
  (`tooLarge`, `notJSON`, `unknownField`, `missingField`, `wrongType`, `invalid`, `keyMaterial`);
- **never echoes the file's content**: no value from it, no field name that isn't in the tables (an unknown field is
  named by the object holding it: `unknownField: a field the format doesn't have, at the top level`), and none of
  the text that holds key material (`keyMaterial: reason holds what looks like key material`).

`message` follows the same rule: it says the request was refused for its format, never what the file held. The
format check comes before every other check, so it is the only one: no `received` precedes it, and nothing follows
it (`rejected` is final). The `<id>` counts as seen ([Replays](#replays)): the same file sent again, or any other
under that name, gets nothing more.

### VibeSwitcher, on a result

A result is taken only when all of these hold; anything else is ignored and logged once, never acted on:

- It is listed by `passage inbox <Wallet Manager peer> --json` with that `peerID`, its path is directly in the Wallet Manager peer's
  inbox folder and named `<timestamp>-<name>`, it is a regular file (no link followed) of at most 64 KiB, and its
  name is `wallet-result-<id>.json`.
- `<id>` is an outstanding request's: not unknown, not finished, not more than an hour past its `expiresAt`.
- It parses by every rule of [wallet-result v1](#wallet-result-v1), key material included, and its `id` is `<id>`.
- Its `sequence` is after the last one taken for the request. Results found together are taken in `sequence` order;
  a repeat, or anything after a final result (a second result for a finished request), is ignored and logged.

A `rejected` result with the [format check](#the-format-check) is taken like any other: the card shows the request as
rejected, with the check's detail, and the request is finished.

## Examples

Made-up values throughout: the workspace `example`, the wallet `example-hardware`, the address 0x000…01. Both
parse as they are (`WalletRequestFormatTests` reads them from this file). Writers may emit them on one line; whitespace
between tokens doesn't matter.

A request: 1 GEN (10¹⁸ base units) on GenLayer mainnet.

```json
{
  "type": "vibeswitcher.wallet-request",
  "version": 1,
  "id": "3f2b8c1e-5d4a-4b6f-9e0c-7a1d2e3f4a5b",
  "createdAt": "2026-10-31T12:00:00Z",
  "expiresAt": "2026-11-01T12:00:00Z",
  "requestedBy": {
    "project": "example-project",
    "session": "example-session",
    "label": "Example agent"
  },
  "workspace": "example",
  "from": "example-hardware",
  "chainId": 42424242,
  "action": "transfer",
  "to": "0x0000000000000000000000000000000000000001",
  "asset": "native",
  "amount": "1000000000000000000",
  "reason": "Pay the example invoice for October, as agreed.\nInvoice number EX-1."
}
```

Its last result: submitted, with the checks the Wallet Manager ran.

```json
{
  "type": "vibeswitcher.wallet-result",
  "version": 1,
  "id": "3f2b8c1e-5d4a-4b6f-9e0c-7a1d2e3f4a5b",
  "sequence": 4,
  "createdAt": "2026-10-31T12:05:00Z",
  "status": "submitted",
  "checks": [
    { "name": "expiry", "ok": true, "detail": "expires 2026-11-01T12:00:00Z" },
    { "name": "wallet", "ok": true, "detail": "example-hardware is a hardware wallet in example" },
    { "name": "chain", "ok": true, "detail": "GenLayer mainnet (42424242)" },
    { "name": "balance", "ok": true, "detail": "covers 1 GEN and the fee" }
  ],
  "txHash": "0x0000000000000000000000000000000000000000000000000000000000000001",
  "explorerURL": "https://explorer.example/tx/0x0000000000000000000000000000000000000000000000000000000000000001",
  "message": "Signed on the hardware wallet and submitted."
}
```

## Test vectors

[vectors/](vectors/) holds files both implementations test against, so both read the same examples:
[vectors/index.json](vectors/index.json) lists each one as an object with

- `file`: the file's name in that folder;
- `kind`: `"request"` (parse it as wallet-request v1) or `"result"` (as wallet-result v1);
- `valid`: whether it parses;
- for an invalid one, `refusal`, why it's refused: `tooLarge` (over 64 KiB), `notJSON` (outside the JSON subset, or
  not UTF-8), `unknownField`, `missingField`, `wrongType`, `invalid` (a value breaking its field's rule) or
  `keyMaterial`; and `field`, the field it is refused on, as a dotted path (`requestedBy.label`, `checks[0].ok`;
  `""` for the document itself), absent for `tooLarge` and `notJSON`;
- `note`: one line saying what it is.

Each invalid file breaks exactly one rule, so it's refused for that reason whatever order a reader checks in. All
values are made up. The valid request and result whose names end in `-transfer-native` and `-submitted` are the
examples above. `result-valid-rejected-format.json` is the answer to a request that fails the format
([The format check](#the-format-check)).

## Versions

This is version 1 of both formats. A change that a v1 reader would refuse or misread (a new field, a new status, a
looser rule) is a new version, with a new `version` number; a reader refuses a version it doesn't know. Both sides
are updated together.

### History

- 2026-11-01: still version 1. A request from the configured VibeSwitcher peer, named `wallet-request-<id>.json` with
  `<id>` an id, that doesn't parse or breaks the format (64 KiB, JSON, fields, key material, its `id` not its name's)
  is now answered with `rejected` under that `<id>`, its only check `format` with a detail of at most 300 characters
  that never echoes the file ([The format check](#the-format-check)); before, it got no result and its request hung at
  sent until it aged out. The file's name and the authenticated Passage peer are enough to answer it. The at-most-once
  rule now counts the name's `<id>`, checked before the file is parsed. Such a result is an ordinary v1 result (a
  vector: `result-valid-rejected-format.json`); a v1 reader takes it as it is.
- 2026-10-31: renamed, still version 1. The formats were vault-request v1 and vault-result v1, their `type`s
  `"vibeswitcher.vault-request"` and `"vibeswitcher.vault-result"`, their files `vault-request-<id>.json` and
  `vault-result-<id>.json`, and this document `docs/protocol/vault-request.md`; they are now `wallet-request` and
  `wallet-result` throughout, so that in VibeSwitcher "vault" names only the lead's own store. No field, rule or
  status changed. A reader takes only the new names; both sides were updated together.
