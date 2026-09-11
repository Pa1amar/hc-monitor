# Disk, memory, load and service checks; the /fail path.

test_ok_report_lists_all_checks() {
    run_script
    assert_rc 0
    assert_requests "POST /test-uuid"
    assert_contains "$BODY" "Disk /: 45% (inodes 12%)"
    assert_contains "$BODY" "RAM: 25% used of 7812 MiB"
    assert_contains "$BODY" "Load (1/5/15 min): 0.10 0.20 0.30, CPUs: 4"
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
