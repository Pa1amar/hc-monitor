# Shared test helpers: fake ping receiver, fake root, script runner, assertions.

REAL_CURL=$(command -v curl)

start_server() {
    SERVER_DIR=$(mktemp -d)
    python3 "$TESTS_DIR/fake_hc_server.py" "$SERVER_DIR" &
    SERVER_PID=$!
    local i
    for i in $(seq 50); do
        [[ -f $SERVER_DIR/port ]] && break
        sleep 0.1
    done
    [[ -f $SERVER_DIR/port ]] || { echo "the fake ping receiver did not start" >&2; exit 1; }
    SERVER_PORT=$(< "$SERVER_DIR/port")
}

stop_server() {
    kill "$SERVER_PID" 2> /dev/null
    rm -rf "$SERVER_DIR"
}

setup() {
    T=$(mktemp -d)
    ROOT_DIR="$T/root"
    STUB_DIR="$T/stub"
    OUT="$T/out"
    ERR="$T/err"
    CALLS="$STUB_DIR/calls.log"
    BODY="$SERVER_DIR/body.txt"
    TEST_PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"
    RUN_SCRIPT="$SCRIPT"
    unset INPUT
    mkdir -p "$ROOT_DIR/etc/systemd/system" "$ROOT_DIR/proc/net" "$ROOT_DIR/run/systemd/system" \
        "$STUB_DIR" "$T/bin"
    cp "$TESTS_DIR"/stubs/* "$T/bin/"
    chmod +x "$T/bin/"*
    printf 'MemTotal:        8000000 kB\nMemFree:         1000000 kB\nMemAvailable:    6000000 kB\n' \
        > "$ROOT_DIR/proc/meminfo"
    echo "0.10 0.20 0.30 1/100 1234" > "$ROOT_DIR/proc/loadavg"
    set_df ' 45%   12% ext4     /'
    set_listen tcp
    set_listen udp
    set_cpu 1000 0 500 8000 100 0 0 0          # total 9600, idle 8000, iowait 100, steal 0
    set_cpu_state 300 8600 7250 100 0          # 5 minutes ago: 25% busy since then
    echo 4 > "$STUB_DIR/nproc"
    : > "$STUB_DIR/services"
    : > "$CALLS"
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\""
    : > "$SERVER_DIR/requests.log"
    rm -f "$BODY" "$SERVER_DIR/status"
}

# set_df <line>... — output of the df stub; the header is added automatically.
set_df() {
    { echo "Use% IUse% Type     Mounted on"; printf '%s\n' "$@"; } > "$STUB_DIR/df.out"
}

# set_listen <tcp|udp> [port]... — /proc/net/<proto> in the kernel format with a listening IPv4
# socket per port (state 0A for tcp, 07 for udp); /proc/net/<proto>6 gets only its header.
set_listen() {
    local proto="$1" state=0A port i=0
    shift
    [[ $proto == udp ]] && state=07
    {
        echo "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode"
        for port in "$@"; do
            printf '%4d: 00000000:%04X 00000000:0000 %s 00000000:00000000 00:00000000 00000000     0        0 %d 1 0000000000000000 100 0 0 10 0\n' \
                "$i" "$port" "$state" "$((20000 + i))"
            i=$((i + 1))
        done
    } > "$ROOT_DIR/proc/net/$proto"
    echo "  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode" \
        > "$ROOT_DIR/proc/net/${proto}6"
}

# add_socket <table> <local address:port in hex> <state> — appends one socket to /proc/net/<table>.
add_socket() {
    printf '  99: %s 00000000:0000 %s 00000000:00000000 00:00000000 00000000     0        0 30000 1 0000000000000000 100 0 0 10 0\n' \
        "$2" "$3" >> "$ROOT_DIR/proc/net/$1"
}

# set_cpu <user nice system idle iowait irq softirq steal> — the first line of /proc/stat.
set_cpu() {
    echo "cpu  $* 0 0" > "$ROOT_DIR/proc/stat"
}

# set_cpu_state <seconds ago> <total idle iowait steal> — the CPU sample saved by the previous run.
set_cpu_state() {
    local now
    printf -v now '%(%s)T' -1
    mkdir -p "$ROOT_DIR/var/lib/hc-monitor"
    echo "$((now - $1)) $2 $3 $4 $5" > "$ROOT_DIR/var/lib/hc-monitor/cpu.stat"
}

# use_sleep_stub <user nice system idle iowait irq softirq steal> — `sleep` rewrites /proc/stat
# with these counters and returns at once, so the one-second CPU sample is instant and exact.
use_sleep_stub() {
    printf '#!/bin/bash\necho "cpu  %s 0 0" > "%s/proc/stat"\n' "$*" "$ROOT_DIR" > "$T/bin/sleep"
    chmod +x "$T/bin/sleep"
}

write_conf() {
    printf '%s\n' "$@" > "$ROOT_DIR/etc/hc-monitor.conf"
}

# A directory with only the commands the script needs, without curl; switches TEST_PATH to it.
make_path_without_curl() {
    local c
    mkdir -p "$T/sysbin"
    for c in timeout awk uname cat mkdir mktemp chmod mv install readlink rm sleep ln; do
        ln -s "$(command -v "$c")" "$T/sysbin/$c"
    done
    TEST_PATH="$T/bin:$T/sysbin"
}

run_script() {
    local -a cmd=(env -i "HOME=$T" "PATH=$TEST_PATH" "HC_MONITOR_ROOT=$ROOT_DIR"
        "STUB_DIR=$STUB_DIR" "STUB_BIN=$T/bin" "REAL_CURL=$REAL_CURL"
        "https_proxy=http://127.0.0.1:9" "HTTPS_PROXY=http://127.0.0.1:9" "no_proxy=127.0.0.1"
        "$BASH" "$RUN_SCRIPT" "$@")
    if [[ -n ${INPUT+set} ]]; then
        "${cmd[@]}" <<< "$INPUT" > "$OUT" 2> "$ERR"
    else
        "${cmd[@]}" < /dev/null > "$OUT" 2> "$ERR"
    fi
    RC=$?
}

fail() {
    echo "    FAIL: $*"
    TEST_FAILED=1
}

assert_rc() {
    [[ $RC == "$1" ]] || fail "exit code $RC, expected $1; stderr: $(head -c 300 "$ERR")"
}

assert_contains() {
    grep -qF -- "$2" "$1" 2> /dev/null ||
        fail "${1##*/} lacks the line: $2; content: $(head -c 600 "$1" 2> /dev/null)"
}

assert_not_contains() {
    ! grep -qF -- "$2" "$1" 2> /dev/null || fail "${1##*/} unexpectedly contains: $2"
}

# assert_requests "POST /test-uuid" — the full list of requests to the receiver, one per line.
assert_requests() {
    local actual
    actual=$(cat "$SERVER_DIR/requests.log")
    [[ $actual == "$1" ]] || fail "requests to the receiver: '$actual', expected: '$1'"
}

assert_mode() {
    local mode
    mode=$(stat -c %a "$1" 2> /dev/null)
    [[ $mode == "$2" ]] || fail "mode of ${1#"$ROOT_DIR"}: '$mode', expected $2"
}

# The listed calls appear in the stub call log in exactly this order.
assert_calls_in_order() {
    local expected actual
    expected=$(printf '%s\n' "$@")
    actual=$(grep -xF -f <(printf '%s\n' "$@") "$CALLS")
    [[ $actual == "$expected" ]] || fail "calls: [$actual], expected in order: [$expected]"
}

run_all_tests() {
    local filter="$1" name passed=0 failed=0
    start_server
    trap stop_server EXIT
    for name in $(declare -F | awk '{ print $3 }' | grep '^test_' | grep -e "$filter"); do
        if (
            TEST_FAILED=0
            setup
            "$name"
            rm -rf "$T"
            exit "$TEST_FAILED"
        ); then
            echo "ok    $name"
            passed=$((passed + 1))
        else
            echo "FAIL  $name"
            failed=$((failed + 1))
        fi
    done
    echo
    echo "Total: $passed passed, $failed failed"
    (( failed == 0 && passed > 0 ))
}
