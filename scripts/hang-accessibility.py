#!/usr/bin/env python3
"""How much of the main thread's time in hang reports goes to SwiftUI's accessibility machinery, and through which views.

Reads the `sample` call graphs that HangWatchdog writes (~/.vibeswitcher/debug/hang-*.txt) and, for each report and
in total, prints the main thread's samples: all of them, the busy ones (all but those parked in
__CFRunLoopServiceMachPort, i.e. waiting for an event) and those under a SwiftUI accessibility frame (a frame of
SwiftUI, SwiftUICore or AttributeGraph whose symbol starts with Accessibility*, AnyAccessibility* or
PropertiesTransform: AccessibilityNode, PropertiesTransform<AccessibilityNodeList>, AccessibilityChildBehavior.combine,
AccessibilityAttachment and the AccessibilityViewGraph update that drives them). A sample counts once, at its
outermost such frame. Then which accessibility frames those samples start at, the innermost SwiftUI accessibility
frames they end in, which of the main window's hosting views they're in (SwiftUI's accessibility update runs from the
attribute graph, so view code is rarely on these stacks: the hosting view is told by how deep it sits in the window,
see HOSTS), and the app frames (in VibeSwitcher) on those stacks: the deepest one below the accessibility frame when
there is one, else the deepest one above it. Each report's verdict (work, starved, waiting) and load come from its
.log beside it: a starved one is the Mac's load, not the app's work.

Reads reports only: it never samples or attaches to a process.

scripts/hang-accessibility.py [-q] [GLOB_OR_FILE ...]
  default: ~/.vibeswitcher/debug/hang-20261030-*.txt and hang-20261031-*.txt (the reports of 2026-10-30 and -31)
  -q: totals only, no line per report
"""
import collections
import glob
import os
import re
import sys

LINE = re.compile(r"^(?P<lead>[ +!:|]*?)(?P<count>\d+) (?P<frame>.*)$")
MODULE = re.compile(r"\(in (?P<module>[^)]+)\)")
A11Y_MODULES = {"SwiftUI", "SwiftUICore", "AttributeGraph"}
A11Y_SYMBOL = re.compile(
    r"^(?:(?:specialized |static |protocol witness for |closure #\d+ in |implicit closure #\d+ in |merged |"
    r"partial apply for |@objc )*)(?:Accessibility|AnyAccessibility|PropertiesTransform|_?AccessibilityNode)")
APP_MODULE = "VibeSwitcher"


def symbol(frame):
    """The frame's symbol without its module, offset and address."""
    return re.sub(r"\s+\(in [^)]+\).*$", "", frame).strip()


def module(frame):
    m = MODULE.search(frame)
    return m.group("module") if m else ""


def is_a11y(frame):
    return module(frame) in A11Y_MODULES and bool(A11Y_SYMBOL.match(symbol(frame)))


def short(sym, width=110):
    sym = re.sub(r"\s+\[0x[0-9a-f]+\].*$", "", sym)
    return sym if len(sym) <= width else sym[: width - 1] + "…"


def app_frame(frame):
    """A VibeSwitcher frame as 'symbol  file:line' (the source location when the report has one)."""
    loc = re.search(r"\]\s+(\S+:\d+)\s*$", frame)
    name = symbol(frame)
    return f"{short(name, 90)}  {loc.group(1)}" if loc else short(name, 90)


class Node:
    __slots__ = ("frame", "count", "children")

    def __init__(self, frame, count):
        self.frame, self.count, self.children = frame, count, []


def main_thread(path):
    """The main thread's call tree in a `sample` report, or None."""
    with open(path, errors="replace") as f:
        lines = f.read().split("\n")
    start = next((i for i, l in enumerate(lines) if ("com.apple.main-thread" in l or "Main Thread" in l) and re.match(r"^\s+\d+ ", l)), None)
    if start is None:
        return None
    root = Node(lines[start].strip(), int(lines[start].split()[0]))
    stack = [(-1, root)]
    for line in lines[start + 1:]:
        if not line.startswith("    +"):
            break
        m = LINE.match(line[4:])
        if not m:
            continue
        depth = len(m.group("lead"))
        node = Node(m.group("frame"), int(m.group("count")))
        while stack[-1][0] >= depth:
            stack.pop()
        stack[-1][1].children.append(node)
        stack.append((depth, node))
    return root


def idle(node):
    """Samples parked waiting for an event (outermost __CFRunLoopServiceMachPort)."""
    if "__CFRunLoopServiceMachPort" in node.frame:
        return node.count
    return sum(idle(c) for c in node.children)


def self_count(node):
    return node.count - sum(c.count for c in node.children)


# The main window's hosting views by how deep they sit from the window's frame view (the frame view 1), which a stack
# shows as the `-[NSView _layoutSubtreeWithOldSize:]` frames above `NSHostingView.layout()`. From
# HostingViewDepthTests (Tests/VibeSwitcherTests/AccessibilityTreeBenchTests.swift): run it again when
# MainWindowController's views move.
HOSTS = {
    5: "inspector (Team tab, briefing)",
    6: "sidebar (SessionListView)",
    7: "ended-sessions bar",
    8: "chat or header (the header is under 20 elements: the chat)",
}


def host_of(depth, hosting, transaction):
    if transaction and not hosting:
        return "a hosting view's transaction flush (NSHostingView.beginTransaction; which one isn't on the stack)"
    if not hosting:
        return "(no hosting view's layout on the stack)"
    if depth in HOSTS:
        return f"depth {depth}: {HOSTS[depth]}"
    return f"depth {depth}: " + ("a hosting view inside the sidebar, the chat or the header (a list row's cell, a chat part)"
                                 if depth > 8 else "another hosting view")


def walk_a11y(node, above_app, out, depth=0, hosting=False, transaction=False):
    """Finds each outermost accessibility frame under node; above_app: the deepest app frame above it; depth: the
    `_layoutSubtreeWithOldSize` frames above it, up to the hosting view's layout."""
    if is_a11y(node.frame):
        out["a11y"] += node.count
        out["entry"][short(symbol(node.frame))] += node.count
        out["hosts"][host_of(depth, hosting, transaction)] += node.count
        attribute_inside(node, None, node.frame, above_app, out)
        return
    if module(node.frame) == APP_MODULE:
        above_app = node.frame
    if not hosting and symbol(node.frame) == "-[NSView _layoutSubtreeWithOldSize:]":
        depth += 1
    if "NSHostingView.layout()" in node.frame:
        hosting = True
    if "NSHostingView.beginTransaction" in node.frame:
        transaction = True
    for c in node.children:
        walk_a11y(c, above_app, out, depth, hosting, transaction)


KIND = re.compile(r"\b(Accessibility\w*Modifier|AccessibilityChildBehavior\.\w+|PlatformItemList|SystemSegmentedControl|"
                  r"Accessibility\w*ContentView|AccessibilityCore\.text\w*|AnyAccessibilityAction)\b")


def attribute_inside(node, below_app, last_a11y, above_app, out, kinds=frozenset()):
    """Splits an accessibility subtree's samples by the app frame they pass through and the innermost a11y frame, and
    counts them for each kind of accessibility work on their stack (a modifier, a combine, a list row's label)."""
    if module(node.frame) == APP_MODULE:
        below_app = node.frame
    if is_a11y(node.frame):
        last_a11y = node.frame
    if module(node.frame) in A11Y_MODULES:
        kinds = kinds | {re.sub(r"^AccessibilityCore\.text.*", "AccessibilityCore.text (resolving Text into labels)", k)
                         for k in KIND.findall(symbol(node.frame))}
    own = self_count(node)
    if own > 0:
        out["leaf"][short(symbol(last_a11y))] += own
        for k in kinds or {"(none: tree plumbing only)"}:
            out["kinds"][k] += own
        if below_app:
            out["views"]["below  " + app_frame(below_app)] += own
        elif above_app:
            out["views"]["above  " + app_frame(above_app)] += own
        else:
            out["views"]["(no app frame on the stack)"] += own
    for c in node.children:
        attribute_inside(c, below_app, last_a11y, above_app, out, kinds)


def pct(part, whole):
    return f"{100.0 * part / whole:5.1f}%" if whole else "    -"


def sidecar(path):
    """The hang's own log beside its sample (hang-….log): its verdict (work, starved, waiting; older ones have none), the
    1-minute load and the core count."""
    log = path[:-4] + ".log"
    try:
        with open(log, errors="replace") as f:
            first = f.readline()
    except OSError:
        return None, None, None
    fields = dict(re.findall(r"(\w[\w-]*)=(\S+)", first))
    num = lambda k: float(fields[k]) if k in fields and re.match(r"^[\d.]+$", fields[k]) else None
    return fields.get("verdict"), num("load"), num("cpus")


def main(argv):
    quiet = "-q" in argv
    args = [a for a in argv if a != "-q"]
    if any(a in ("-h", "--help") for a in args):
        print(__doc__.strip())
        return 0
    debug = os.path.expanduser("~/.vibeswitcher/debug")
    patterns = args or [f"{debug}/hang-20261030-*.txt", f"{debug}/hang-20261031-*.txt"]
    paths = sorted({p for pat in patterns for p in (glob.glob(pat) if any(c in pat for c in "*?[") else [pat])})
    if not paths:
        print("no reports match " + " ".join(patterns), file=sys.stderr)
        return 1
    groups = collections.defaultdict(collections.Counter)
    counters = {k: collections.Counter() for k in ("entry", "leaf", "kinds", "views", "hosts", "work-hosts")}
    if not quiet:
        print(f"{'report':28} {'verdict':>8} {'load':>5} {'samples':>8} {'busy':>6} {'a11y':>6} {'a11y/busy':>9}")
    for path in paths:
        root = main_thread(path)
        if root is None:
            print(f"{os.path.basename(path):28} (no main thread)", file=sys.stderr)
            continue
        verdict, load, cpus = sidecar(path)
        out = {"a11y": 0, **{k: collections.Counter() for k in ("entry", "leaf", "views", "kinds", "hosts")}}
        walk_a11y(root, None, out)
        busy = root.count - idle(root)
        for k in ("entry", "leaf", "views", "kinds", "hosts"):
            counters[k].update(out[k])
        if verdict == "work":
            counters["work-hosts"].update(out["hosts"])
        keys = ["all", f"verdict {verdict or '(none: an older report)'}"]
        if load is not None and cpus:
            keys.append("load ≤ 2.5 × cores" if load <= 2.5 * cpus else "load > 2.5 × cores")
        for key in keys:
            g = groups[key]
            g["reports"] += 1; g["samples"] += root.count; g["busy"] += busy; g["a11y"] += out["a11y"]
            if busy and out["a11y"] * 2 > busy:
                g["dominated"] += 1
        if not quiet:
            print(f"{os.path.basename(path):28} {verdict or '-':>8} {load if load is not None else '-':>5} {root.count:8} {busy:6} "
                  f"{out['a11y']:6} {pct(out['a11y'], busy):>9}")
    print()
    print("Main thread's samples under SwiftUI accessibility frames (busy: all but those waiting for an event):")
    for key in sorted(groups, key=lambda k: (k != "all", k)):
        g = groups[key]
        print(f"  {key:34} {g['reports']:4} reports, {g['busy']:7} busy samples, {g['a11y']:6} accessibility = "
              f"{pct(g['a11y'], g['busy']).strip():>6} of busy; over half of busy in {g['dominated']}")
    total = groups["all"]["a11y"]
    for title, counter, whole in (
            ("Which hosting view the accessibility samples are in (by its depth in the window)", counters["hosts"], total),
            ("The same, in the reports whose verdict is work", counters["work-hosts"], sum(counters["work-hosts"].values())),
            ("Accessibility frames the samples enter at (outermost)", counters["entry"], total),
            ("Innermost accessibility frame of each sample", counters["leaf"], total),
            ("Kinds of accessibility work on the stack (a sample may count under several)", counters["kinds"], total),
            ("App frames on those stacks (below: evaluated inside the update; above: started it)", counters["views"], total)):
        print()
        print(title + ":")
        for name, n in counter.most_common(12):
            print(f"  {n:7} {pct(n, whole)}  {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
