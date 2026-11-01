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
#   --wallet-manager DIR  the Wallet Manager's checkout (~/dev/wallet-manager). Nothing is written there but its
#                         git-ignored node_modules: when node_modules/.package-lock.json is missing or older than its
#                         package-lock.json, the run first says so and runs `npm ci --ignore-scripts` in it.
#   --binary PATH         this build of VibeSwitcher (vibeswitcher-host beside it) instead of building (sandbox-app.sh).
#   --keep                keeps the run's scratch folder (logs, vault, inboxes) and says where; else it's removed.
#   --judge-case-1 SEEN RECORD  runs nothing: judges case 1 on a recorded outcome (SEEN, the card's states as the run
#                         writes them, "waiting → sent → received"; RECORD, the Wallet Manager's record as `record`
#                         prints it, "pending true 1 wallet:ok,recipient-known:failed", or "" for none), prints its
#                         lines and exits 0 on a pass, 1 on a failure.
#
# --real-testnet: one real GenLayer testnet payment through the same chain, instead of the cases below. Never part of
# scripts/test.sh, a merge or an audit: it broadcasts a real transaction, so it runs only when asked for by name. It
# refuses (exit 2, before any network or scratch folder) unless the chain is 4221, `from` is the Wallet Manager
# project's throwaway testnet wallet (0x4c50…ab99, the address its keystore names) and the transfer is a self-transfer
# (`to` = `from`) of 1 to 1000 wei, and the Wallet Manager's own NETWORKS.testnet (src/networks.ts, read through node)
# is chain 4221 at GenLayer's testnet RPC; the explorer link it prints is that entry's. The throwaway keystore and passphrase are read only from
# ~/.config/wallet-manager-testnet/ (keystore.json, passphrase: yours, regular files, 0600, in a 0700 folder), copied
# 0600 into the run's scratch vault, never printed or logged, and removed with it however the run ends (--keep keeps
# the logs, never those two). The Wallet Manager runs on that vault with no --rpc, so it uses GenLayer's testnet RPC;
# the sandbox files the request and clicks Send; the run signs on the Wallet Manager's /sign page over HTTP exactly as
# its docs/running.md, "Signing over HTTP (headless)", has it (GET the page, read its csrf, token and hash, POST the
# confirmation with the passphrase on stdin): one POST, never retried. It passes when the card shows Signed (the
# result `submitted`) with the transaction, and the RPC's eth_getTransactionReceipt says status 1 for that
# self-transfer; it prints the explorer link.
#   --amount WEI (1000), --from 0x… and --to 0x… (the throwaway wallet), --chain N (4221): checked, not chosen freely
#   --dry-run             everything up to the sign POST (the page fetched and read, the card Proposed), then stops:
#                         nothing is signed or sent
#   --check-guards        runs only the refusals above and says they pass: no network, no Wallet Manager or sandbox
#                         started (the checkout's NETWORKS.testnet is read through node: 4221 at GenLayer's testnet RPC)
#
# Cases, each with the card's final state and a light shot in .build/sandbox-shots/e2e/:
#   1 a valid testnet transfer from a known wallet: waiting → sent → received (or proposed), not rejected. A check
#     that failed in a result that isn't rejected is a warning (docs/protocol/wallet-request.md): named, not a failure.
#     Its recipient isn't in the vault, so a Wallet Manager with an address book warns `recipient-known`.
#  1b the same with case 1's recipient in the vault's address book (contacts/, as the Wallet Manager's
#     docs/vault-format.md has it): no warnings. Skipped, saying so, when that document doesn't describe contacts/.
#   2 an unknown wallet: rejected, the failed check named on the card
#   3 the wrong chain (the testnet wallet asked for mainnet): rejected, the chain check failed
#   5 the same id sent again after an unsure send (Retry): the Wallet Manager takes it once
#   4 the Wallet Manager stopped: the request stays Sent and shows the not-picked-up hint (the desk's clock moved on)
# (5 runs before 4, which stops the Wallet Manager.) Never the real Passage, its inbox or pairings, the Keychain, a
# real key or address, or the network: the chains are the Wallet Manager's fake chain on 127.0.0.1, for both networks.
# At the end it stops everything it started, by pid, and checks nothing of the run is left running.
set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/scratch.sh

repo=$(pwd -P)
wm=$HOME/dev/wallet-manager
binary=""
keep=""
judge=""
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
# testnet_network: the Wallet Manager's own testnet, NETWORKS.testnet from its src/networks.ts read through node (not
# matched as text, so its layout doesn't matter): chain 4221 at GenLayer's testnet RPC, with an https explorer, else a
# refusal. Sets TESTNET_EXPLORER, the explorer the run prints. Reads the checkout only: no network.
TESTNET_RPC=https://rpc.testnet-chain.genlayer.com
TESTNET_EXPLORER=""
testnet_network() {
    local checkout fields chain_id rpc_url explorer
    command -v node >/dev/null || refuse "node isn't on the PATH, so the Wallet Manager's testnet can't be read"
    { checkout=$(cd "$wm" 2>/dev/null && pwd -P) && [[ -f $checkout/src/networks.ts ]]; } || refuse "no src/networks.ts in a Wallet Manager checkout at $wm"
    fields=$(cd "$checkout" && node --input-type=module -e 'import { NETWORKS } from "./src/networks.ts";
        const t = NETWORKS?.testnet ?? {}, text = (v) => (typeof v === "string" && v !== "" && !/\s/.test(v) ? v : "-");
        process.stdout.write([typeof t.chainId === "number" ? String(t.chainId) : "-", text(t.rpcUrl), text(t.explorerUrl)].join(" "))' 2>/dev/null </dev/null) \
        || refuse "the Wallet Manager's src/networks.ts couldn't be read through node"
    read -r chain_id rpc_url explorer <<<"$fields"
    [[ $chain_id == "$TESTNET_CHAIN" && $rpc_url == "$TESTNET_RPC" ]] \
        || refuse "the Wallet Manager's NETWORKS.testnet is chain ${chain_id:--} at ${rpc_url:--}, not $TESTNET_CHAIN at $TESTNET_RPC"
    [[ $explorer =~ ^https://[A-Za-z0-9.-]+$ ]] || refuse "the Wallet Manager's NETWORKS.testnet has no https explorer (${explorer:--})"
    TESTNET_EXPLORER=$explorer
}
if [[ -z $real ]]; then
    [[ -z $real_options ]] || { say "wallet-e2e:$real_options only with --real-testnet"; exit 64; }
else
    [[ -z $dry_run || -z $check_guards ]] || { say "wallet-e2e: --dry-run or --check-guards, not both"; exit 64; }
    real_testnet_guards
    testnet_network
    if [[ -n $check_guards ]]; then
        say "wallet-e2e --real-testnet: guards pass: chain $chain, a self-transfer of $amount wei from the throwaway wallet $THROWAWAY, its keystore and passphrase private in $testnet_config; the Wallet Manager's testnet: $TESTNET_CHAIN at $TESTNET_RPC, explorer $TESTNET_EXPLORER"
        exit 0
    fi
fi

command -v node >/dev/null || die "node isn't on the PATH"
wm=$(cd "$wm" 2>/dev/null && pwd -P) || die "no Wallet Manager checkout at $wm (--wallet-manager DIR)"
[[ -f $wm/src/server/main.ts && -f $wm/src/dev/fake-chain-cli.ts ]] || die "$wm isn't the Wallet Manager's checkout (no src/server/main.ts)"
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
    answer=$(rpc eth_getBalance "[\"$THROWAWAY\",\"latest\"]") || die "the testnet RPC didn't answer eth_getBalance"
    balance=$(decimal "$(jget "$answer" "")")
    answer=$(rpc eth_getTransactionCount "[\"$THROWAWAY\",\"latest\"]") || die "the testnet RPC didn't answer eth_getTransactionCount"
    nonce_before=$(decimal "$(jget "$answer" "")")
    answer=$(rpc eth_getTransactionCount "[\"$THROWAWAY\",\"pending\"]") || die "the testnet RPC didn't answer eth_getTransactionCount"
    [[ $(decimal "$(jget "$answer" "")") == "$nonce_before" ]] || refuse "a transaction from the throwaway wallet is still pending: wait for it to be mined"
    say "testnet RPC $TESTNET_RPC: chain $TESTNET_CHAIN; the throwaway wallet holds $balance wei, nonce $nonce_before"
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
    write "$vault/vault.json" '{ "format": "wallet-manager-vault", "version": "1.0" }'
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
write "$vault/vault.json" '{ "format": "wallet-manager-vault", "version": "1.0" }'
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
# docs/running.md, "Signing over HTTP (headless)", has it; the card ends Signed (the result `submitted`) and the RPC's
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

    # 0. A pending request, its checks done; GET /requests reads the inbox now; its card links to /sign/<id>.
    wm_poll
    final=$(await_card "Received|Proposed|Rejected") || { real_fail "no answer from the Wallet Manager on the card: $(tr '\n' ';' <<<"$final")"; return; }
    states+=" → $(sed -n 's/^state //p' <<<"$final" | tr '[:upper:]' '[:lower:]')"
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
    # A fresh request with no calldata: the page asks for neither the stale box nor the blind-call phrase. Either
    # shown means something else is to be signed, and this run never sends them.
    if grep -q 'name="stillWanted"' "$sign_dir/page.html" || grep -q 'name="acknowledgement"' "$sign_dir/page.html"; then
        real_fail "the signing page asks for a stale or blind-call acknowledgement: this run signs only a fresh self-transfer"; return
    fi
    # What the page says will be signed (from the transaction's own bytes): chain 4221, from and to the throwaway
    # wallet, the amount. The run stops before the POST unless all of it matches.
    local row_chain row_from row_to row_send
    row() { sed -nE "s|^(<dl>)?<dt>$1</dt><dd>(.*)</dd>(</dl>)?\$|\\2|p" "$sign_dir/page.html" | head -1; }   # one row a line, <dl> before the first
    row_chain=$(row Chain); row_from=$(row From); row_to=$(row To); row_send=$(row Send)
    local grouped
    grouped=$amount   # as the page groups digits (1,000): the amount has at most 4
    ((${#amount} > 3)) && grouped="${amount:0:${#amount}-3},${amount:${#amount}-3}"
    # Read as text, the markup taken out (the page wraps addresses as it likes): To is the address and nothing else.
    untag() { sed -e 's/<br>/ /g' -e 's/<[^>]*>//g' <<<"$1"; }
    if [[ $(untag "$row_chain") != *"($TESTNET_CHAIN)" || $(lower "$(untag "$row_from")") != *" $(lower "$THROWAWAY")" \
          || $(lower "$(untag "$row_to")") != "$(lower "$THROWAWAY")" || $(untag "$row_send") != *" $grouped base units" ]]; then
        real_fail "the signing page doesn't show a self-transfer of $amount wei on $TESTNET_CHAIN from the throwaway wallet (chain: $row_chain; to: $row_to; send: $row_send)"; return
    fi
    final=$(await_card Proposed) || { real_fail "the card didn't show Proposed after the page: $(tr '\n' ';' <<<"$final")"; return; }
    states+=" → proposed"
    if [[ -n $dry_run ]]; then
        shot e2e-real-testnet-dry-run
        report real "testnet payment, dry run (stopped before the sign POST)" pass \
            "$states; the page shows a self-transfer of $amount wei on $TESTNET_CHAIN from $THROWAWAY, signing hash $HASH; nothing signed or sent" e2e-real-testnet-dry-run
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
    states+=" → signed (303)"

    # 4. Until submitted: the signing pass looks for the receipt every 15 s; the result comes back to the card.
    final=$(await_card "Signed|Failed" 3000) || { real_fail "no submitted result on the card in 10 minutes: $(tr '\n' ';' <<<"$final")"; return; }
    states+=" → $(sed -n 's/^state //p' <<<"$final" | tr '[:upper:]' '[:lower:]')"
    shot e2e-real-testnet
    local tx card_hash card_url result result_hash signed_hash
    tx=$(sed -n 's/^tx //p' <<<"$final")
    card_hash=${tx%% *}; card_url=""; [[ $tx == *" "* ]] && card_url=${tx#* }
    [[ $(sed -n 's/^state //p' <<<"$final") == Signed && $card_hash =~ ^0x[0-9a-f]{64}$ ]] \
        || { real_fail "the card ended $(sed -n 's/^state //p' <<<"$final"), not Signed with a transaction: $(tr '\n' ';' <<<"$final")"; return; }
    # The result the card took: `submitted` with that txHash, in the dev side's inbox; the vault's signed.json agrees.
    result=$(node -e 'const fs = require("fs"), dir = process.argv[1], id = process.argv[2];
        const all = fs.readdirSync(dir).filter((f) => f.endsWith(`-wallet-result-${id}.json`)).map((f) => JSON.parse(fs.readFileSync(`${dir}/${f}`, "utf8")));
        const s = all.filter((r) => r.status === "submitted");
        process.stdout.write(s.length === 1 ? `${s[0].txHash} ${s[0].explorerURL ?? ""}` : `${s.length} submitted results`)' "$loop/dev/inbox/0a1b2c3d" "$id" 2>&1)
    result_hash=${result%% *}
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
# contacts/<id>.json, in a vault whose version has contacts (the version the document's contacts/ section names; the
# vault stays 1.0 until here). The checker must take the vault; then no warnings.
contacts_doc=$wm/docs/vault-format.md
if [[ -f $contacts_doc ]] && grep -q '^## `contacts/' "$contacts_doc"; then
    contacts_version=$(awk '/^## `contacts\//{on=1; next} on && /^## /{exit} on' "$contacts_doc" | grep -oE 'format [0-9]+\.[0-9]+' | head -1 | cut -d' ' -f2)
    [[ -n $contacts_version ]] || contacts_version=$(sed -n '1s/^# Vault format, version \([0-9]*\.[0-9]*\).*/\1/p' "$contacts_doc")
    if [[ -z $contacts_version ]]; then
        report 1b "recipient in the address book" fail "$contacts_doc describes contacts/ but names no format version for them"
    else
        write "$vault/vault.json" "{ \"format\": \"wallet-manager-vault\", \"version\": \"$contacts_version\" }"
        write "$vault/contacts/e2e-recipient.json" "{ \"address\": \"$RECIPIENT\", \"label\": \"Made-up end-to-end recipient\", \"networks\": [\"testnet\"], \"workspaces\": [\"e2e\"] }"
        if (cd "$wm" && node src/cli/check-vault.ts "$vault") >"$run/check-vault-contacts.log" 2>&1; then
            case_1 1b "recipient in the address book (vault $contacts_version, contacts/e2e-recipient.json)" e2e-1b-recipient-known strict
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
