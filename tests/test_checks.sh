# Disk, memory, load, CPU, service and port checks; the /fail path.

test_ok_report_lists_all_checks() {
    run_script
    assert_rc 0
    assert_requests "POST /test-uuid"
    assert_contains "$BODY" "Disk /: 45% (inodes 12%)"
    assert_contains "$BODY" "RAM: 25% used of 7812 MiB"
    assert_contains "$BODY" "Load (1/5/15 min): 0.10 0.20 0.30, CPUs: 4"
    assert_contains "$BODY" "CPU: 25% busy over 5 min (steal 0%, iowait 0%)"
    assert_contains "$BODY" "Services: none"
}

test_problem_goes_to_fail_url() {
    set_df ' 95%   12% ext4     /'
    run_script
    assert_rc 0
    assert_requests "POST /test-uuid/fail"
    assert_contains "$BODY" "PROBLEMS (1):"
    assert_contains "$BODY" "- Disk /: 95% used (threshold 90%)"
    assert_contains "$OUT" "PROBLEMS: Disk /: 95% used (threshold 90%) (report sent to /fail)"
}

test_disk_and_inodes_over_threshold() {
    set_df ' 50%   95% ext4     /' ' 91%   10% xfs      /var/lib'
    run_script --dry-run
    assert_contains "$OUT" "Ping URL: http://127.0.0.1:$SERVER_PORT/test-uuid/fail"
    assert_contains "$OUT" "PROBLEMS (2):"
    assert_contains "$OUT" "- Inodes /: 95% used (threshold 90%)"
    assert_contains "$OUT" "- Disk /var/lib: 91% used (threshold 90%)"
}

test_disk_threshold_is_inclusive() {
    set_df ' 90%    1% ext4     /'
    run_script --dry-run
    assert_contains "$OUT" "- Disk /: 90% used (threshold 90%)"
}

test_service_filesystems_are_ignored() {
    set_df ' 45%      - vfat     /boot/efi' \
        '100%   100% squashfs /snap/core/1' \
        '100%     1% tmpfs    /run/user/0' \
        '100%      - overlay  /var/lib/docker/overlay2/x/merged' \
        '100%      - iso9660  /media/cdrom' \
        ' 30%     5% devtmpfs /dev' \
        ' 45%    12% ext4     /'
    run_script --dry-run
    assert_contains "$OUT" "All good"
    assert_contains "$OUT" "Disk /boot/efi: 45%"
    assert_not_contains "$OUT" "/snap/core"
    assert_not_contains "$OUT" "/run/user"
    assert_not_contains "$OUT" "/media/cdrom"
}

test_mount_point_with_spaces() {
    set_df ' 95%     1% ext4     /mnt/my disk'
    run_script --dry-run
    assert_contains "$OUT" "- Disk /mnt/my disk: 95% used (threshold 90%)"
}

test_df_is_called_for_local_filesystems() {
    run_script --dry-run
    assert_contains "$CALLS" "df -l --output=pcent,ipcent,fstype,target"
}

test_df_timeout_is_a_problem() {
    echo 15 > "$STUB_DIR/df.sleep"
    run_script --dry-run
    assert_contains "$OUT" "- Disk: df did not respond within 10 s"
}

test_df_error_is_a_problem_but_output_is_used() {
    echo 1 > "$STUB_DIR/df.rc"
    run_script --dry-run
    assert_contains "$OUT" "- Disk: df failed (exit code 1)"
    assert_contains "$OUT" "Disk /: 45% (inodes 12%)"
}

test_df_without_data_is_a_problem() {
    set_df
    run_script --dry-run
    assert_contains "$OUT" "- Disk: df returned no data"
}

test_memory_over_threshold() {
    printf 'MemTotal: 1000000 kB\nMemAvailable: 50000 kB\n' > "$ROOT_DIR/proc/meminfo"
    run_script --dry-run
    assert_contains "$OUT" "- RAM: 95% used (threshold 90%)"
}

test_memory_without_memavailable_is_a_problem() {
    printf 'MemTotal: 1000000 kB\nMemFree: 50000 kB\n' > "$ROOT_DIR/proc/meminfo"
    run_script --dry-run
    assert_contains "$OUT" "- RAM: cannot determine (no MemAvailable/MemTotal in /proc/meminfo)"
}

test_load_over_threshold() {
    echo "9.00 9.50 9.10 3/200 999" > "$ROOT_DIR/proc/loadavg"
    run_script --dry-run
    assert_contains "$OUT" "- Load: load15 9.10 on 4 CPUs (threshold 8)"
}

test_fractional_load_threshold() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'LOAD_MAX_PER_CPU="1.5"'
    echo "1.00 1.00 5.99 1/100 1" > "$ROOT_DIR/proc/loadavg"
    run_script --dry-run
    assert_contains "$OUT" "All good"
    echo "1.00 1.00 6.00 1/100 1" > "$ROOT_DIR/proc/loadavg"
    run_script --dry-run
    assert_contains "$OUT" "- Load: load15 6.00 on 4 CPUs (threshold 6)"
}

test_unreadable_load_is_a_problem() {
    rm "$ROOT_DIR/proc/loadavg"
    run_script --dry-run
    assert_contains "$OUT" "- Load: cannot determine"
}

test_service_states() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" \
        'SERVICES="nginx cron postgresql ngnix"'
    printf 'nginx active\ncron reloading\npostgresql failed\n' > "$STUB_DIR/services"
    run_script --dry-run
    assert_contains "$OUT" "PROBLEMS (2):"
    assert_contains "$OUT" "- Service postgresql: failed"
    assert_contains "$OUT" "- Service ngnix: not found (check the name)"
    assert_contains "$OUT" "Services: nginx=active, cron=reloading, postgresql=failed, ngnix=not-found"
}

test_real_environment_report() {
    # Real df, nproc and /proc/loadavg; meminfo stays fake (WSL1 has no MemAvailable).
    rm "$T/bin/df" "$T/bin/nproc"
    ln -sf /proc/loadavg "$ROOT_DIR/proc/loadavg"
    run_script --dry-run
    assert_rc 0
    assert_contains "$OUT" "Disk /:"
    assert_contains "$OUT" "Load (1/5/15 min):"
    assert_not_contains "$OUT" "cannot determine"
    assert_not_contains "$OUT" "df failed"
    assert_not_contains "$OUT" "df returned no data"
}

test_no_ports_configured() {
    run_script --dry-run
    assert_contains "$OUT" "Ports: none"
}

test_listening_ports_ipv4_and_ipv6() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'PORTS="22 443"'
    set_listen tcp 22
    add_socket tcp6 00000000000000000000000000000000:01BB 0A   # [::]:443
    run_script --dry-run
    assert_contains "$OUT" "All good"
    assert_contains "$OUT" "Ports: 22/tcp=listening, 443/tcp=listening"
}

test_connected_socket_is_not_listening() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'PORTS="8080"'
    add_socket tcp 0100007F:1F90 01   # 127.0.0.1:8080, ESTABLISHED
    run_script --dry-run
    assert_contains "$OUT" "- Port 8080/tcp: not listening"
}

test_tcp_port_not_listening_goes_to_fail() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'PORTS="22 8080/tcp"'
    set_listen tcp 22
    run_script
    assert_rc 0
    assert_requests "POST /test-uuid/fail"
    assert_contains "$BODY" "- Port 8080/tcp: not listening"
    assert_contains "$BODY" "Ports: 22/tcp=listening, 8080/tcp=not-listening"
}

test_udp_ports() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'PORTS="53/udp 51820/udp"'
    set_listen udp 53
    add_socket udp 0100007F:CA6C 01   # a connected socket on 51820 does not count
    run_script --dry-run
    assert_contains "$OUT" "- Port 51820/udp: not listening"
    assert_contains "$OUT" "Ports: 53/udp=listening, 51820/udp=not-listening"
}

test_bare_port_means_tcp() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'PORTS="443"'
    set_listen udp 443
    run_script --dry-run
    assert_contains "$OUT" "- Port 443/tcp: not listening"
}

test_loopback_listener_counts() {
    # Any local address counts, loopback included (documented in the README).
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'PORTS="53/udp"'
    add_socket udp 3500007F:0035 07   # systemd-resolved on 127.0.0.53:53
    run_script --dry-run
    assert_contains "$OUT" "Ports: 53/udp=listening"
}

test_unreadable_tables_mark_ports_unknown() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'PORTS="22 443 53/udp"'
    rm "$ROOT_DIR/proc/net/tcp"
    : > "$ROOT_DIR/proc/net/udp"   # empty, without the kernel header, as in WSL1
    run_script --dry-run
    assert_contains "$OUT" "PROBLEMS (1):"
    assert_contains "$OUT" "- Ports: cannot read /proc/net/tcp, /proc/net/udp"
    assert_contains "$OUT" "Ports: 22/tcp=unknown, 443/tcp=unknown, 53/udp=unknown"
    assert_not_contains "$OUT" "not listening"
}

test_missing_ipv6_table_is_fine() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'PORTS="22"'
    set_listen tcp 22
    rm "$ROOT_DIR/proc/net/tcp6"
    run_script --dry-run
    assert_contains "$OUT" "All good"
    assert_contains "$OUT" "Ports: 22/tcp=listening"
}

test_duplicate_ports_are_checked_once() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'PORTS="443 443/tcp 22 22"'
    set_listen tcp 22
    run_script --dry-run
    assert_contains "$OUT" "PROBLEMS (1):"
    assert_contains "$OUT" "Ports: 443/tcp=not-listening, 22/tcp=listening"
}

test_multiline_lists_in_config() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'PORTS="22' '8080"' \
        'SERVICES="nginx' 'cron"'
    printf 'nginx active\ncron failed\n' > "$STUB_DIR/services"
    set_listen tcp 22
    run_script --dry-run
    assert_contains "$OUT" "- Port 8080/tcp: not listening"
    assert_contains "$OUT" "- Service cron: failed"
}

test_cpu_over_threshold() {
    set_cpu_state 300 8600 7950 100 0
    run_script --dry-run
    assert_contains "$OUT" "- CPU: 95% busy (threshold 90%)"
}

test_cpu_steal_counts_as_busy() {
    set_cpu 1000 0 500 8000 200 0 0 100
    set_cpu_state 300 8800 7500 100 0
    run_script --dry-run
    assert_contains "$OUT" "CPU: 40% busy over 5 min (steal 10%, iowait 10%)"
}

test_cpu_short_interval_in_seconds() {
    set_cpu_state 30 8600 7250 100 0
    run_script --dry-run
    grep -qE 'CPU: 25% busy over 3[0-2] s' "$OUT" || fail "expected an interval of about 30 s: $(cat "$OUT")"
}

test_cpu_without_previous_sample_measures_one_second() {
    rm "$ROOT_DIR/var/lib/hc-monitor/cpu.stat"
    use_sleep_stub 1050 0 550 8100 100 0 0 0
    run_script --dry-run
    assert_contains "$OUT" "CPU: 50% busy over 1 s (steal 0%, iowait 0%)"
}

test_cpu_stale_or_reset_sample_is_not_used() {
    use_sleep_stub 1050 0 550 8100 100 0 0 0
    set_cpu_state 3600 8600 7250 100 0          # older than 15 minutes
    run_script --dry-run
    assert_contains "$OUT" "CPU: 50% busy over 1 s"
    set_cpu 1000 0 500 8000 100 0 0 0
    set_cpu_state 300 99999 7250 100 0          # counters went back: the server rebooted
    run_script --dry-run
    assert_contains "$OUT" "CPU: 50% busy over 1 s"
}

test_cpu_average_over_a_long_interval() {
    # With checks every hour, a sample from 50 minutes ago is the previous run's, not a stale one.
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'INTERVAL="60"'
    set_cpu_state 3000 8600 7250 100 0
    run_script --dry-run
    assert_contains "$OUT" "CPU: 25% busy over 50 min"
}

test_cpu_without_ticks_is_a_problem() {
    rm "$ROOT_DIR/var/lib/hc-monitor/cpu.stat"
    use_sleep_stub 1000 0 500 8000 100 0 0 0   # the counters do not move
    run_script --dry-run
    assert_contains "$OUT" "- CPU: cannot determine (no CPU time counted)"
}

test_unreadable_proc_stat_is_a_problem() {
    rm "$ROOT_DIR/proc/stat"
    run_script --dry-run
    assert_contains "$OUT" "- CPU: cannot read /proc/stat"
}

test_real_run_saves_cpu_sample() {
    run_script
    assert_rc 0
    assert_contains "$ROOT_DIR/var/lib/hc-monitor/cpu.stat" " 9600 8000 100 0"
}

test_dry_run_keeps_cpu_sample() {
    run_script --dry-run
    assert_contains "$ROOT_DIR/var/lib/hc-monitor/cpu.stat" " 8600 7250 100 0"
}
