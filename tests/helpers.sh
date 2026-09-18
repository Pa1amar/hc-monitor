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

# make_test_certs: in the current directory, a test CA (ca.pem) and certificates signed by it:
# good (localhost, ~400 days), soon (localhost, 5 days and 1 hour), expired (2020), other
# (other.test), plus self (self-signed localhost).
make_test_certs() {
    local yesterday
    yesterday=$(date -u -d '-1 day' +%Y%m%d%H%M%SZ)
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout ca.key -out ca.pem -days 3650 -subj /CN=hc-monitor-test-ca || return 1
    mkdir db && : > db/index.txt && echo 01 > db/serial
    cat > ca.cnf <<'EOF'
[ca]
default_ca = test
[test]
database = db/index.txt
serial = db/serial
new_certs_dir = db
default_md = sha256
policy = any
copy_extensions = copy
unique_subject = no
[any]
commonName = supplied
EOF
    make_leaf_cert good localhost "$yesterday" "$(date -u -d '+400 days' +%Y%m%d%H%M%SZ)" &&
        make_leaf_cert soon localhost "$yesterday" "$(date -u -d '+5 days +1 hour' +%Y%m%d%H%M%SZ)" &&
        make_leaf_cert expired localhost 20200101000000Z 20200102000000Z &&
        make_leaf_cert other other.test "$yesterday" "$(date -u -d '+400 days' +%Y%m%d%H%M%SZ)" &&
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
            -keyout self.key -out self.pem -days 400 -subj /CN=localhost \
            -addext subjectAltName=DNS:localhost
}

# make_leaf_cert <name> <DNS name> <not before> <not after> — a certificate signed by the test CA.
make_leaf_cert() {
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$1.key" \
        -out "$1.csr" -subj "/CN=$2" -addext "subjectAltName=DNS:$2" &&
        openssl ca -batch -config ca.cnf -cert ca.pem -keyfile ca.key -in "$1.csr" -out "$1.pem" \
            -startdate "$3" -enddate "$4" -notext
}

start_tls_server() {
    TLS_DIR=$(mktemp -d)
    (cd "$TLS_DIR" && make_test_certs) > "$TLS_DIR/certs.log" 2>&1 ||
        { echo "cannot create the test certificates:" >&2; cat "$TLS_DIR/certs.log" >&2; exit 1; }
    python3 "$TESTS_DIR/fake_tls_server.py" "$TLS_DIR" good soon expired other self &
    TLS_PID=$!
    local i
    for i in $(seq 50); do
        [[ -f $TLS_DIR/ports ]] && break
        sleep 0.1
    done
    [[ -f $TLS_DIR/ports ]] || { echo "the fake TLS server did not start" >&2; exit 1; }
}

stop_tls_server() {
    kill "$TLS_PID" 2> /dev/null
    rm -rf "$TLS_DIR"
}

# tls_port <name> — the port that serves that test certificate.
tls_port() {
    awk -v name="$1" '$1 == name { print $2 }' "$TLS_DIR/ports"
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
    set_oom_kills 0
    echo 4 > "$STUB_DIR/nproc"
    : > "$STUB_DIR/services"
    : > "$STUB_DIR/restarts"
    : > "$CALLS"
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\""
    : > "$SERVER_DIR/requests.log"
    rm -rf "$BODY" "$SERVER_DIR"/status* "$SERVER_DIR"/response* "$SERVER_DIR/bodies"
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

# set_oom_kills <n> — /proc/vmstat with the kernel's count of processes killed by the OOM killer.
set_oom_kills() {
    printf 'nr_free_pages 12345\noom_kill %s\npgfault 999\n' "$1" > "$ROOT_DIR/proc/vmstat"
}

# set_oom_state <seconds ago> <count> — the OOM kill count saved by the previous run.
set_oom_state() {
    local now
    printf -v now '%(%s)T' -1
    mkdir -p "$ROOT_DIR/var/lib/hc-monitor"
    echo "$((now - $1)) $2" > "$ROOT_DIR/var/lib/hc-monitor/oom.state"
}

# add_restarts_state <context> <unit> <count> — a restart count saved by the previous run
# (context "." is the server, otherwise a service name).
add_restarts_state() {
    mkdir -p "$ROOT_DIR/var/lib/hc-monitor"
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$ROOT_DIR/var/lib/hc-monitor/restarts.state"
}

# add_confirm_state <context> <key> <count> — how many runs in a row the previous run had seen a
# problem (context "." is the server, otherwise a service name).
add_confirm_state() {
    mkdir -p "$ROOT_DIR/var/lib/hc-monitor"
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$ROOT_DIR/var/lib/hc-monitor/confirm.state"
}

# use_sleep_stub <user nice system idle iowait irq softirq steal> — `sleep` rewrites /proc/stat
# with these counters and returns at once, so the one-second CPU sample is instant and exact.
use_sleep_stub() {
    printf '#!/bin/bash\necho "cpu  %s 0 0" > "%s/proc/stat"\n' "$*" "$ROOT_DIR" > "$T/bin/sleep"
    chmod +x "$T/bin/sleep"
}

# write_conf <line>... — the main config. Tests see problems at once (CONFIRM_RUNS="1") unless the
# lines set CONFIRM_RUNS themselves: a later assignment wins.
write_conf() {
    printf '%s\n' 'CONFIRM_RUNS="1"' "$@" > "$ROOT_DIR/etc/hc-monitor.conf"
}

# add_service <name> <line>... — writes <root home>/.healthchecks/<name>/.env (directories 700, file 600).
add_service() {
    local dir="$ROOT_DIR/root/.healthchecks/$1"
    shift
    mkdir -p "$dir"
    chmod 700 "$ROOT_DIR/root/.healthchecks" "$dir"
    printf '%s\n' "$@" > "$dir/.env"
    chmod 600 "$dir/.env"
}

# set_response <path> <status> [body] — how the receiver answers requests to <path>.
set_response() {
    echo "$2" > "$SERVER_DIR/status${1//\//_}"
    if (( $# > 2 )); then
        printf '%s' "$3" > "$SERVER_DIR/response${1//\//_}"
    fi
}

# body_of <path> — the file with the body of the last request to <path>.
body_of() {
    echo "$SERVER_DIR/bodies/${1//\//_}"
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
        "STUB_DIR=$STUB_DIR" "STUB_BIN=$T/bin" "REAL_CURL=$REAL_CURL" "SSL_CERT_FILE=$TLS_DIR/ca.pem"
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

# assert_requests "POST /a" — every request to the receiver, one per line, in any order.
assert_requests() {
    local actual expected
    actual=$(sort "$SERVER_DIR/requests.log")
    expected=$(printf '%s\n' "$1" | sort)
    [[ $actual == "$expected" ]] || fail "requests to the receiver: '$actual', expected: '$expected'"
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
    start_tls_server
    trap 'stop_server; stop_tls_server' EXIT
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
