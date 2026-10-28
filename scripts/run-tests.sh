#!/bin/bash
# Run the test suite under the resource policy macOS gives applications.
#
# Audit N01 (3.3.1 re-audit): a shell started by a background agent, launchd
# job or remote session can be suppressed or darwin-background. Its threads
# then run timeshare at priority 4 and timed waits wake ~200 ms late, so the
# realtime AirPlay mix-clock check cannot mean anything there. `taskpolicy -a`
# gives the test process the application policy the installed app runs under.
# In any other environment the realtime check reports the host's throttle
# signals and skips, while a promotion failure on a healthy host still fails.
#
# usage: scripts/run-tests.sh [swift test arguments…]   e.g. --filter AudioPipelineTests
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
exec /usr/sbin/taskpolicy -a swift test --scratch-path "${ALLOFMACOS_SCRATCH_PATH:-$PWD/.build}" "$@"
