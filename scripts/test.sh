#!/usr/bin/env bash
# Runs swift-testing suites with the Command Line Tools, whose toolchain doesn't put the Testing
# macro plugin on the default search path.
# Usage: scripts/test.sh [swift test arguments…], e.g. scripts/test.sh --filter VCPipelineTests --scratch-path .build-pipeline
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
PLUGINS="$(xcrun --find swift | xargs dirname)/../lib/swift/host/plugins/testing"
if [[ ! -d "$PLUGINS" ]]; then
    PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
fi

exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
