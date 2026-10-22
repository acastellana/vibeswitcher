#!/bin/bash
# The project's init_command: what a worker runs first in a new worktree, and merge and an audit before their tests.
# In a worktree the lead made (<main checkout>/.vibeswitcher/worktrees/<slug>) it points SourceKit-LSP at the
# worktrees' shared cache of the SDK's modules (scripts/lib/module-cache.sh), as scripts/test.sh points the build:
# .sourcekit-lsp/config.json (git-ignored), written before the first edit of a Swift file starts the session's
# sourcekit-lsp. Without it the LSP builds a ModuleCache of its own in .build, up to 300 MB, the disk the shared cache
# saves. Anywhere else (the main checkout, merge's and an audit's worktrees) it does nothing, and a config.json
# already there is left as it is.
#
# scripts/worktree-init.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/module-cache.sh

shared_module_cache > /dev/null
[[ -n $module_cache ]] || exit 0
[[ -e .sourcekit-lsp/config.json ]] && exit 0
mkdir -p .sourcekit-lsp || exit 1
printf '{\n  "swiftPM": { "swiftCompilerFlags": ["-module-cache-path", "%s"] }\n}\n' "$module_cache" > .sourcekit-lsp/config.json || exit 1
echo "SourceKit-LSP: the worktrees' shared module cache, $module_cache (.sourcekit-lsp/config.json)"
