// scripts/test.sh --retry-failed's judge (node, which test.sh requires already): which Swift tests a failed run failed,
// whether that failure is theirs alone and so may be retried, the retry's filter, and whether the retry passed. It reads
// two things a run leaves: Swift Testing's event stream (swift test --event-stream-output-path FILE
// --experimental-event-stream-version 0, one JSON record a line), which names each test by its full ID
// ("Module.Suite/name()/File.swift:12:6"), and the run's console output, which says what the stream can't: a test
// process that died of a signal after its run ended, XCTest's failures, Swift Testing's own closing line.
//
// The console alone can't name a test: it prints "shared()" for every suite's shared(), a display name ("Some words")
// no filter matches, and a test's own output can print a ✘ line. So the stream names them, and every doubt is a refusal:
// a run is retried only when everything below holds, and fails as it would have without the option otherwise.
//
//   first EVENTS CONSOLE LIMIT OUT   A failed first run: exit 0 when it may be retried, its failed tests' IDs written to
//                                    OUT one a line, in the order they first failed; else exit 1, the reason on stdout.
//   filter IDS                       The retry's `swift test --filter`: each ID of the file IDS matched literally, whole.
//   retry EVENTS CONSOLE IDS         The retry passed: exit 0 when it ran exactly IDS's tests and each passed; else 1,
//                                    the reason on stdout.
//   issues EVENTS IDS                Each failing issue the run recorded in IDS's tests, "  ID: message", for the log.
//   flaky IDS                        One line a test: "flaky (passed on retry): Module.Suite/name()".
import { readFileSync, writeFileSync, existsSync } from "node:fs";

// "say WHY; exit 1": the reason a run isn't retried, or a retry didn't pass.
class Refusal extends Error {}
const refuse = (why) => { throw new Refusal(why); };

// The event stream's records: [{kind: "test", payload: {id, kind}} | {kind: "event", payload: {kind, testID, …}}].
function stream(path) {
    if (!existsSync(path)) refuse("Swift Testing wrote no event stream (the run ended before its tests started)");
    const records = [];
    const lines = readFileSync(path, "utf8").split("\n");
    lines.forEach((line, index) => {
        if (line.trim() === "") return;
        let record;
        try { record = JSON.parse(line); } catch { refuse(`line ${index + 1} of Swift Testing's event stream isn't whole (a run cut off as it wrote)`); }
        if (record?.version !== 0) refuse(`line ${index + 1} of Swift Testing's event stream isn't version 0, the one read here`);
        records.push(record);
    });
    return records;
}

// What a stream says: its tests' kinds by ID, its events, and the failing issues (not known ones, not warnings).
function read(records) {
    const kinds = new Map();
    const events = [];
    for (const record of records) {
        if (record.kind === "test" && typeof record.payload?.id === "string") kinds.set(record.payload.id, record.payload.kind);
        else if (record.kind === "event" && record.payload) events.push(record.payload);
    }
    const failing = events.filter((event) => event.kind === "issueRecorded" && event.issue?.isKnown !== true
        && event.issue?.isFailure !== false && event.issue?._severity !== "warning");
    return { kinds, events, failing };
}

// The run started once and ended once, its end the last event, and every test and test case it started ended: a run
// that crashed or was stopped never wrote its end, and the rest of its tests never ran.
function ranToItsEnd({ events }) {
    const runs = events.filter((event) => event.kind === "runStarted").length;
    const ends = events.filter((event) => event.kind === "runEnded").length;
    if (runs !== 1 || ends !== 1 || events.at(-1)?.kind !== "runEnded") {
        refuse(ends === 0 ? "Swift Testing's run never ended (a crash, a kill or a time limit stopped it)"
            : `Swift Testing's event stream shows ${runs} runs started and ${ends} ended, not one run that ended last`);
    }
    const open = new Map();
    for (const event of events) {
        const key = event.kind.startsWith("testCase") ? `${event.testID} ${event._testCase?.id}` : event.testID;
        if (event.kind === "testStarted" || event.kind === "testCaseStarted") open.set(key, (open.get(key) ?? 0) + 1);
        if (event.kind === "testEnded" || event.kind === "testCaseEnded") open.set(key, (open.get(key) ?? 0) - 1);
    }
    const unended = [...open].filter(([, count]) => count !== 0).map(([key]) => key);
    if (unended.length > 0) refuse(`${unended.length} tests started and never ended, e.g. ${unended[0]}`);
}

// The console output, its colours taken out.
const consoleLines = (path) => readFileSync(path, "utf8").split("\n").map((line) => line.replace(/\u001B\[[0-9;]*m/g, "").trim());

// Swift Testing's closing line: "✘ Test run with 7 tests in 2 suites failed after 0.001 seconds with 4 issues
// (including 1 known issue)." The console has exactly one, else it can't be trusted to be the run's.
const closing = /^\S{1,2} Test run with \d+ tests?\b.* (passed|failed) after /;

// What the console says that the stream can't, alike for both runs: SwiftPM didn't say the test process "exited with
// unexpected signal code" (it does for signals 1, 3, 4, 6, 7, 8, 10, 11, 13 and 14, a fatalError's 4 among them, even
// after the run's end, and exits 1 as for a failing test), XCTest failed nothing, and Swift Testing's closing line is
// there once. Returns that line. Not seen (swift test 6.4.2 prints the same console, stderr and event stream, and exits
// 1): a test process ended by SIGKILL, SIGTERM or SIGINT, or exiting non-zero without a signal, after every test ended
// and was recorded. Beside 1 to 10 failed tests that then pass alone, such a run is retried into a pass: a limit the
// lead accepted (scripts/test.sh, `swift_tests_retrying_failed`).
function consoleSays(lines) {
    const died = lines.find((line) => / exited with unexpected signal code /.test(line) || /^error: Process '.*' exited with /.test(line));
    if (died) refuse(`the test process didn't end by itself: ${died.slice(0, 300)}`);
    const xctest = lines.find((line) => /^Test Case '.*' failed/.test(line) || /\bExecuted \d+ tests?, with [1-9]\d* failures?\b/.test(line));
    if (xctest) refuse(`XCTest failed, and only Swift Testing's tests are retried: ${xctest.slice(0, 300)}`);
    const ends = lines.filter((line) => closing.test(line));
    if (ends.length !== 1) refuse(`the output shows ${ends.length} Swift Testing closing lines ("Test run with N tests … after"), not one`);
    return ends[0];
}

// An ID the filter can match literally: no control character (a raw identifier may hold anything else).
const plainID = (id) => typeof id === "string" && id.length > 0 && !/[\u0000-\u001F\u007F]/.test(id);

function first(events, consolePath, limit, out) {
    const run = read(stream(events));
    ranToItsEnd(run);
    const end = consoleSays(consoleLines(consolePath));
    if (!/ failed after /.test(end)) refuse(`Swift Testing's run passed ("${end.slice(0, 200)}"): what failed isn't a test`);
    if (run.failing.length === 0) refuse("Swift Testing recorded no failing issue: what failed isn't a test");
    const failed = [];
    for (const issue of run.failing) {
        const id = issue.testID;
        const where = id == null ? "outside any test" : run.kinds.get(id) === "function" ? null : `in ${id}, not a test function`;
        if (where) refuse(`an issue was recorded ${where}: ${message(issue)}`);
        if (!plainID(id)) refuse(`a failed test's ID holds a control character: ${JSON.stringify(id)}`);
        if (!failed.includes(id)) failed.push(id);
    }
    // The closing line counts every issue, known ones too: as many failing ones as the stream recorded.
    const issues = Number(end.match(/ with (\d+) issues?\b/)?.[1] ?? 0);
    const known = Number(end.match(/\(including (\d+) known issues?\)/)?.[1] ?? 0);
    if (issues - known !== run.failing.length) {
        refuse(`the closing line counts ${issues - known} failing issues and the event stream ${run.failing.length}`);
    }
    if (failed.length > limit) refuse(`${failed.length} tests failed, more than ${limit}: a broken change, not a flake`);
    writeFileSync(out, failed.join("\n") + "\n");
}

// Each character matched as itself: letters and digits as they are, any other ASCII character escaped, anything else
// by its code point. Anchored at both ends, so no ID matches a longer one or the start of another.
function literal(id) {
    let text = "";
    for (const char of id) {
        if (/^[A-Za-z0-9]$/.test(char)) text += char;
        else if (char.codePointAt(0) < 0x80) text += "\\" + char;
        else text += `\\x{${char.codePointAt(0).toString(16).toUpperCase()}}`;
    }
    return text;
}

const ids = (path) => readFileSync(path, "utf8").split("\n").filter((line) => line !== "");

function filter(path) {
    const list = ids(path);
    if (list.length === 0 || !list.every(plainID)) refuse("no test to retry");
    return "^(" + list.map(literal).join("|") + ")$";
}

function retry(events, consolePath, path) {
    const expected = ids(path);
    const run = read(stream(events));
    ranToItsEnd(run);
    const end = consoleSays(consoleLines(consolePath));
    if (!/ passed after /.test(end)) refuse(`Swift Testing's run failed: ${end.slice(0, 200)}`);
    if (run.failing.length > 0) refuse(`it recorded ${run.failing.length} failing issues, the first ${run.failing[0].testID ?? "outside any test"}: ${message(run.failing[0])}`);
    const ran = [...new Set(run.events.filter((event) => event.kind === "testStarted" && run.kinds.get(event.testID) === "function").map((event) => event.testID))];
    const missing = expected.filter((id) => !ran.includes(id));
    const extra = ran.filter((id) => !expected.includes(id));
    if (missing.length > 0) refuse(`it didn't run ${missing.join(", ")}`);
    if (extra.length > 0) refuse(`it ran more than the failed tests: ${extra.join(", ")}`);
}

// An issue's first lines, as the console shows them.
function message(issue) {
    const texts = (issue.messages ?? []).map((part) => part.text).filter(Boolean).slice(0, 3);
    const text = texts.join(" / ") || "(no message)";
    return text.length > 300 ? text.slice(0, 299) + "…" : text;
}

function issues(events, path) {
    const wanted = new Set(ids(path));
    let run;
    try { run = read(stream(events)); } catch (error) { if (error instanceof Refusal) return `  (${error.message})`; throw error; }
    const lines = run.failing.filter((issue) => issue.testID == null || wanted.has(issue.testID))
        .map((issue) => `  ${issue.testID ?? "(outside any test)"}: ${message(issue)}`);
    return lines.length > 0 ? lines.join("\n") : "  (no failing issue in its event stream)";
}

// "Module.Suite/name()" from "Module.Suite/name()/File.swift:12:6".
const named = (id) => id.replace(/\/[^/]*:\d+:\d+$/, "");

const [command, ...args] = process.argv.slice(2);
try {
    switch (command) {
        case "first": first(args[0], args[1], Number(args[2]), args[3]); break;
        case "filter": console.log(filter(args[0])); break;
        case "retry": retry(args[0], args[1], args[2]); break;
        case "issues": console.log(issues(args[0], args[1])); break;
        case "flaky": for (const id of ids(args[0])) console.log(`flaky (passed on retry): ${named(id)}`); break;
        default: console.log(`retry-failed.mjs: no command ${command}`); process.exit(2);
    }
} catch (error) {
    if (!(error instanceof Refusal)) throw error;
    console.log(error.message);
    process.exit(1);
}
