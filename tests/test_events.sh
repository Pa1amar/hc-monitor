# Events since the previous run: automatic restarts of watched units and OOM kills.

test_restart_since_last_check_is_a_problem() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'SERVICES="nginx"'
    printf 'nginx active\n' > "$STUB_DIR/services"
    printf 'nginx 5\n' > "$STUB_DIR/restarts"
    add_restarts_state . nginx 3
    run_script
    assert_rc 0
    assert_requests "POST /test-uuid/fail"
    assert_contains "$BODY" "- Service nginx: restarted 2 times since the last check"
    assert_contains "$ROOT_DIR/var/lib/hc-monitor/restarts.state" $'.\tnginx\t5'
}

test_single_restart() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'SERVICES="nginx"'
    printf 'nginx active\n' > "$STUB_DIR/services"
    printf 'nginx 5\n' > "$STUB_DIR/restarts"
    add_restarts_state . nginx 4
    run_script --dry-run
    assert_contains "$OUT" "- Service nginx: restarted 1 time since the last check"
}

test_first_run_and_reset_counter_only_record_a_baseline() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'SERVICES="nginx"'
    printf 'nginx active\n' > "$STUB_DIR/services"
    printf 'nginx 5\n' > "$STUB_DIR/restarts"
    run_script
    assert_requests "POST /test-uuid"
    assert_contains "$ROOT_DIR/var/lib/hc-monitor/restarts.state" $'.\tnginx\t5'
    printf 'nginx 0\n' > "$STUB_DIR/restarts"   # a manual restart resets the counter
    set_cpu_state 300 8600 7250 100 0           # the fake /proc/stat doesn't move between the runs
    : > "$SERVER_DIR/requests.log"
    run_script
    assert_requests "POST /test-uuid"
    assert_contains "$ROOT_DIR/var/lib/hc-monitor/restarts.state" $'.\tnginx\t0'
}

test_dry_run_keeps_restart_state() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'SERVICES="nginx"'
    printf 'nginx active\n' > "$STUB_DIR/services"
    printf 'nginx 5\n' > "$STUB_DIR/restarts"
    add_restarts_state . nginx 3
    run_script --dry-run
    assert_contains "$OUT" "- Service nginx: restarted 2 times since the last check"
    assert_contains "$ROOT_DIR/var/lib/hc-monitor/restarts.state" $'.\tnginx\t3'
    assert_not_contains "$ROOT_DIR/var/lib/hc-monitor/restarts.state" $'.\tnginx\t5'
}

test_restart_is_reported_to_every_check_watching_the_unit() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'SERVICES="nym-node"'
    add_service nym "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/svc-uuid\"" 'SERVICES="nym-node"'
    printf 'nym-node active\n' > "$STUB_DIR/services"
    printf 'nym-node 2\n' > "$STUB_DIR/restarts"
    add_restarts_state . nym-node 1
    add_restarts_state nym nym-node 1
    run_script
    assert_rc 0
    assert_requests $'POST /svc-uuid/fail\nPOST /test-uuid/fail'
    assert_contains "$(body_of /svc-uuid/fail)" "- Service nym-node: restarted 1 time since the last check"
    assert_contains "$(body_of /test-uuid/fail)" "- Service nym-node: restarted 1 time since the last check"
    assert_contains "$ROOT_DIR/var/lib/hc-monitor/restarts.state" $'.\tnym-node\t2'
    assert_contains "$ROOT_DIR/var/lib/hc-monitor/restarts.state" $'nym\tnym-node\t2'
}

test_restart_of_a_service_without_own_check_goes_into_server_report() {
    add_service web 'SERVICES="nginx"'
    printf 'nginx active\n' > "$STUB_DIR/services"
    printf 'nginx 3\n' > "$STUB_DIR/restarts"
    add_restarts_state web nginx 1
    run_script
    assert_rc 0
    assert_requests "POST /test-uuid/fail"
    assert_contains "$BODY" "- [web] Service nginx: restarted 2 times since the last check"
    assert_contains "$ROOT_DIR/var/lib/hc-monitor/restarts.state" $'web\tnginx\t3'
}

test_oom_kills_since_last_check() {
    local state="$ROOT_DIR/var/lib/hc-monitor/oom.state" since
    set_oom_state 300 2
    since=$(cut -d ' ' -f 1 "$state")
    set_oom_kills 4
    printf '%s\n' \
        'Out of memory: Killed process 1234 (nym-node) total-vm:4000000kB, anon-rss:3000000kB' \
        'oom_reaper: reaped process 1234 (nym-node), now anon-rss:0kB, file-rss:0kB' \
        'Memory cgroup out of memory: Killed process 99 (python3) total-vm:1000kB' > "$STUB_DIR/journal.out"
    run_script
    assert_rc 0
    assert_requests "POST /test-uuid/fail"
    assert_contains "$BODY" "- OOM killer: killed 2 processes since the last check: nym-node (1234), python3 (99)"
    assert_contains "$CALLS" "journalctl -k -q --no-pager -o cat --since @$since"
    grep -qE '^[0-9]+ 4 vmstat$' "$state" || fail "oom.state must hold this run's count: $(cat "$state")"
}

test_oom_kill_without_names() {
    set_oom_state 300 2
    set_oom_kills 3
    run_script --dry-run
    assert_contains "$OUT" "- OOM killer: killed 1 process since the last check"
    assert_not_contains "$OUT" "since the last check:"
}

test_oom_first_run_and_reboot_only_record_a_baseline() {
    local state="$ROOT_DIR/var/lib/hc-monitor/oom.state"
    set_oom_kills 7
    run_script
    assert_requests "POST /test-uuid"
    grep -qE '^[0-9]+ 7 vmstat$' "$state" || fail "oom.state after the first run: $(cat "$state")"
    set_oom_kills 0                             # the counter starts over after a reboot
    set_cpu_state 300 8600 7250 100 0           # the fake /proc/stat doesn't move between the runs
    : > "$SERVER_DIR/requests.log"
    run_script
    assert_requests "POST /test-uuid"
    grep -qE '^[0-9]+ 0 vmstat$' "$state" || fail "oom.state after the reboot: $(cat "$state")"
}

test_missing_oom_counter_is_a_problem() {
    printf 'nr_free_pages 1\n' > "$ROOT_DIR/proc/vmstat"
    run_script --dry-run
    assert_contains "$OUT" "- OOM: cannot determine (no oom_kill in /proc/vmstat)"
}

test_dry_run_keeps_oom_state() {
    local state="$ROOT_DIR/var/lib/hc-monitor/oom.state"
    set_oom_state 300 2
    set_oom_kills 3
    run_script --dry-run
    assert_contains "$OUT" "- OOM killer: killed 1 process since the last check"
    grep -qE '^[0-9]+ 2$' "$state" || fail "a dry run must not change oom.state: $(cat "$state")"
}

test_oom_in_a_container_ignores_the_hosts_kills() {
    # In LXC /proc/vmstat is the host's: its oom_kill counts the kills in every container.
    local state="$ROOT_DIR/var/lib/hc-monitor/oom.state"
    set_cgroup_oom_kills 0
    set_oom_state 300 0 cgroup
    set_oom_kills 112
    run_script
    assert_rc 0
    assert_requests "POST /test-uuid"
    grep -qE '^[0-9]+ 0 cgroup$' "$state" || fail "oom.state must hold the container's count: $(cat "$state")"
}

test_oom_kill_in_a_container_is_reported() {
    set_cgroup_oom_kills 1
    set_oom_state 300 0 cgroup
    set_oom_kills 112
    run_script --dry-run
    assert_contains "$OUT" "- OOM killer: killed 1 process since the last check"
}

test_oom_counter_change_only_records_a_baseline() {
    # A state saved from the host's counter by a version that read /proc/vmstat in a container.
    local state="$ROOT_DIR/var/lib/hc-monitor/oom.state"
    set_oom_state 300 5
    set_cgroup_oom_kills 9
    run_script
    assert_requests "POST /test-uuid"
    grep -qE '^[0-9]+ 9 cgroup$' "$state" || fail "oom.state after switching the counter: $(cat "$state")"
}

test_oom_in_a_cgroup_v1_container() {
    echo lxc > "$STUB_DIR/virt"
    mkdir -p "$ROOT_DIR/sys/fs/cgroup/memory"
    printf 'oom_kill_disable 0
under_oom 0
oom_kill 3
' > "$ROOT_DIR/sys/fs/cgroup/memory/memory.oom_control"
    set_oom_state 300 1 cgroup
    set_oom_kills 112
    run_script --dry-run
    assert_contains "$OUT" "- OOM killer: killed 2 processes since the last check"
}

test_cgroup_v1_counter_is_not_used_outside_a_container() {
    # On a server the root memory cgroup doesn't stand for the whole system; /proc/vmstat does.
    mkdir -p "$ROOT_DIR/sys/fs/cgroup/memory"
    printf 'oom_kill_disable 0
under_oom 0
oom_kill 0
' > "$ROOT_DIR/sys/fs/cgroup/memory/memory.oom_control"
    set_oom_state 300 2 vmstat
    set_oom_kills 3
    run_script --dry-run
    assert_contains "$OUT" "- OOM killer: killed 1 process since the last check"
}

test_container_without_oom_counter_is_a_problem() {
    echo lxc > "$STUB_DIR/virt"
    run_script --dry-run
    assert_contains "$OUT" "- OOM: cannot determine (no oom_kill in the container's memory cgroup)"
}
