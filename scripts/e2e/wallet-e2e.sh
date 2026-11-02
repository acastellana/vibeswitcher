#!/bin/bash
# The local end-to-end wallet run, on this Mac and with made-up data only: the VibeSwitcher sandbox (this worktree's
# build) files a wallet request as a fake agent and clicks Send; the loop passage (scripts/e2e/loop-passage) carries it
# into a Wallet Manager running from ~/dev/wallet-manager on a scratch synthetic vault; its real receiving code checks
# it and answers; the answer comes back through the loop and updates the card. Only Passage's link between two Macs
# is stood in for. Run on demand (never part of scripts/test.sh): it needs the Wallet Manager's checkout.
#
# scripts/e2e/wallet-e2e.sh [--wallet-manager DIR] [--binary PATH] [--keep]
# scripts/e2e/wallet-e2e.sh --real-testnet [--dry-run|--check-guards] [--amount WEI] [--from 0x…] [--to 0x…] [--chain N]
#                           [--wallet-manager DIR] [--binary PATH] [--keep]
# scripts/e2e/wallet-e2e.sh --judge-case-1 SEEN RECORD
# scripts/e2e/wallet-e2e.sh --judge-sign-page PAGE [--amount WEI]
# scripts/e2e/wallet-e2e.sh --judge-real-results DIR ID
#   --wallet-manager DIR  the Wallet Manager's checkout (~/dev/wallet-manager). Nothing is written there but its
#                         git-ignored node_modules: when node_modules/.package-lock.json is missing or older than its
#                         package-lock.json, the run first says so and runs `npm ci --ignore-scripts` in it.
#   --binary PATH         this build of VibeSwitcher (vibeswitcher-host beside it) instead of building (sandbox-app.sh).
#   --keep                keeps the run's scratch folder (logs, vault, inboxes) and says where; else it's removed.
#   --judge-case-1 SEEN RECORD  runs nothing: judges case 1 on a recorded outcome (SEEN, the card's states as the run
#                         writes them, "waiting → sent → received"; RECORD, the Wallet Manager's record as `record`
#                         prints it, "pending true 1 wallet:ok,recipient-known:failed", or "" for none), prints its
#                         lines and exits 0 on a pass, 1 on a failure.
#   --judge-sign-page PAGE  runs nothing: judges a recorded signing page (PAGE, its HTML) as --real-testnet does before
#                         its POST, for the self-transfer of --amount (1000) wei; prints its line and exits 0 when the
#                         page signs exactly that, with no warnings, else 2 (refused).
#   --judge-real-results DIR ID  runs nothing: judges the results for request ID in DIR (the dev side's inbox folder) as
#                         --real-testnet does after its POST; prints their statuses in sequence order and exits 0 when
#                         they read received → proposed → signed → submitted, the last with a txHash, else 1.
#   --vault-format FILE   runs nothing: reads FILE (a Wallet Manager's src/vault/format.ts) as the run does; prints
#                         "VERSION CONTACT-SHAPE" ("1.11 chains") and exits 0, or why it can't and exits 1.
#
# --real-testnet: one real GenLayer testnet payment through the same chain, instead of the cases below. Never part of
# scripts/test.sh, a merge or an audit: it broadcasts a real transaction, so it runs only when asked for by name. It
# refuses (exit 2, before any network or scratch folder) unless the chain is 4221, `from` is the Wallet Manager
# project's throwaway testnet wallet (0x4c50…ab99, the address its keystore names) and the transfer is a self-transfer
# (`to` = `from`) of 1 to 1000 wei, and the Wallet Manager's own testnet (`node src/networks.ts --json`, its stable
# command: docs/protocol/sign-page.md) is chain 4221 at GenLayer's testnet RPC with a pinned genesis hash, which the RPC's
# block 0 must match before anything starts; the explorer link it prints is that entry's. The throwaway keystore and passphrase are read only from
# ~/.config/wallet-manager-testnet/ (keystore.json, passphrase: yours, regular files, 0600, in a 0700 folder), copied
# 0600 into the run's scratch vault, never printed or logged, and removed with it however the run ends (--keep keeps
# the logs, never those two). The Wallet Manager runs on that vault with no --rpc, so it uses GenLayer's testnet RPC;
# the sandbox files the request and clicks Send; the run signs on the Wallet Manager's /sign page over HTTP exactly as
# its docs/running.md, "Signing over HTTP (headless)", has it (GET the page, read its csrf, token and hash, POST the
# confirmation with the passphrase on stdin): one POST, never retried, and only when the page's machine-readable fields
# (data-sign-field / data-value, as docs/protocol/sign-page.md has them) say chain 4221, from and to the throwaway
# wallet, the amount and no call, exactly, and its data-sign-warnings lists none. Opening the page has no side effects:
# the card stays Received and the Wallet Manager's record unchanged; `proposed` comes with the POST. The states read
# waiting → sent → received → (POST) → proposed → signed → submitted (after the POST, the results the card took, in
# sequence order). It passes when the card shows Signed (the result `submitted`) with the transaction, and the RPC's
# eth_getTransactionReceipt says status 1 for that self-transfer; it prints the explorer link.
#   --amount WEI (1000), --from 0x… and --to 0x… (the throwaway wallet), --chain N (4221): checked, not chosen freely
#   --dry-run             everything up to the sign POST (the page fetched and read, the card still Received:
#                         waiting → sent → received), then stops: nothing is signed or sent
#   --check-guards        runs only the refusals above and says they pass: no network, no Wallet Manager or sandbox
#                         started (the checkout's `node src/networks.ts --json`: 4221 at GenLayer's testnet RPC)
#
# Cases, each with the card's final state and a light shot in .build/sandbox-shots/e2e/:
#   1 a valid testnet transfer from a known wallet: waiting → sent → received (or proposed), not rejected. A check
#     that failed in a result that isn't rejected is a warning (docs/protocol/wallet-request.md): named, not a failure.
#     Its recipient isn't in the vault, so a Wallet Manager with an address book warns `recipient-known`.
#  1b the same with case 1's recipient in the vault's address book (contacts/, as the Wallet Manager's
#     docs/vault-format.md has it, in its format version's shape): no warnings. Skipped, saying so, when that document
#     doesn't describe contacts/.
#   2 an unknown wallet: rejected, the failed check named on the card
#   3 the wrong chain (the testnet wallet asked for mainnet): rejected, the chain check failed
#   5 the same id sent again after an unsure send (Retry): the Wallet Manager takes it once
#   4 the Wallet Manager stopped: the request stays Sent and shows the not-picked-up hint (the desk's clock moved on)
# (5 runs before 4, which stops the Wallet Manager.) Never the real Passage, its inbox or pairings, the Keychain, a
# real key or address, or the network: the chains are the Wallet Manager's fake chain on 127.0.0.1, for both networks.
# The scratch vault says the format version the Wallet Manager under test writes (FORMAT_VERSION in its
# src/vault/format.ts, read as text): the run stops, naming the file, when it can't read one.
# At the end it stops everything it started, by pid, and checks nothing of the run is left running.
set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/scratch.sh

repo=$(pwd -P)
wm=$HOME/dev/wallet-manager
binary=""
keep=""
judge=""
judge_page=""
judge_results=""
vault_format_file=""
real=""
dry_run=""
check_guards=""
real_options=""
THROWAWAY=0x4c50c0Ae2b75B8C17d999CA2e11118A27867ab99   # the Wallet Manager project's throwaway testnet hot wallet
TESTNET_CHAIN=4221
MAX_WEI=1000
chain=$TESTNET_CHAIN
from=$THROWAWAY
to=$THROWAWAY
amount=$MAX_WEI
while [[ $# -gt 0 ]]; do
    case $1 in
        --wallet-manager|--binary|--amount|--from|--to|--chain)
            [[ $# -ge 2 ]] || { echo "$1 needs a value"; exit 64; }
            case $1 in
                --wallet-manager) wm=$2 ;;
                --binary) binary=$2 ;;
                --amount) amount=$2; real_options+=" $1" ;;
                --from) from=$2; real_options+=" $1" ;;
                --to) to=$2; real_options+=" $1" ;;
                --chain) chain=$2; real_options+=" $1" ;;
            esac
            shift 2 ;;
        --keep) keep=1; shift ;;
        --real-testnet) real=1; shift ;;
        --dry-run) dry_run=1; real_options+=" $1"; shift ;;
        --check-guards) check_guards=1; real_options+=" $1"; shift ;;
        --judge-sign-page) [[ $# -ge 2 ]] || { echo "--judge-sign-page PAGE"; exit 64; }; judge_page=$2; shift 2 ;;
        --vault-format) [[ $# -ge 2 ]] || { echo "--vault-format FILE"; exit 64; }; vault_format_file=$2; shift 2 ;;
        --judge-real-results) [[ $# -ge 3 ]] || { echo "--judge-real-results DIR ID"; exit 64; }; judge_results=$2; judge_results_id=$3; shift 3 ;;
        --judge-case-1) [[ $# -ge 3 ]] || { echo "--judge-case-1 SEEN RECORD"; exit 64; }; judge_seen=$2; judge_record=$3; judge=1; shift 3 ;;
        -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        *) echo "unknown option $1 (--help)"; exit 64 ;;
    esac
done

DEV_PEER=de0e2e01
WALLET=e2e-hot
# Made up: not anyone's address, no key behind it.
WALLET_ADDRESS=0x00000000000000000000000000000000000E2e01   # EIP-55, as the vault's checker wants it
RECIPIENT=0x00000000000000000000000000000000000e2E02
AMOUNT=1000000000000000000

say() { printf '%s\n' "$*"; }
die() { say "wallet-e2e: $*"; exit 1; }

# vault_format FILE: the vault format the Wallet Manager under test writes, read as text from its src/vault/format.ts
# (nothing of the checkout runs): FORMAT_VERSION's major and minor, each a number or the name of an
# `export const NAME = N;` in the same file, as `{ major: 1, minor: WATCH_MINOR } as const` has it. Sets VAULT_VERSION
# ("1.11") and CONTACT_FORM, the shape of a contact at that version: chains (chain IDs) from CONTACT_CHAINS_MINOR on
# (1.10), networks before it or when the file has no CONTACT_CHAINS_MINOR. The Wallet Manager adds versions often, so
# the run follows it rather than pinning one. Fail-closed, naming the file: no file, not exactly one FORMAT_VERSION, a
# part that isn't a number or one such constant, a CONTACT_CHAINS_MINOR that isn't one, or a major other than 1 (the
# vault this run writes is format 1's).
VAULT_VERSION=""
CONTACT_FORM=""
format_number() {   # format_number FILE NAME: N from FILE's one `export const NAME = N;`, else nothing
    local values
    values=$(sed -nE "s/^export const $2(: number)? = (0|[1-9][0-9]{0,5})( as const)?;[[:space:]]*(\/\/.*)?$/\2/p" "$1")
    [[ $(grep -c . <<<"$values") == 1 ]] && printf '%s' "$values"
}
format_part() {     # format_part FILE TEXT: TEXT as a number, or the number its constant names, else nothing
    if [[ $2 =~ ^(0|[1-9][0-9]{0,5})$ ]]; then printf '%s' "$2"
    elif [[ $2 =~ ^[A-Z][A-Z0-9_]*$ ]]; then format_number "$1" "$2"
    else return 1
    fi
}
vault_format() {
    local file=$1 lines major minor threshold
    local shape='^export const FORMAT_VERSION = \{ *major: *([A-Za-z0-9_]+), *minor: *([A-Za-z0-9_]+) *\}( as const)?; *$'
    local why="can't read the Wallet Manager's vault format version from $file"
    [[ -f $file ]] || die "$why: no such file"
    lines=$(grep -E '^export const FORMAT_VERSION[^A-Za-z0-9_]' "$file")
    [[ $(grep -c . <<<"$lines") == 1 ]] || die "$why: it doesn't have exactly one \`export const FORMAT_VERSION\`"
    [[ $lines =~ $shape ]] || die "$why: FORMAT_VERSION isn't \`{ major: N, minor: N } as const\`"
    major=$(format_part "$file" "${BASH_REMATCH[1]}") || die "$why: FORMAT_VERSION's major (${BASH_REMATCH[1]}) isn't a number or a constant set to one"
    minor=$(format_part "$file" "${BASH_REMATCH[2]}") || die "$why: FORMAT_VERSION's minor (${BASH_REMATCH[2]}) isn't a number or a constant set to one"
    [[ $major == 1 ]] || die "$why: it says format $major.$minor, and this run writes format 1 vaults"
    CONTACT_FORM=networks
    if grep -qE '^export const CONTACT_CHAINS_MINOR[^A-Za-z0-9_]' "$file"; then
        threshold=$(format_number "$file" CONTACT_CHAINS_MINOR) || die "$why: CONTACT_CHAINS_MINOR isn't \`export const CONTACT_CHAINS_MINOR = N;\`"
        ((minor >= threshold)) && CONTACT_FORM=chains
    fi
    VAULT_VERSION=$major.$minor
}

failures=0
cases=0
report() {   # report NUMBER TITLE pass|fail DETAIL [SHOT]
    say "case $1 $2: $3 ($4)"
    [[ -n ${5:-} ]] && say "  shot: $shots/$5-main-light.png"   # the main window's, as `shot` names it
    cases=$((cases + 1))
    [[ $3 == pass ]] || failures=$((failures + 1))
}
# Judges and reports case 1, or 1b with STRICT set (a warning fails it then):
# report_case_1 NUMBER TITLE SEEN RECORD SHOT [CARD] [STRICT]
# SEEN is the card's states ("waiting → sent → received"), RECORD the Wallet Manager's record as `record` prints it.
# It fails on a rejection (or a decline, or a failure) or a missing answer (no record, no Received or Proposed on the
# card, no result, the checks not run). A check that failed while the record isn't rejected is a warning, as the
# protocol has it (docs/protocol/wallet-request.md): named on a line of its own, and case 1 still passes.
report_case_1() {
    local number=$1 title=$2 seen=$3 rec=$4 shot=$5 card=${6:-} strict=${7:-}
    local state="" checked="" results="" checks="" check warned="" why=""
    read -r state checked results checks <<<"$rec"
    for check in ${checks//,/ }; do [[ $check == *:failed ]] && warned+="${warned:+ }${check%:failed}"; done
    if [[ -z $rec ]]; then why="no answer: the Wallet Manager has no record of the request"
    elif [[ $state == rejected || $state == declined || $state == failed ]]; then why="the Wallet Manager's record is $state"
    elif [[ $seen != "waiting → sent → received" && $seen != "waiting → sent → proposed" ]]; then why="no answer on the card"
    elif [[ $checked != true || -z $checks ]]; then why="the Wallet Manager didn't finish its checks"
    elif [[ ! $results =~ ^[1-9][0-9]*$ ]]; then why="the Wallet Manager sent no result"
    elif [[ -n $strict && -n $warned ]]; then why="warnings where none were expected: $warned"
    fi
    if [[ -z $why ]]; then
        local count=0 name
        for name in $warned; do count=$((count + 1)); done
        report "$number" "$title" pass "$seen; the Wallet Manager's checks: $checks; warnings: $count" "$shot"
        for name in $warned; do say "  warning: $name (failed, in a result that isn't rejected)"; done
    else
        report "$number" "$title" fail "$why; $seen; record: ${rec:-none}${card:+; card: $(tr '\n' ';' <<<"$card")}" "$shot"
    fi
}
# sign_page_refusal PAGE CHAIN FROM TO VALUE: nothing when the signing page (its HTML, in the file PAGE) signs exactly
# that transfer (no call) and shows no warning; else why not, and fails. Read only through the page's stable hooks
# (the Wallet Manager's docs/protocol/sign-page.md): exactly one element with data-sign-warnings, its list empty and no
# element marked data-sign-warning; elements with data-sign-field, each once with a data-value, exactly chain, from, to,
# value and call (a field it doesn't expect, such as a token's or a Safe's, refuses). Tags, order and text don't count.
# Comments and script, style, template and textarea contents are not the page's elements. Nothing is unescaped: the
# values' formats need none, so an escaped one doesn't match.
sign_page_refusal() {
    node -e 'const [file, ...want] = process.argv.slice(1);
        const [chain, from, to, value] = want, expected = { chain, from, to, value, call: "none" };
        let html; try { html = require("fs").readFileSync(file, "utf8") } catch { console.log("the signing page can'"'"'t be read"); process.exit(1) }
        html = html.replace(/<!--[\s\S]*?-->/g, "").replace(/<(script|style|template|textarea)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, "");
        const elements = [];
        for (const [, rest] of html.matchAll(/<[A-Za-z][A-Za-z0-9-]*(\s[^>]*)?>/g)) {
            const attributes = new Map();
            for (const m of (rest ?? "").matchAll(/([^\s"'"'"'>\/=]+)(?:\s*=\s*(?:"([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^\s"'"'"'=<>`]+)))?/g)) {
                const name = m[1].toLowerCase();
                if (!attributes.has(name)) attributes.set(name, m[2] ?? m[3] ?? m[4] ?? "");
            }
            elements.push(attributes);
        }
        const refuse = (why) => { console.log(why); process.exit(1) };
        const lists = elements.filter((a) => a.has("data-sign-warnings"));
        if (lists.length !== 1) refuse(lists.length === 0 ? "the page has no data-sign-warnings element: it isn'"'"'t a page that can sign" : `the page has ${lists.length} data-sign-warnings elements, not one`);
        const warnings = [...new Set([...lists[0].get("data-sign-warnings").split(/\s+/), ...elements.filter((a) => a.has("data-sign-warning")).map((a) => a.get("data-sign-warning") || "(unnamed)")])].filter(Boolean);
        if (warnings.length > 0) refuse(`the page shows warnings: ${warnings.join(" ")}`);
        const fields = new Map();
        for (const a of elements.filter((a) => a.has("data-sign-field"))) {
            const name = a.get("data-sign-field");
            if (!Object.hasOwn(expected, name)) refuse(`the page signs a field this run doesn'"'"'t expect: ${name || "(unnamed)"}`);
            if (fields.has(name)) refuse(`the page names its ${name} twice`);
            if (!a.has("data-value")) refuse(`the page'"'"'s ${name} has no data-value`);
            fields.set(name, a.get("data-value"));
        }
        const wrong = Object.keys(expected).filter((k) => fields.get(k) !== expected[k]);
        if (wrong.length > 0) refuse(`the page doesn'"'"'t sign what was asked: ${wrong.map((k) => `${k} ${fields.has(k) ? fields.get(k) : "missing"}, not ${expected[k]}`).join("; ")}`);' \
        "$@" </dev/null
}
# real_results DIR ID: the results for request ID in DIR (the dev side's inbox folder, where the card took them), in
# sequence order. Prints "STATUSES<TAB>TXHASH<TAB>EXPLORER" (the statuses joined with " → ") and succeeds when they read
# received → proposed → signed → submitted, numbered 1 to 4, the submitted one with a txHash; else prints why, and fails.
REAL_RESULTS="received → proposed → signed → submitted"
real_results() {
    node -e 'const fs = require("fs"), [dir, id, want] = process.argv.slice(1);
        const fail = (why) => { console.log(why); process.exit(1) };
        let names; try { names = fs.readdirSync(dir).filter((f) => f.endsWith(`-wallet-result-${id}.json`)) } catch { fail(`no results folder ${dir}`) }
        const all = [];
        for (const f of names) { try { all.push(JSON.parse(fs.readFileSync(`${dir}/${f}`, "utf8"))) } catch { fail(`the result ${f} can'"'"'t be read`) } }
        all.sort((a, b) => a.sequence - b.sequence);
        const seen = all.map((r) => r.status).join(" → ") || "none";
        if (seen !== want) fail(`the results read ${seen}, not ${want}`);
        if (all.some((r, i) => r.sequence !== i + 1)) fail(`the results are numbered ${all.map((r) => r.sequence).join(", ")}, not 1 to ${all.length}`);
        const last = all[all.length - 1];
        if (!/^0x[0-9a-f]{64}$/.test(last.txHash ?? "")) fail(`the submitted result has no txHash (${last.txHash ?? "none"})`);
        process.stdout.write(`${seen}\t${last.txHash}\t${last.explorerURL ?? ""}\n`)' "$1" "$2" "$REAL_RESULTS" </dev/null
}
if [[ -n $vault_format_file ]]; then
    [[ -z $judge && -z $judge_page && -z $judge_results && -z $real && -z $real_options ]] || { say "wallet-e2e: --vault-format takes nothing else"; exit 64; }
    vault_format "$vault_format_file"
    say "$VAULT_VERSION $CONTACT_FORM"
    exit 0
fi
if [[ -n $judge_results ]]; then
    [[ -z $judge && -z $judge_page && -z $real && -z $real_options ]] || { say "wallet-e2e: --judge-real-results takes nothing else"; exit 64; }
    command -v node >/dev/null || { say "wallet-e2e: node isn't on the PATH"; exit 1; }
    if seen=$(real_results "$judge_results" "$judge_results_id"); then
        say "wallet-e2e: the results read ${seen%%$'\t'*}"
        exit 0
    fi
    say "wallet-e2e: ${seen:-the results could not be judged}"
    exit 1
fi
if [[ -n $judge_page ]]; then
    [[ -z $judge && -z $judge_results ]] && [[ $real_options == "" || $real_options == " --amount" ]] && [[ -z $real ]] || { say "wallet-e2e: --judge-sign-page takes only --amount"; exit 64; }
    command -v node >/dev/null || { say "wallet-e2e: node isn't on the PATH"; exit 1; }
    if why=$(sign_page_refusal "$judge_page" "$TESTNET_CHAIN" "$THROWAWAY" "$THROWAWAY" "$amount"); then
        say "wallet-e2e: the signing page signs a self-transfer of $amount wei on $TESTNET_CHAIN from $THROWAWAY, with no warnings"
        exit 0
    fi
    say "wallet-e2e: refused before the sign POST: ${why:-the page could not be judged}"
    exit 2
fi
if [[ -n $judge ]]; then
    report_case_1 1 "valid testnet transfer from a known wallet" "$judge_seen" "$judge_record" ""
    exit $((failures == 0 ? 0 : 1))
fi

# --real-testnet's refusals, all before any network, scratch folder, Wallet Manager or sandbox. They read the config
# folder's metadata and the keystore's address, never print a value from either file.
testnet_config=$HOME/.config/wallet-manager-testnet
refuse() { say "wallet-e2e --real-testnet: refused: $*"; exit 2; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# private PATH WHAT: yours, not a link, nobody else may read or write it (no group or other bits).
private() {
    local path=$1 what=$2 mode
    [[ ! -L $path ]] || refuse "$what ($path) is a link: it must be the file itself"
    [[ -e $path ]] || refuse "$what ($path) is missing"
    [[ $(stat -f %u "$path") == "$(id -u)" ]] || refuse "$what ($path) isn't yours"
    mode=$(stat -f %Lp "$path")
    (( (8#$mode & 8#077) == 0 )) || refuse "$what ($path) has mode $mode: others may reach it (0600 for a file, 0700 for the folder)"
}
# private_file PATH WHAT MAX_BYTES: as private, a regular file of 1 to MAX_BYTES bytes.
private_file() {
    local size
    private "$1" "$2"
    [[ -f $1 ]] || refuse "$2 ($1) isn't a regular file"
    size=$(stat -f %z "$1")
    ((size > 0 && size <= $3)) || refuse "$2 ($1) is $size bytes: expected 1 to $3"
}
real_testnet_guards() {
    [[ $chain == "$TESTNET_CHAIN" ]] || refuse "chain $chain: only GenLayer testnet, $TESTNET_CHAIN"
    [[ $(lower "$from") == "$(lower "$THROWAWAY")" ]] || refuse "from $from: only the throwaway testnet wallet $THROWAWAY"
    [[ $(lower "$to") == "$(lower "$from")" ]] || refuse "to $to: only a self-transfer, to the throwaway wallet itself"
    { [[ $amount =~ ^[1-9][0-9]{0,3}$ ]] && ((amount <= MAX_WEI)); } || refuse "amount $amount: 1 to $MAX_WEI wei"
    private "$testnet_config" "the throwaway wallet's folder"
    [[ -d $testnet_config ]] || refuse "$testnet_config isn't a folder"
    private_file "$testnet_config/keystore.json" "the throwaway keystore" 65536
    private_file "$testnet_config/passphrase" "the throwaway passphrase" 1024
    [[ -n $(tr -d '\r\n' <"$testnet_config/passphrase") ]] || refuse "the throwaway passphrase file holds no passphrase"
    # A v3 keystore naming exactly one address, the throwaway wallet's (lower-case hex, no 0x, as the format has it).
    local keystore=$testnet_config/keystore.json addresses
    grep -Eq '"version"[[:space:]]*:[[:space:]]*3[[:space:]]*[,}]' "$keystore" || refuse "the throwaway keystore isn't a version 3 keystore"
    addresses=$(grep -Eo '"address"[[:space:]]*:[[:space:]]*"[^"]*"' "$keystore" | sed -E 's/.*"([^"]*)"$/\1/')
    [[ $(printf '%s\n' "$addresses" | grep -c .) == 1 ]] || refuse "the throwaway keystore doesn't name exactly one address"
    [[ $(lower "$addresses") == "$(lower "${THROWAWAY#0x}")" ]] || refuse "the throwaway keystore isn't the throwaway wallet's ($THROWAWAY)"
}
# testnet_network: the Wallet Manager's own testnet, as its stable command prints it (docs/protocol/sign-page.md, "The
# networks"): `node src/networks.ts --json`, one JSON line and exit 0. Fail-closed: a non-zero exit, anything on stderr,
# anything on stdout but that one line, or a testnet without its chainId, rpcUrl, explorerUrl and genesisHash refuses.
# It must be chain 4221 at GenLayer's testnet RPC, with an https explorer and a pinned genesis hash. Sets
# TESTNET_EXPLORER (the explorer the run prints) and TESTNET_GENESIS (block 0's hash, which the RPC must answer before
# the payment). Reads the checkout only: no network.
TESTNET_RPC=https://rpc.testnet-chain.genlayer.com
TESTNET_EXPLORER=""
TESTNET_GENESIS=""
testnet_network() {
    local checkout out err status fields chain_id rpc_url explorer genesis
    command -v node >/dev/null || refuse "node isn't on the PATH, so the Wallet Manager's testnet can't be read"
    { checkout=$(cd "$wm" 2>/dev/null && pwd -P) && [[ -f $checkout/src/networks.ts ]]; } || refuse "no src/networks.ts in a Wallet Manager checkout at $wm"
    err=$(mktemp "${TMPDIR:-/tmp}/wallet-e2e-networks.XXXXXX") || refuse "can't make a file for \`node src/networks.ts --json\`'s errors"
    # Its exit status after an x, which also keeps the output's trailing newlines from $( ) (the one-line check sees them).
    out=$(cd "$checkout" && node src/networks.ts --json 2>"$err" </dev/null; printf 'x%s' "$?")
    status=${out##*x}
    out=${out%x*}
    [[ -s $err ]] && status=stderr
    rm -f "$err"
    [[ $status == 0 ]] || refuse "the Wallet Manager's \`node src/networks.ts --json\` failed (${status/stderr/it wrote to stderr})"
    fields=$(node -e 'const out = process.argv[1];
        let all; try { if (!/^[^\n]+\n?$/.test(out)) throw 0; all = JSON.parse(out) } catch { process.exit(3) }
        const t = all?.testnet ?? {}, text = (v) => (typeof v === "string" && v !== "" && !/\s/.test(v) ? v : "-");
        process.stdout.write([typeof t.chainId === "number" ? String(t.chainId) : "-", text(t.rpcUrl), text(t.explorerUrl),
            typeof t.genesisHash === "string" && /^0x[0-9a-f]{64}$/.test(t.genesisHash) ? t.genesisHash : "-"].join(" "))' "$out" 2>/dev/null </dev/null) \
        || refuse "the Wallet Manager's \`node src/networks.ts --json\` didn't print one JSON line, and only that"
    read -r chain_id rpc_url explorer genesis <<<"$fields"
    [[ $chain_id == "$TESTNET_CHAIN" && $rpc_url == "$TESTNET_RPC" ]] \
        || refuse "the Wallet Manager's testnet is chain ${chain_id:--} at ${rpc_url:--}, not $TESTNET_CHAIN at $TESTNET_RPC"
    [[ $explorer =~ ^https://[A-Za-z0-9.-]+$ ]] || refuse "the Wallet Manager's testnet has no https explorer (${explorer:--})"
    [[ $genesis != - ]] || refuse "the Wallet Manager's testnet has no genesisHash (0x and 64 lower-case hex digits)"
    TESTNET_EXPLORER=$explorer
    TESTNET_GENESIS=$genesis
}
if [[ -z $real ]]; then
    [[ -z $real_options ]] || { say "wallet-e2e:$real_options only with --real-testnet"; exit 64; }
else
    [[ -z $dry_run || -z $check_guards ]] || { say "wallet-e2e: --dry-run or --check-guards, not both"; exit 64; }
    real_testnet_guards
    testnet_network
    if [[ -n $check_guards ]]; then
        say "wallet-e2e --real-testnet: guards pass: chain $chain, a self-transfer of $amount wei from the throwaway wallet $THROWAWAY, its keystore and passphrase private in $testnet_config; the Wallet Manager's testnet: $TESTNET_CHAIN at $TESTNET_RPC, explorer $TESTNET_EXPLORER, genesis $TESTNET_GENESIS"
        exit 0
    fi
fi

command -v node >/dev/null || die "node isn't on the PATH"
wm=$(cd "$wm" 2>/dev/null && pwd -P) || die "no Wallet Manager checkout at $wm (--wallet-manager DIR)"
[[ -f $wm/src/server/main.ts && -f $wm/src/dev/fake-chain-cli.ts ]] || die "$wm isn't the Wallet Manager's checkout (no src/server/main.ts)"
# The vault format it writes: the scratch vault says that version (vault_format; it stops the run if it can't tell).
vault_format "$wm/src/vault/format.ts"
# Its dependencies as its lockfile has them: npm writes node_modules/.package-lock.json at each install, so one missing or
# older than package-lock.json means the lockfile changed since (a dependency added, e.g.). --ignore-scripts: no
# package's install scripts run; npm ci writes only node_modules. Its output goes to a log, named if it fails.
installed=$wm/node_modules/.package-lock.json
if [[ ! -f $installed || $wm/package-lock.json -nt $installed ]]; then
    command -v npm >/dev/null || die "$wm's node_modules is out of date and npm isn't on the PATH"
    say "wallet-e2e: $wm's node_modules is missing or older than its package-lock.json: running \`npm ci --ignore-scripts\` there"
    npm_log=$(mktemp "${TMPDIR:-/tmp}/wallet-e2e-npm-ci.XXXXXX") || die "can't make a log file for npm ci"
    (cd "$wm" && npm ci --ignore-scripts) >"$npm_log" 2>&1 </dev/null
    npm_status=$?
    ((npm_status == 0)) || die "\`npm ci --ignore-scripts\` failed in $wm (exit $npm_status); its output: $npm_log"
    rm -f "$npm_log"
fi

# --real-testnet's look at the chain before anything starts: GenLayer's testnet RPC (the Wallet Manager's, checked by
# testnet_network) says it's 4221, and nothing from the wallet is pending. Nothing is sent but these reads.
# jget JSON PATH: the value at a dotted PATH ("" for the whole), a string as is, else as JSON; "" when absent.
jget() {
    node -e 'let v = JSON.parse(process.argv[1]); for (const k of process.argv[2] ? process.argv[2].split(".") : []) v = v == null ? v : v[k];
        process.stdout.write(v == null ? "" : typeof v === "string" ? v : JSON.stringify(v))' "$1" "$2"
}
# rpc METHOD PARAMS: the testnet RPC's result as JSON, or fails saying its error.
rpc() {
    local reply
    reply=$(curl -sS --max-time 30 -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" "$TESTNET_RPC") || return 1
    node -e 'let r; try { r = JSON.parse(process.argv[1]) } catch { r = {} }
        if (r.error !== undefined || !("result" in r)) { process.stderr.write(`the RPC answered ${process.argv[2]} with ${JSON.stringify(r.error ?? r).slice(0, 300)}\n`); process.exit(1) }
        process.stdout.write(JSON.stringify(r.result))' "$reply" "$1"
}
decimal() { node -e 'process.stdout.write(BigInt(process.argv[1]).toString())' "$1"; }
if [[ -n $real ]]; then
    command -v curl >/dev/null || die "curl isn't on the PATH"
    answer=$(rpc eth_chainId '[]') || die "the testnet RPC ($TESTNET_RPC) didn't answer eth_chainId"
    [[ $(jget "$answer" "") == "$(printf '0x%x' "$TESTNET_CHAIN")" ]] || refuse "$TESTNET_RPC says it's chain $(jget "$answer" ""), not $TESTNET_CHAIN"
    # Block 0 is the one the Wallet Manager pins (its --json genesisHash): the same chain, not another one on 4221.
    answer=$(rpc eth_getBlockByNumber '["0x0",false]') || die "the testnet RPC didn't answer eth_getBlockByNumber for block 0"
    [[ $(jget "$answer" hash) == "$TESTNET_GENESIS" ]] || refuse "$TESTNET_RPC's block 0 is $(jget "$answer" hash), not the Wallet Manager's pinned genesis $TESTNET_GENESIS"
    answer=$(rpc eth_getBalance "[\"$THROWAWAY\",\"latest\"]") || die "the testnet RPC didn't answer eth_getBalance"
    balance=$(decimal "$(jget "$answer" "")")
    answer=$(rpc eth_getTransactionCount "[\"$THROWAWAY\",\"latest\"]") || die "the testnet RPC didn't answer eth_getTransactionCount"
    nonce_before=$(decimal "$(jget "$answer" "")")
    answer=$(rpc eth_getTransactionCount "[\"$THROWAWAY\",\"pending\"]") || die "the testnet RPC didn't answer eth_getTransactionCount"
    [[ $(decimal "$(jget "$answer" "")") == "$nonce_before" ]] || refuse "a transaction from the throwaway wallet is still pending: wait for it to be mined"
    say "testnet RPC $TESTNET_RPC: chain $TESTNET_CHAIN, block 0 the pinned genesis $TESTNET_GENESIS; the throwaway wallet holds $balance wei, nonce $nonce_before"
fi

# The run's scratch folder, resolved: the Wallet Manager refuses an inbox reached through a link (/tmp is one).
run=$(mktemp -d "${TMPDIR:-/tmp}/wallet-e2e.XXXXXX") || die "can't make a scratch folder"
run=$(cd "$run" && pwd -P)
loop=$run/loop
vault=$run/vault
shots=$repo/.build/sandbox-shots/e2e
sandbox_dir=$repo/.build/sandbox-e2e
mkdir -p "$loop/dev/bin" "$loop/vault/bin" "$loop/dev/inbox" "$loop/vault/inbox" "$shots" "$sandbox_dir"

dev_root=$loop
pids=()          # what this run started, stopped by pid at the end
wm_pid=""
sandbox_started=""
secrets=()       # --real-testnet: the copies of the throwaway keystore and passphrase, removed first, always
cleanup() {
    local pid
    if (( ${#secrets[@]} > 0 )); then
        local file
        rm -f "${secrets[@]}" </dev/null
        for file in "${secrets[@]}"; do [[ ! -e $file ]] || say "couldn't remove $file: remove it now"; done
        say "removed the scratch copies of the throwaway keystore and passphrase"
    fi
    [[ -n $sandbox_started ]] && bash scripts/sandbox-app.sh --dir "$sandbox_dir" quit >/dev/null 2>&1
    # Any `passage listen` still marked in the loop (the sandbox's, if it didn't stop its own): its pid is the marker's
    # name, and its command line doesn't name the run's folder, so pgrep below wouldn't see it.
    local marker
    for marker in "$loop"/dev/listening/* "$loop"/vault/listening/*; do
        [[ -f $marker && $(basename "$marker") =~ ^[0-9]+$ ]] && pids+=("$(basename "$marker")")
    done
    for pid in ${pids[@]+"${pids[@]}"}; do kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null; done
    for pid in ${pids[@]+"${pids[@]}"}; do
        for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    done
    local left
    # Anything still running with the run's folder in its command line (either spelling of it).
    left=$( { pgrep -f "$run"; pgrep -f "$dev_root/"; for pid in ${pids[@]+"${pids[@]}"}; do kill -0 "$pid" 2>/dev/null && echo "$pid"; done; } 2>/dev/null | sort -u | tr '\n' ' ')
    if [[ -n $left ]]; then say "left running: pids $left(started with $run)"; else say "stopped everything it started: nothing of the run is left running"; fi
    if [[ -n $keep ]]; then say "kept the run's folder: $run (the sandbox's log: $sandbox_dir/app.log)"; else rm -rf "$run" "$sandbox_dir" </dev/null; fi
}
on_exit cleanup

# One wrapper per side. The vault side is spelled resolved (the Wallet Manager compares real paths); the dev side as
# Foundation spells it (/tmp, /var: VibeSwitcher's PassageLink reads paths under its standardized inbox folder).
foundation_spelling() { local p=$1; [[ $p == /private/tmp/* || $p == /private/var/* ]] && p=${p#/private}; printf '%s' "$p"; }
dev_root=$(foundation_spelling "$loop")
for side in dev vault; do
    root=$loop
    [[ $side == dev ]] && root=$dev_root
    printf '#!/bin/bash\nLOOP_PASSAGE_ROOT=%q LOOP_PASSAGE_SIDE=%s exec %q "$@"\n' "$root" "$side" "$repo/scripts/e2e/loop-passage" >"$loop/$side/bin/passage"
    chmod 755 "$loop/$side/bin/passage"
done

write() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" >"$1"; }
REAL_WORKSPACE=testnet
REAL_WALLET=throwaway
if [[ -n $real ]]; then
    # The real vault: one workspace with the throwaway hot wallet and a 0600 copy of its keystore; the passphrase's
    # 0600 copy beside the vault, read by the sign POST on stdin. Both go first when the run ends (cleanup).
    keystore_copy=$vault/workspaces/$REAL_WORKSPACE/hot/$REAL_WALLET.keystore.json
    passphrase_copy=$run/passphrase
    write "$vault/vault.json" "{ \"format\": \"wallet-manager-vault\", \"version\": \"$VAULT_VERSION\" }"
    write "$vault/workspaces/$REAL_WORKSPACE/workspace.json" "{ \"name\": \"$REAL_WORKSPACE\", \"label\": \"Throwaway testnet (end-to-end)\" }"
    write "$vault/workspaces/$REAL_WORKSPACE/hot/$REAL_WALLET.json" "{ \"address\": \"$THROWAWAY\", \"label\": \"Throwaway testnet hot wallet\", \"network\": \"testnet\", \"chainIds\": [$TESTNET_CHAIN] }"
    write "$vault/requests/config.json" "{\"vibeswitcherPeer\":\"$DEV_PEER\"}"
    secrets=("$keystore_copy" "$passphrase_copy")
    (umask 077 && cp "$testnet_config/keystore.json" "$keystore_copy" && cp "$testnet_config/passphrase" "$passphrase_copy") </dev/null \
        || die "couldn't copy the throwaway keystore and passphrase into the scratch vault"
    chmod 600 "$keystore_copy" "$passphrase_copy" || die "couldn't make the scratch copies 0600"
    [[ $(stat -f %Lp "$keystore_copy") == 600 && $(stat -f %Lp "$passphrase_copy") == 600 ]] || die "the scratch copies aren't 0600"
    (cd "$wm" && node src/cli/check-vault.ts "$vault") >"$run/check-vault.log" 2>&1 || { cat "$run/check-vault.log"; die "the Wallet Manager's checker refused the throwaway vault"; }
else
# The synthetic vault: one made-up workspace with one testnet hot wallet, no keys.
write "$vault/vault.json" "{ \"format\": \"wallet-manager-vault\", \"version\": \"$VAULT_VERSION\" }"
write "$vault/workspaces/e2e/workspace.json" '{ "name": "e2e", "label": "End-to-end (made up)" }'
write "$vault/workspaces/e2e/hot/$WALLET.json" "{ \"address\": \"$WALLET_ADDRESS\", \"label\": \"Made-up testnet hot wallet\", \"network\": \"testnet\", \"chainIds\": [4221] }"
write "$vault/requests/config.json" "{\"vibeswitcherPeer\":\"$DEV_PEER\"}"
(cd "$wm" && node src/cli/check-vault.ts "$vault") >"$run/check-vault.log" 2>&1 || { cat "$run/check-vault.log"; die "the Wallet Manager's checker refused the synthetic vault"; }
# Its fake chains: the wallet holds 10 GEN on testnet; mainnet only answers its chain id.
write "$run/testnet.json" "{ \"chainId\": 4221, \"balances\": { \"$WALLET_ADDRESS\": \"10000000000000000000\" } }"
write "$run/mainnet.json" '{ "chainId": 42424242 }'
fi

# Waits for a ready file ($1) naming pid $2, then prints its url.
await_ready() {
    local file=$1 pid=$2 what=$3
    for _ in $(seq 1 600); do
        if [[ -s $file ]] && node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.exit(r.pid === Number(process.argv[2]) ? 0 : 1)' "$file" "$pid" 2>/dev/null; then
            node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).url)' "$file"
            return 0
        fi
        kill -0 "$pid" 2>/dev/null || { say "$what quit before it was ready:" >&2; tail -20 "$run/$what.log" >&2; return 1; }
        sleep 0.1
    done
    say "$what wasn't ready in 60 s" >&2
    return 1
}

rpc_args=()      # none for --real-testnet: the Wallet Manager uses GenLayer's testnet RPC throughout
if [[ -z $real ]]; then
# The Wallet Manager's harness lines (its docs/running.md, "Local end-to-end run"): node itself, so $! is its pid.
(cd "$wm" && exec node src/dev/fake-chain-cli.ts --port 0 --state "$run/testnet.json" --ready-file "$run/testnet-ready.json") >"$run/testnet.log" 2>&1 &
testnet_pid=$!; pids+=("$testnet_pid")
(cd "$wm" && exec node src/dev/fake-chain-cli.ts --port 0 --state "$run/mainnet.json" --ready-file "$run/mainnet-ready.json") >"$run/mainnet.log" 2>&1 &
mainnet_pid=$!; pids+=("$mainnet_pid")
testnet_url=$(await_ready "$run/testnet-ready.json" "$testnet_pid" testnet) || die "the testnet fake chain didn't start"
mainnet_url=$(await_ready "$run/mainnet-ready.json" "$mainnet_pid" mainnet) || die "the mainnet fake chain didn't start"
rpc_args=(--rpc "testnet=$testnet_url" --rpc "mainnet=$mainnet_url")
fi

# The vault Mac's `passage listen`, as a person leaves it running there.
"$loop/vault/bin/passage" listen >"$run/vault-listen.log" 2>&1 &
pids+=("$!")

start_wallet_manager() {
    (cd "$wm" && PATH="$loop/vault/bin:$PATH" exec node src/server/main.ts "$vault" --port 0 --inbox "$loop/vault/inbox" --peer "$DEV_PEER" \
        ${rpc_args[@]+"${rpc_args[@]}"} --ready-file "$run/app-ready.json") >>"$run/wallet-manager.log" 2>&1 &
    wm_pid=$!; pids+=("$wm_pid")
    wm_url=$(await_ready "$run/app-ready.json" "$wm_pid" wallet-manager) || die "the Wallet Manager didn't start (see above)"
}
stop_wallet_manager() {
    kill "$wm_pid" 2>/dev/null
    for _ in $(seq 1 100); do kill -0 "$wm_pid" 2>/dev/null || break; sleep 0.1; done
    ! kill -0 "$wm_pid" 2>/dev/null
}
start_wallet_manager
grep -q "Test mode: overridden" "$run/wallet-manager.log" || die "the Wallet Manager didn't say it's in test mode"
if [[ -n $real ]]; then say "Wallet Manager (pid $wm_pid) at $wm_url on the throwaway vault, GenLayer's testnet RPC"
else say "Wallet Manager (pid $wm_pid) at $wm_url on the synthetic vault, fake chains at $testnet_url and $mainnet_url"; fi
# Opening /requests reads the inbox and sends what's waiting now (else it looks every 15 s).
wm_poll() { curl -s --max-time 30 -o /dev/null "${wm_url}requests"; }

# The sandbox, its wallet requests through the loop's dev side.
sb() { bash scripts/sandbox-app.sh --dir "$sandbox_dir" --shots "$shots" "$@"; }
sandbox_started=1
sb --minutes 30 ${binary:+--binary "$binary"} --passage "$loop/dev/bin/passage" --passage-inbox "$dev_root/dev/inbox" run || die "the sandbox didn't start"
# Each case in a fake session of its own, so its chat holds just its card.
session() { sb new "$1" >/dev/null && sb chat "$1" >/dev/null || die "couldn't start and show the fake session $1"; }

# The newest card's field ($1: state, id, not-picked-up…), from `wallet-card`.
card() { sb wallet-card | sed -n "s/^$1 //p" | head -1; }
# Waits for the newest card's state to be $1, or one of them ("Received|Proposed"), up to 60 s (or $2 looks, 0.2 s
# apart); prints the card.
await_card() {
    local text state
    for _ in $(seq 1 "${2:-300}"); do
        text=$(sb wallet-card)
        state=$(sed -n 's/^state //p' <<<"$text")
        [[ -n $state && "|$1|" == *"|$state|"* ]] && { printf '%s\n' "$text"; return 0; }
        sleep 0.2
    done
    printf '%s\n' "$text"
    return 1
}
ask() { sb wallet-ask --workspace e2e --from "$WALLET" --chain 4221 --to "$RECIPIENT" --amount "$AMOUNT" "$@" >/dev/null && await_card "Waiting for you" >/dev/null; }
send() { sb wallet-click "$1" >/dev/null; }
# The Wallet Manager's record of a request: "<state> <checked> <results> <checks>", or nothing.
record() {
    local file=$vault/requests/$1/state.json
    [[ -f $file ]] || return 0
    node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        process.stdout.write(`${r.state} ${r.checked} ${r.results.length} ${r.checks.map((c) => `${c.name}:${c.ok ? "ok" : "failed"}`).join(",")}`)' "$file"
}
results_in_dev_inbox() { ls "$loop/dev/inbox/0a1b2c3d" 2>/dev/null | grep -c -- "-wallet-result-$1.json$"; }
requests_in_vault_inbox() { ls "$loop/vault/inbox/$DEV_PEER" 2>/dev/null | grep -c -- "-wallet-request-$1.json$"; }

shot() { sb scroll bottom >/dev/null; sb shot "$1" >/dev/null || say "  (couldn't take shot $1)"; }

# --real-testnet: one real payment. The sandbox's fake agent asks for the self-transfer and Send is clicked; the
# Wallet Manager checks it against GenLayer's testnet; then the /sign page is driven over HTTP exactly as its
# docs/running.md, "Signing over HTTP (headless)", has it. Opening the page has no side effects (the card stays
# Received); the POST brings proposed → signed → submitted, the card ends Signed (the result `submitted`) and the RPC's
# receipt says status 1.
real_payment() {
    local id states final rec url sign_dir answer
    session "Testnet agent"
    sb wallet-ask --workspace "$REAL_WORKSPACE" --from "$REAL_WALLET" --chain "$chain" --to "$to" --amount "$amount" >/dev/null \
        && await_card "Waiting for you" >/dev/null || { real_fail "the fake agent's request didn't show as a card"; return; }
    send send
    id=$(card id)
    states="waiting → $(card state | tr '[:upper:]' '[:lower:]')"
    [[ $id =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { real_fail "the card has no request id ($id)"; return; }

    # 0. A pending request, its checks done, the card Received (`proposed` comes only with the POST); GET /requests
    # reads the inbox now; its card links to /sign/<id>.
    wm_poll
    final=$(await_card "Received|Proposed|Rejected") || { real_fail "no answer from the Wallet Manager on the card: $(tr '\n' ';' <<<"$final")"; return; }
    [[ $(sed -n 's/^state //p' <<<"$final") == Received ]] \
        || { real_fail "the card shows $(sed -n 's/^state //p' <<<"$final") before the sign POST, not Received: $(tr '\n' ';' <<<"$final")"; return; }
    states+=" → received"
    rec=$(record "$id")
    [[ $rec == "pending true "* ]] || { real_fail "the Wallet Manager's record isn't pending with its checks done: ${rec:-none}; card: $(tr '\n' ';' <<<"$final")"; return; }
    sign_dir=$run/sign
    mkdir -p "$sign_dir"
    url=${wm_url%/}
    curl -fsS --max-time 30 -o "$sign_dir/requests.html" "$url/requests" && grep -qF "href=\"/sign/$id\"" "$sign_dir/requests.html" \
        || { real_fail "the request's card on /requests doesn't link to /sign/$id (record: $rec)"; return; }

    # 1. The page, read as the doc's block reads it (from its scratch folder, where it writes page.html).
    local ID=$id URL=$url CSRF TOKEN HASH
    local ACKS=()
    (cd "$sign_dir" && curl -fsS -o page.html -H 'Sec-Fetch-Site: same-origin' "$URL/sign/$ID") || { real_fail "GET /sign/$ID didn't answer 200"; return; }
    CSRF=$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' "$sign_dir/page.html")
    TOKEN=$(sed -n 's/.*name="token" value="\([^"]*\)".*/\1/p' "$sign_dir/page.html")
    HASH=$(sed -n 's/.*name="hash" value="\([^"]*\)".*/\1/p' "$sign_dir/page.html")
    [[ $CSRF =~ ^[A-Za-z0-9_-]+$ && $TOKEN =~ ^[A-Za-z0-9_-]{43}$ && $HASH =~ ^0x[0-9a-f]{64}$ ]] \
        || { real_fail "the signing page has no csrf, token and hash as the doc describes them"; return; }
    # What the page says will be signed, from its machine-readable fields (taken from the built, verified transaction,
    # not the request): chain 4221, from and to the throwaway wallet, the amount, no call; and no warning (a stale or
    # blind-call one would ask for an acknowledgement this run never sends). The run stops before the POST otherwise.
    local why
    why=$(sign_page_refusal "$sign_dir/page.html" "$TESTNET_CHAIN" "$THROWAWAY" "$THROWAWAY" "$amount") \
        || { real_fail "refused before the sign POST: ${why:-the signing page could not be judged}"; return; }
    # Opening the page has no side effects: the card still Received, the Wallet Manager's record as it was.
    local seen_now rec_now
    seen_now=$(card state)
    rec_now=$(record "$id")
    [[ $seen_now == Received && $rec_now == "$rec" ]] \
        || { real_fail "opening the signing page changed the request: card $seen_now (was Received), record ${rec_now:-none} (was $rec)"; return; }
    if [[ -n $dry_run ]]; then
        shot e2e-real-testnet-dry-run
        report real "testnet payment, dry run (stopped before the sign POST)" pass \
            "$states; the card still Received after the page; the page shows a self-transfer of $amount wei on $TESTNET_CHAIN from $THROWAWAY, signing hash $HASH; nothing signed or sent" e2e-real-testnet-dry-run
        return
    fi

    # 2. The confirmation: the doc's POST, the passphrase on stdin from its 0600 scratch copy. Once: never retried.
    local PASSPHRASE_FILE=$passphrase_copy posted
    posted=$(cd "$sign_dir" && tr -d '\r\n' < "$PASSPHRASE_FILE" | curl -sS -o reply.html -w '%{http_code} %{redirect_url}\n' \
      -H "Origin: $URL" \
      -H 'Sec-Fetch-Site: same-origin' \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "csrf=$CSRF" \
      --data-urlencode "token=$TOKEN" \
      --data-urlencode "hash=$HASH" \
      --data-urlencode "passphrase@-" \
      ${ACKS[@]+"${ACKS[@]}"} \
      "$URL/sign/$ID")
    if [[ $posted != "303 $URL/requests#req-$ID" ]]; then
        local why
        why=$(sed -n 's/.*<p class="error"[^>]*>\(.*\)<\/p>.*/\1/p' "$sign_dir/reply.html" | head -1)
        [[ -n $why ]] || why=$(head -c 300 "$sign_dir/reply.html" | tr '\n' ' ')
        real_fail "the sign POST answered ${posted:-nothing}, not 303 to /requests#req-$ID: $why (not retried)"; return
    fi
    states+=" → (POST)"

    # 4. Until submitted: the signing pass looks for the receipt every 15 s; the result comes back to the card.
    final=$(await_card "Signed|Failed" 3000) || { real_fail "no submitted result on the card in 10 minutes: $states; $(tr '\n' ';' <<<"$final")"; return; }
    shot e2e-real-testnet
    local tx card_hash card_url result result_hash signed_hash
    tx=$(sed -n 's/^tx //p' <<<"$final")
    card_hash=${tx%% *}; card_url=""; [[ $tx == *" "* ]] && card_url=${tx#* }
    [[ $(sed -n 's/^state //p' <<<"$final") == Signed && $card_hash =~ ^0x[0-9a-f]{64}$ ]] \
        || { real_fail "the card ended $(sed -n 's/^state //p' <<<"$final"), not Signed with a transaction: $(tr '\n' ';' <<<"$final")"; return; }
    # The results the card took, in the dev side's inbox: received → proposed → signed → submitted (the card may move
    # through the middle ones faster than it's looked at), `submitted` with that txHash; the vault's signed.json agrees.
    result=$(real_results "$loop/dev/inbox/0a1b2c3d" "$id") || { real_fail "$states; $result; card: $(tr '\n' ';' <<<"$final")"; return; }
    states+=" → ${REAL_RESULTS#received → }"
    result_hash=$(cut -f2 <<<"$result")
    signed_hash=$(jget "$(cat "$vault/requests/$id/signed.json" 2>/dev/null || echo '{}')" txHash)
    [[ $result_hash == "$card_hash" && $signed_hash == "$card_hash" ]] \
        || { real_fail "the transaction differs: card $card_hash, submitted result $result, vault signed.json ${signed_hash:-none}"; return; }

    # The chain's own word: the receipt, status 1, for a self-transfer of the amount from the throwaway wallet on 4221.
    local receipt="" transaction status block explorer=$TESTNET_EXPLORER/tx/$card_hash
    for _ in $(seq 1 30); do
        receipt=$(rpc eth_getTransactionReceipt "[\"$card_hash\"]") && [[ -n $(jget "$receipt" "") ]] && break
        sleep 2
    done
    [[ -n $receipt && -n $(jget "$receipt" "") ]] || { real_fail "the RPC has no receipt for $card_hash; explorer: $explorer"; return; }
    transaction=$(rpc eth_getTransactionByHash "[\"$card_hash\"]") || { real_fail "the RPC didn't answer eth_getTransactionByHash for $card_hash"; return; }
    status=$(jget "$receipt" status)
    block=$(decimal "$(jget "$receipt" blockNumber)")
    answer=$(rpc eth_getTransactionCount "[\"$THROWAWAY\",\"latest\"]") && nonce_after=$(decimal "$(jget "$answer" "")") || nonce_after="?"
    say "txHash: $card_hash"
    say "explorer: $explorer"
    say "receipt: status $status, block $block, gas used $(decimal "$(jget "$receipt" gasUsed)"); the throwaway wallet's nonce $nonce_before → $nonce_after"
    if [[ $status == 0x1 && $(lower "$(jget "$receipt" from)") == "$(lower "$THROWAWAY")" && $(lower "$(jget "$receipt" to)") == "$(lower "$THROWAWAY")" \
          && $(decimal "$(jget "$transaction" value)") == "$amount" && $(jget "$transaction" chainId) == "$(printf '0x%x' "$TESTNET_CHAIN")" \
          && $card_url == "$explorer" ]]; then
        report real "testnet payment, $amount wei from the throwaway wallet to itself" pass \
            "$states; result submitted, txHash $card_hash; eth_getTransactionReceipt status 1 in block $block" e2e-real-testnet
    else
        real_fail "$states; receipt status $status, from $(jget "$receipt" from) to $(jget "$receipt" to), value $(jget "$transaction" value), chain $(jget "$transaction" chainId); card's link ${card_url:-none}, expected $explorer"
    fi
}
real_fail() { report real "testnet payment" fail "$1"; }
if [[ -n $real ]]; then
    real_payment
    if ((failures == 0)); then say "wallet-e2e --real-testnet: passed"; else say "wallet-e2e --real-testnet: failed (logs: --keep keeps $run, without the keystore or passphrase)"; fi
    exit $((failures == 0 ? 0 : 1))
fi

# 1. A valid testnet transfer: waiting → sent → received. Its answer is held back until the card has shown Sent.
# Its recipient isn't in the vault: a Wallet Manager with an address book warns recipient-known, without rejecting.
case_1() {   # case_1 NUMBER TITLE SHOT [STRICT]
    local seen id final rec
    touch "$loop/vault/hold"
    session "Case $1 agent"
    ask; seen="waiting"
    send send
    [[ $(card state) == Sent ]] && seen+=" → sent"
    id=$(card id)
    wm_poll
    rm -f "$loop/vault/hold"
    wm_poll
    final=$(await_card "Received|Proposed") && seen+=" → $(sed -n 's/^state //p' <<<"$final" | tr '[:upper:]' '[:lower:]')"
    rec=$(record "$id")
    shot "$3"
    report_case_1 "$1" "$2" "$seen" "$rec" "$3" "$final" "${4:-}"
}
case_1 1 "valid testnet transfer from a known wallet" e2e-1-valid

# 1b. Case 1's recipient in the vault's address book, as the Wallet Manager's docs/vault-format.md describes it: a
# contacts/<id>.json in the shape its vault format has (vault_format: chains, chain IDs, from 1.10; networks before).
# The vault already says that version (the address book is 1.2's), so nothing lowers what the running Wallet Manager
# raised it to (its logs/ is 1.5's). The checker must take the vault; then no warnings.
contacts_doc=$wm/docs/vault-format.md
if [[ -f $contacts_doc ]] && grep -q '^## `contacts/' "$contacts_doc"; then
    if ((${VAULT_VERSION#*.} < 2)); then
        report 1b "recipient in the address book" fail "$contacts_doc describes contacts/, but the Wallet Manager writes format $VAULT_VERSION, older than the address book's 1.2"
    else
        if [[ $CONTACT_FORM == chains ]]; then contact_chains="\"chains\": [$TESTNET_CHAIN]"; else contact_chains='"networks": ["testnet"]'; fi
        write "$vault/contacts/e2e-recipient.json" "{ \"address\": \"$RECIPIENT\", \"label\": \"Made-up end-to-end recipient\", $contact_chains, \"workspaces\": [\"e2e\"] }"
        if (cd "$wm" && node src/cli/check-vault.ts "$vault") >"$run/check-vault-contacts.log" 2>&1; then
            case_1 1b "recipient in the address book (vault $VAULT_VERSION, contacts/e2e-recipient.json with $CONTACT_FORM)" e2e-1b-recipient-known strict
        else
            report 1b "recipient in the address book" fail "the Wallet Manager's checker refused the vault with the contact: $(tr '\n' ';' <"$run/check-vault-contacts.log")"
        fi
    fi
else
    say "case 1b recipient in the address book: skipped (the Wallet Manager has no address book yet: its docs/vault-format.md doesn't describe contacts/)"
fi

# 2. An unknown wallet: rejected, naming the wallet check.
session "Case 2 agent"
ask --from no-such-wallet
send send
id=$(card id)
wm_poll
final=$(await_card Rejected); ok=$?
shot e2e-2-unknown-wallet
failed=$(sed -n 's/^check \([^ ]*\) failed \(.*\)/\1: \2/p' <<<"$final" | paste -sd ';' -)
if ((ok == 0)) && grep -q '^check wallet failed' <<<"$final"; then
    report 2 "request for an unknown wallet" pass "rejected; failed check: $failed" e2e-2-unknown-wallet
else
    report 2 "request for an unknown wallet" fail "card: $(tr '\n' ';' <<<"$final")" e2e-2-unknown-wallet
fi

# 3. The wrong chain: the testnet wallet asked for mainnet (42424242).
session "Case 3 agent"
ask --chain 42424242
send send
wm_poll
final=$(await_card Rejected); ok=$?
shot e2e-3-wrong-chain
failed=$(sed -n 's/^check \([^ ]*\) failed \(.*\)/\1: \2/p' <<<"$final" | paste -sd ';' -)
if ((ok == 0)) && grep -q '^check chain failed' <<<"$final"; then
    report 3 "request for the wrong chain" pass "rejected; failed check: $failed" e2e-3-wrong-chain
else
    report 3 "request for the wrong chain" fail "card: $(tr '\n' ';' <<<"$final")" e2e-3-wrong-chain
fi

# 5. Unsure, then Retry: the first copy arrives but the send fails (exit 1), so the card is unsure; the Wallet Manager
# takes that copy (its answer held back); Retry delivers the same id again, which it ignores; then the answer goes.
session "Case 5 agent"
touch "$loop/vault/hold"
ask
echo deliver-then-fail >"$loop/dev/fault"
send send
unsure=$(card state)
id=$(card id)
wm_poll
before=$(record "$id")
send retry
after_retry=$(card state)
wm_poll
after=$(record "$id")
copies=$(requests_in_vault_inbox "$id")
rm -f "$loop/vault/hold"
wm_poll
final=$(await_card Received); ok=$?
results=$(results_in_dev_inbox "$id")
shot e2e-5-resent-after-unsure
detail="sent: $unsure; retried: $after_retry; copies in the vault's inbox: $copies; Wallet Manager record after the first copy: ${before:-none}, after the second: ${after:-none}; results back: $results"
if [[ $unsure == "May have reached the Wallet Manager" && $after_retry == Sent && $copies == 2 && -n $before && $before == "$after" \
      && $after == "pending true 1 "* && $results == 1 ]] && ((ok == 0)); then
    report 5 "same request id resent after an unsure send" pass "$detail; card received" e2e-5-resent-after-unsure
else
    report 5 "same request id resent after an unsure send" fail "$detail; card: $(tr '\n' ';' <<<"$final")" e2e-5-resent-after-unsure
fi

# 4. The Wallet Manager stopped: delivered to the vault Mac but never picked up.
if stop_wallet_manager; then
    session "Case 4 agent"
    ask
    send send
    id=$(card id)
    sent=$(card state)
    later=$(sb wallet-later 6)
    shot e2e-4-not-picked-up
    hint=$(sed -n 's/^not-picked-up //p' <<<"$later")
    state=$(sed -n 's/^state //p' <<<"$later")
    detail="state $state, not-picked-up $hint, copies in the vault's inbox: $(requests_in_vault_inbox "$id"), Wallet Manager record: $(record "$id" | grep . || echo none)"
    if [[ $sent == Sent && $state == Sent && $hint == yes && -z $(record "$id") ]] && grep -q "hasn't picked it up yet" <<<"$later"; then
        report 4 "Wallet Manager stopped: stays Sent with the not-picked-up hint" pass "$detail" e2e-4-not-picked-up
    else
        report 4 "Wallet Manager stopped: stays Sent with the not-picked-up hint" fail "$detail" e2e-4-not-picked-up
    fi
else
    report 4 "Wallet Manager stopped: stays Sent with the not-picked-up hint" fail "the Wallet Manager (pid $wm_pid) didn't stop on SIGTERM" e2e-4-not-picked-up
fi

if ((failures == 0)); then say "wallet-e2e: all $cases cases passed"; else say "wallet-e2e: $failures of $cases cases failed (logs: --keep keeps $run)"; fi
exit $((failures == 0 ? 0 : 1))
