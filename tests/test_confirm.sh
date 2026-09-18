# Problem confirmation: a state problem must be seen in CONFIRM_RUNS runs in a row before the
# report goes to /fail; events (restarts, OOM kills) never wait.

# confirm_conf <runs> [line]... — the server config with CONFIRM_RUNS.
confirm_conf() {
    local runs=$1
    shift
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" "CONFIRM_RUNS=\"$runs\"" "$@"
}

test_new_problem_is_pending() {
    confirm_conf 2
    set_df ' 95%   12% ext4     /'
    run_script
    assert_rc 0
    assert_requests "POST /test-uuid"
    assert_contains "$BODY" "All good"
    assert_contains "$BODY" "Pending:"
    assert_contains "$BODY" "- Disk /: 95% used (threshold 90%) (seen 1 of 2 runs)"
    grep -qx "OK: report sent (pending: Disk /: 95% used (threshold 90%))" "$OUT" ||
        fail "no pending log line: $(cat "$OUT")"
    assert_contains "$ROOT_DIR/var/lib/hc-monitor/confirm.state" $'.\tDisk /\t1'
}

test_problem_is_confirmed_on_the_second_run() {
    confirm_conf 2
    set_df ' 95%   12% ext4     /'
    add_confirm_state . "Disk /" 1
    run_script
    assert_rc 0
    assert_requests "POST /test-uuid/fail"
    assert_contains "$BODY" "- Disk /: 95% used (threshold 90%)"
    assert_not_contains "$BODY" "Pending:"
    assert_contains "$ROOT_DIR/var/lib/hc-monitor/confirm.state" $'.\tDisk /\t2'
}

test_changing_values_keep_the_same_problem() {
    confirm_conf 2
    set_cpu_state 300 8600 7950 100 0            # 95% busy now
    add_confirm_state . CPU 1                    # the previous run saw a different figure
    run_script --dry-run
    assert_contains "$OUT" "Ping URL: http://127.0.0.1:$SERVER_PORT/test-uuid/fail"
    assert_contains "$OUT" "- CPU: 95% busy (threshold 90%)"
}

test_recovered_problem_starts_over() {
    confirm_conf 2
    add_confirm_state . "Disk /" 5
    run_script
    assert_rc 0
    assert_requests "POST /test-uuid"
    assert_not_contains "$BODY" "Pending:"
    assert_not_contains "$ROOT_DIR/var/lib/hc-monitor/confirm.state" "Disk /"
}

test_one_problem_key_counts_once_per_run() {
    confirm_conf 2
    set_df                                      # no data...
    echo 1 > "$STUB_DIR/df.rc"                   # ...and an error: two "Disk" problems
    run_script
    assert_requests "POST /test-uuid"
    assert_contains "$BODY" "- Disk: df failed (exit code 1) (seen 1 of 2 runs)"
    assert_contains "$BODY" "- Disk: df returned no data (seen 1 of 2 runs)"
    assert_contains "$ROOT_DIR/var/lib/hc-monitor/confirm.state" $'.\tDisk\t1'
}

test_events_are_reported_at_once() {
    confirm_conf 2 'SERVICES="nginx"'
    printf 'nginx active\n' > "$STUB_DIR/services"
    printf 'nginx 5\n' > "$STUB_DIR/restarts"
    add_restarts_state . nginx 3
    run_script
    assert_rc 0
    assert_requests "POST /test-uuid/fail"
    assert_contains "$BODY" "- Service nginx: restarted 2 times since the last check"
    assert_not_contains "$BODY" "Pending:"
}

test_pending_problem_in_a_service_report() {
    confirm_conf 2
    add_service nym "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/svc-uuid\"" 'PORTS="8080"'
    run_script
    assert_rc 0
    assert_requests $'POST /svc-uuid\nPOST /test-uuid'
    assert_contains "$(body_of /svc-uuid)" "- Port 8080/tcp: not listening (seen 1 of 2 runs)"
    grep -qx "\[nym\] OK: report sent (pending: Port 8080/tcp: not listening)" "$OUT" ||
        fail "no pending log line for the service: $(cat "$OUT")"
    assert_contains "$ROOT_DIR/var/lib/hc-monitor/confirm.state" $'nym\tPort 8080/tcp\t1'
}

test_dry_run_keeps_confirm_state() {
    confirm_conf 2
    set_df ' 95%   12% ext4     /'
    add_confirm_state . "Disk /" 1
    run_script --dry-run
    assert_contains "$OUT" "- Disk /: 95% used (threshold 90%)"
    assert_contains "$ROOT_DIR/var/lib/hc-monitor/confirm.state" $'.\tDisk /\t1'
    assert_not_contains "$ROOT_DIR/var/lib/hc-monitor/confirm.state" $'.\tDisk /\t2'
}

test_invalid_confirm_runs_exits_2() {
    confirm_conf 0
    run_script
    assert_rc 2
    assert_contains "$ERR" "invalid CONFIRM_RUNS"
    confirm_conf 11
    run_script
    assert_rc 2
    assert_requests ""
}
