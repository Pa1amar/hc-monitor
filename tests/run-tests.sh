#!/usr/bin/env bash
# Tests for hc-monitor.sh. Run on Linux or WSL: bash tests/run-tests.sh [test name filter]
set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$TESTS_DIR/../hc-monitor.sh"

source "$TESTS_DIR/helpers.sh"
for test_file in "$TESTS_DIR"/test_*.sh; do
    source "$test_file"
done

run_all_tests "${1:-}"
