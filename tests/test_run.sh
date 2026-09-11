# Run modes, config, sending and exit codes.

test_ok_report_goes_to_check_url() {
    run_script
    assert_rc 0
    assert_requests "POST /test-uuid"
    assert_contains "$BODY" "All good"
    assert_contains "$BODY" "Host: "
    assert_contains "$OUT" "OK: report sent"
}

test_trailing_slashes_in_url_are_dropped() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid//\""
    run_script
    assert_rc 0
    assert_requests "POST /test-uuid"
}

test_dry_run_prints_report_and_sends_nothing() {
    run_script --dry-run
    assert_rc 0
    assert_requests ""
    assert_contains "$OUT" "Ping URL: http://127.0.0.1:$SERVER_PORT/test-uuid"
    assert_contains "$OUT" "All good"
}

test_ping_failure_exits_1() {
    echo 404 > "$SERVER_DIR/status"
    run_script
    assert_rc 1
    assert_contains "$ERR" "Error: failed to send the report (curl exit code 22)"
}

test_empty_url_exits_2() {
    write_conf 'HC_PING_URL=""'
    run_script
    assert_rc 2
    assert_contains "$ERR" "HC_PING_URL is not set, run install"
}

test_missing_config_exits_2() {
    rm "$ROOT_DIR/etc/hc-monitor.conf"
    run_script
    assert_rc 2
    assert_contains "$ERR" "HC_PING_URL is not set, run install"
    assert_requests ""
}

test_invalid_threshold_in_config_exits_2() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'DISK_MAX_PCT="90%"'
    run_script
    assert_rc 2
    assert_contains "$ERR" "invalid DISK_MAX_PCT"
    assert_requests ""
}

test_unreadable_config_exits_2() {
    (( EUID == 0 )) && return 0   # root can read any file, so this case can't be reproduced
    chmod 000 "$ROOT_DIR/etc/hc-monitor.conf"
    run_script
    assert_rc 2
    assert_contains "$ERR" "cannot read"
}

test_unknown_argument_exits_2() {
    run_script --bogus
    assert_rc 2
    assert_contains "$ERR" "Usage:"
}

test_extra_arguments_exit_2() {
    run_script install now
    assert_rc 2
    assert_contains "$ERR" "Usage:"
}

test_run_via_sh_asks_for_bash() {
    sh "$SCRIPT" > "$OUT" 2> "$ERR"
    RC=$?
    assert_rc 2
    assert_contains "$ERR" "Run with bash"
}

test_invalid_port_in_config_exits_2() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'PORTS="22 db.local:5432"'
    run_script
    assert_rc 2
    assert_contains "$ERR" "invalid port in"
    assert_contains "$ERR" "db.local:5432"
    assert_requests ""
}
