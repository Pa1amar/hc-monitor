# Install and uninstall. install asks, in order: [install curl?] -> URL -> services -> ports ->
# "Change thresholds?". A here-string adds a final newline, which answers the last question with Enter.

test_install_fresh() {
    rm "$ROOT_DIR/etc/hc-monitor.conf"
    printf 'nginx active\n' > "$STUB_DIR/services"
    set_ss tcp '0.0.0.0:22'
    set_ss udp '0.0.0.0:53'
    INPUT=$'https://hc-ping.com/new-check\nnginx\n22 53/udp\n'   # URL, services, ports; thresholds: Enter
    run_script install
    assert_rc 0
    local conf="$ROOT_DIR/etc/hc-monitor.conf" units="$ROOT_DIR/etc/systemd/system"
    assert_mode "$conf" 600
    assert_contains "$conf" 'HC_PING_URL="https://hc-ping.com/new-check"'
    assert_contains "$conf" 'SERVICES="nginx"'
    assert_contains "$conf" 'PORTS="22 53/udp"'
    assert_contains "$conf" 'DISK_MAX_PCT="90"'
    assert_contains "$conf" 'MEM_MAX_PCT="90"'
    assert_contains "$conf" 'LOAD_MAX_PER_CPU="2"'
    assert_mode "$ROOT_DIR/usr/local/bin/hc-monitor.sh" 700
    cmp -s "$SCRIPT" "$ROOT_DIR/usr/local/bin/hc-monitor.sh" || fail "the installed copy differs from the original"
    assert_mode "$units/hc-monitor.service" 644
    assert_mode "$units/hc-monitor.timer" 644
    assert_contains "$units/hc-monitor.service" "Type=oneshot"
    assert_contains "$units/hc-monitor.service" "ExecStart=/usr/local/bin/hc-monitor.sh"
    assert_contains "$units/hc-monitor.service" "TimeoutStartSec=2min"
    assert_contains "$units/hc-monitor.timer" "OnCalendar=*:0/5"
    assert_contains "$units/hc-monitor.timer" "WantedBy=timers.target"
    assert_calls_in_order "systemctl daemon-reload" "systemctl start hc-monitor.service" \
        "systemctl enable --now hc-monitor.timer"
    assert_requests ""   # the unit (a stub here) sends the first ping; the installer itself sends nothing
    assert_contains "$OUT" "The report will look like this:"
    assert_contains "$OUT" "Services: nginx=active"
    assert_contains "$OUT" "Ports: 22/tcp=listening, 53/udp=listening"
    assert_contains "$OUT" "First report sent."
    assert_contains "$OUT" "Period: 5 minutes, Grace Time: 10 minutes"
}

test_install_requires_url_when_none_is_configured() {
    rm "$ROOT_DIR/etc/hc-monitor.conf"
    INPUT=$'\nhttps://hc-ping.com/new-check\n\n\n'   # Enter without a URL must ask again
    run_script install
    assert_rc 0
    [[ $(grep -c "Expected a URL like https://hc-ping.com/<uuid>" "$ERR") == 1 ]] ||
        fail "an empty URL must be rejected exactly once"
    assert_contains "$ROOT_DIR/etc/hc-monitor.conf" 'HC_PING_URL="https://hc-ping.com/new-check"'
}

test_install_reprompts_bad_url_and_unknown_service() {
    printf 'nginx active\n' > "$STUB_DIR/services"
    INPUT=$'ftp://bad\nhttp://127.0.0.1:1/a"b\nhttp://127.0.0.1:1/new-uuid/\nnginx ngnix\nnginx\n\n'
    run_script install
    assert_rc 0
    [[ $(grep -c "Expected a URL like https://hc-ping.com/<uuid>" "$ERR") == 2 ]] ||
        fail "the URL hint must be shown twice (ftp and the quote)"
    assert_contains "$ERR" "Service ngnix not found."
    assert_contains "$ROOT_DIR/etc/hc-monitor.conf" 'HC_PING_URL="http://127.0.0.1:1/new-uuid"'
    assert_contains "$ROOT_DIR/etc/hc-monitor.conf" 'SERVICES="nginx"'
}

test_install_changes_thresholds() {
    INPUT=$'\n\n\ny\n101\n85\n80\n0\n1.5\n'
    run_script install
    assert_rc 0
    assert_contains "$ERR" "Expected a whole number from 1 to 100."
    assert_contains "$ERR" "Expected a positive number, e.g. 2 or 1.5."
    local conf="$ROOT_DIR/etc/hc-monitor.conf"
    assert_contains "$conf" 'DISK_MAX_PCT="85"'
    assert_contains "$conf" 'MEM_MAX_PCT="80"'
    assert_contains "$conf" 'LOAD_MAX_PER_CPU="1.5"'
}

test_reinstall_keeps_current_values() {
    write_conf 'HC_PING_URL="http://127.0.0.1:1/keep"' 'SERVICES="cron"' 'PORTS="22"' \
        'DISK_MAX_PCT="70"' 'MEM_MAX_PCT="75"' 'LOAD_MAX_PER_CPU="3"'
    printf 'cron active\n' > "$STUB_DIR/services"
    INPUT=$'\n\n\n'
    run_script install
    assert_rc 0
    local conf="$ROOT_DIR/etc/hc-monitor.conf"
    assert_contains "$conf" 'HC_PING_URL="http://127.0.0.1:1/keep"'
    assert_contains "$conf" 'SERVICES="cron"'
    assert_contains "$conf" 'PORTS="22"'
    assert_contains "$conf" 'DISK_MAX_PCT="70"'
    assert_contains "$conf" 'MEM_MAX_PCT="75"'
    assert_contains "$conf" 'LOAD_MAX_PER_CPU="3"'
}

test_install_dash_clears_services() {
    write_conf 'HC_PING_URL="http://127.0.0.1:1/x"' 'SERVICES="cron"'
    printf 'cron active\n' > "$STUB_DIR/services"
    INPUT=$'\n-\n\n'
    run_script install
    assert_rc 0
    assert_contains "$ROOT_DIR/etc/hc-monitor.conf" 'SERVICES=""'
}

test_install_rejects_invalid_ports() {
    INPUT=$'\n\ndb.local:5432 70000 53/icmp 0 0443 443/TCP\n22 53/udp 65535\n'
    run_script install
    assert_rc 0
    [[ $(grep -c "^Invalid port: " "$ERR") == 6 ]] || fail "all six invalid entries must be reported"
    assert_contains "$ERR" "Invalid port: db.local:5432 (expected 443, 443/tcp or 53/udp)."
    assert_contains "$ROOT_DIR/etc/hc-monitor.conf" 'PORTS="22 53/udp 65535"'
}

test_install_dash_clears_ports() {
    write_conf 'HC_PING_URL="http://127.0.0.1:1/x"' 'PORTS="22"'
    INPUT=$'\n\n-\n'
    run_script install
    assert_rc 0
    assert_contains "$ROOT_DIR/etc/hc-monitor.conf" 'PORTS=""'
}

test_install_from_installed_copy() {
    mkdir -p "$ROOT_DIR/usr/local/bin"
    cp "$SCRIPT" "$ROOT_DIR/usr/local/bin/hc-monitor.sh"
    RUN_SCRIPT="$ROOT_DIR/usr/local/bin/hc-monitor.sh"
    INPUT=$'\n\n\n'
    run_script install
    assert_rc 0
    cmp -s "$SCRIPT" "$ROOT_DIR/usr/local/bin/hc-monitor.sh" || fail "the installed copy got corrupted"
}

test_install_warns_when_report_has_problems() {
    set_df ' 95%   12% ext4     /'
    INPUT=$'\n\n\n'
    run_script install
    assert_rc 0
    assert_contains "$OUT" "Warning: the report lists problems, so the first ping goes to /fail and healthchecks.io will send an alert."
}

test_install_first_report_failure_keeps_timer_off() {
    echo 1 > "$STUB_DIR/start.rc"
    INPUT=$'\n\n\n'
    run_script install
    assert_rc 1
    assert_contains "$ERR" "the first report was not sent and the timer is not enabled"
    assert_contains "$CALLS" "systemctl status hc-monitor.service --no-pager"
    assert_not_contains "$CALLS" "enable"
}

test_install_eof_exits_1() {
    run_script install   # INPUT is not set: stdin is /dev/null
    assert_rc 1
    assert_contains "$ERR" "input aborted"
}

test_install_requires_systemd() {
    rmdir "$ROOT_DIR/run/systemd/system"
    INPUT=$'\n\n\n'
    run_script install
    assert_rc 1
    assert_contains "$ERR" "systemd is required"
}

test_install_offers_curl_when_missing() {
    make_path_without_curl
    INPUT=$'y\n\n\n\n'
    run_script install
    assert_rc 0
    assert_calls_in_order "apt-get update" "apt-get install -y curl"
}

test_install_without_curl_declined_exits_1() {
    make_path_without_curl
    INPUT=$'n\n'
    run_script install
    assert_rc 1
    assert_contains "$ERR" "curl is required to send reports"
    assert_not_contains "$CALLS" "apt-get"
}

test_uninstall_yes_removes_everything() {
    INPUT=$'\n\n\n'
    run_script install
    assert_rc 0
    : > "$CALLS"
    INPUT=$'y\n'
    run_script uninstall
    assert_rc 0
    local f
    for f in etc/hc-monitor.conf usr/local/bin/hc-monitor.sh \
        etc/systemd/system/hc-monitor.service etc/systemd/system/hc-monitor.timer; do
        [[ ! -e $ROOT_DIR/$f ]] || fail "/$f was not removed"
    done
    assert_calls_in_order "systemctl disable --now hc-monitor.timer" "systemctl daemon-reload" \
        "systemctl reset-failed hc-monitor.service"
    assert_contains "$OUT" "pause or delete the check in healthchecks.io"
}

test_uninstall_declined_keeps_everything() {
    INPUT=$'\n\n\n'
    run_script install
    INPUT=$'n\n'
    run_script uninstall
    assert_rc 0
    assert_contains "$OUT" "Cancelled."
    [[ -e $ROOT_DIR/etc/hc-monitor.conf ]] || fail "the config was removed although the answer was n"
    [[ -e $ROOT_DIR/usr/local/bin/hc-monitor.sh ]] || fail "the script was removed although the answer was n"
}

test_confirm_asks_again_on_unclear_answer() {
    INPUT=$'\n\n\n'
    run_script install
    INPUT=$'maybe\nyes\n'   # anything other than y/yes/n/no is asked again
    run_script uninstall
    assert_rc 0
    assert_contains "$ERR" "Please answer y or n."
    [[ ! -e $ROOT_DIR/etc/hc-monitor.conf ]] || fail "the config is still there after yes"
}
