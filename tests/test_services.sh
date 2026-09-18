# Services in <root home>/.healthchecks/<name>/.env: their own checks, the server report, HTTP checks,
# broken files.

test_service_with_own_check_sends_its_own_report() {
    set_listen tcp 22
    add_service nym "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/svc-uuid\"" 'PORTS="22"'
    run_script
    assert_rc 0
    assert_requests $'POST /svc-uuid\nPOST /test-uuid'
    local body
    body=$(body_of /svc-uuid)
    assert_contains "$body" "All good"
    assert_contains "$body" "Service: nym"
    assert_contains "$body" "Ports: 22/tcp=listening"
    assert_not_contains "$body" "Services: none"
    assert_not_contains "$body" "Disk"
    assert_not_contains "$(body_of /test-uuid)" "[nym]"
    grep -qx "OK: report sent" "$OUT" || fail "no log line for the server report: $(cat "$OUT")"
    grep -qx "\[nym\] OK: report sent" "$OUT" || fail "no log line for the service report: $(cat "$OUT")"
}

test_service_problem_goes_to_its_own_fail_url() {
    add_service nym "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/svc-uuid/\"" 'PORTS="8080"'
    run_script
    assert_rc 0
    assert_requests $'POST /svc-uuid/fail\nPOST /test-uuid'
    assert_contains "$(body_of /svc-uuid/fail)" "- Port 8080/tcp: not listening"
    assert_contains "$(body_of /test-uuid)" "All good"
    assert_contains "$OUT" "[nym] PROBLEMS: Port 8080/tcp: not listening (report sent to /fail)"
}

test_service_without_own_check_goes_into_server_report() {
    printf 'cron failed\n' > "$STUB_DIR/services"
    add_service nym 'SERVICES="cron"'
    run_script
    assert_rc 0
    assert_requests "POST /test-uuid/fail"
    assert_contains "$BODY" "- [nym] Service cron: failed"
    assert_contains "$BODY" "[nym] Services: cron=failed"
    assert_contains "$OUT" "PROBLEMS: [nym] Service cron: failed (report sent to /fail)"
}

test_http_check_expected_text_found() {
    set_response /health 200 '{"status": "up", "uptime": 5}'
    add_service web "HTTP_URL=\"http://127.0.0.1:$SERVER_PORT/health\"" "HTTP_EXPECT='\"status\" *: *\"up\"'"
    run_script --dry-run
    assert_rc 0
    assert_contains "$OUT" "All good"
    assert_contains "$OUT" "[web] HTTP http://127.0.0.1:$SERVER_PORT/health: 200, expected text found"
}

test_http_check_expected_text_not_found() {
    set_response /health 200 '{"status": "down"}'
    add_service web "HTTP_URL=\"http://127.0.0.1:$SERVER_PORT/health\"" "HTTP_EXPECT='\"status\" *: *\"up\"'"
    run_script --dry-run
    assert_contains "$OUT" "- [web] HTTP http://127.0.0.1:$SERVER_PORT/health: expected text not found"
    assert_contains "$OUT" "[web] HTTP http://127.0.0.1:$SERVER_PORT/health: 200, expected text not found"
}

test_http_check_error_status() {
    set_response /health 503 'maintenance'
    add_service web "HTTP_URL=\"http://127.0.0.1:$SERVER_PORT/health\""
    run_script --dry-run
    assert_contains "$OUT" "- [web] HTTP http://127.0.0.1:$SERVER_PORT/health: status 503"
}

test_http_check_connection_failed() {
    add_service web 'HTTP_URL="http://127.0.0.1:9/health"'
    run_script --dry-run
    assert_contains "$OUT" "- [web] HTTP http://127.0.0.1:9/health: connection failed"
}

test_http_check_without_expect_accepts_any_2xx() {
    set_response /health 200 'anything'
    add_service web "HTTP_URL=\"http://127.0.0.1:$SERVER_PORT/health\""
    run_script --dry-run
    assert_contains "$OUT" "All good"
    grep -qx "\[web\] HTTP http://127.0.0.1:$SERVER_PORT/health: 200" "$OUT" ||
        fail "no HTTP summary line: $(cat "$OUT")"
}

test_invalid_service_file_is_a_server_problem() {
    set_listen tcp 22
    add_service bad 'PORTS="22 db.local:5432"'
    add_service good 'PORTS="22"'
    run_script
    assert_rc 0
    assert_requests "POST /test-uuid/fail"
    assert_contains "$BODY" "- Service bad: invalid port: db.local:5432"
    assert_contains "$BODY" "[good] Ports: 22/tcp=listening"
}

test_service_file_errors() {
    add_service a-empty 'HC_PING_URL=""'
    add_service b-broken 'PORTS="22'
    add_service c-unset 'PORTS="$NOT_SET"'
    add_service d-expect 'PORTS="22"' "HTTP_EXPECT='up'"
    add_service e-regex "HTTP_URL=\"http://127.0.0.1:$SERVER_PORT/health\"" "HTTP_EXPECT='(up'"
    add_service f-same "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid/\"" 'PORTS="22"'
    add_service g-url 'HTTP_URL="ftp://x"'
    add_service "h bad name" 'PORTS="22"'
    run_script --dry-run
    assert_rc 0
    assert_contains "$OUT" "- Service a-empty: nothing to check (set SERVICES, PORTS, CERTS or HTTP_URL)"
    assert_contains "$OUT" "- Service b-broken: cannot load /root/.healthchecks/b-broken/.env"
    assert_contains "$OUT" "- Service c-unset: cannot load /root/.healthchecks/c-unset/.env"
    assert_contains "$OUT" "- Service d-expect: HTTP_EXPECT is set without HTTP_URL"
    assert_contains "$OUT" "- Service e-regex: invalid HTTP_EXPECT (not a regular expression)"
    assert_contains "$OUT" "- Service f-same: HC_PING_URL is the server's ping URL (create a separate check)"
    assert_contains "$OUT" "- Service g-url: invalid HTTP_URL"
    assert_contains "$OUT" "- Service \"h bad name\": invalid name (use letters, digits, '.', '_' and '-')"
}

test_unsafe_service_file_is_not_loaded() {
    add_service open "touch '$T/sourced'" 'PORTS="22"'
    chmod 666 "$ROOT_DIR/root/.healthchecks/open/.env"
    add_service opendir 'PORTS="22"'
    chmod 777 "$ROOT_DIR/root/.healthchecks/opendir"
    run_script --dry-run
    assert_contains "$OUT" "- Service open: unsafe permissions on /root/.healthchecks/open/.env (it must be owned by root and not writable by group or others)"
    assert_contains "$OUT" "- Service opendir: unsafe permissions on /root/.healthchecks/opendir (it must be owned by root and not writable by group or others)"
    [[ ! -e $T/sourced ]] || fail "a file with unsafe permissions was sourced"
}

test_service_settings_do_not_leak() {
    set_listen tcp 22
    printf 'cron active\n' > "$STUB_DIR/services"
    add_service a "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/svc-a\"" 'PORTS="22"' 'DISK_MAX_PCT="1"'
    add_service b 'SERVICES="cron"'
    run_script
    assert_rc 0
    assert_requests $'POST /svc-a\nPOST /test-uuid'
    assert_contains "$(body_of /test-uuid)" "All good"
    assert_contains "$(body_of /test-uuid)" "Ports: none"
    assert_contains "$(body_of /test-uuid)" "[b] Services: cron=active"
}

test_failed_report_does_not_stop_the_others() {
    set_listen tcp 22
    set_response /svc-uuid 404
    add_service nym "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/svc-uuid\"" 'PORTS="22"'
    run_script
    assert_rc 1
    assert_requests $'POST /svc-uuid\nPOST /test-uuid'
    assert_contains "$ERR" "Error: [nym] failed to send the report (curl exit code 22)"
    grep -qx "OK: report sent" "$OUT" || fail "the server report must still be sent: $(cat "$OUT")"
}

test_dry_run_prints_every_report() {
    add_service nym "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/svc-uuid\"" 'PORTS="8080"'
    run_script --dry-run
    assert_rc 0
    assert_requests ""
    assert_contains "$OUT" "Ping URL: http://127.0.0.1:$SERVER_PORT/test-uuid"
    assert_contains "$OUT" "Ping URL: http://127.0.0.1:$SERVER_PORT/svc-uuid/fail"
    assert_contains "$OUT" "Service: nym"
}

test_directory_without_env_is_ignored() {
    mkdir -p "$ROOT_DIR/root/.healthchecks/notes"
    run_script --dry-run
    assert_contains "$OUT" "All good"
    assert_not_contains "$OUT" "notes"
}

# add asks, in order: ping URL -> services -> ports -> certificates -> health check URL ->
# [expected text, only when there is a URL]. A here-string adds a final newline, which answers the
# last question with Enter.

test_add_creates_service_file() {
    local cert
    cert="localhost:$(tls_port good)"
    printf 'nym-node active\n' > "$STUB_DIR/services"
    set_listen tcp 1789
    set_response /health 200 '{"status":"up"}'
    INPUT="http://127.0.0.1:$SERVER_PORT/svc-uuid/"$'\nnym-node\n1789\n'"$cert"$'\n'"http://127.0.0.1:$SERVER_PORT/health"$'\n"status" *: *"up"'
    run_script add nym
    assert_rc 0
    local dir="$ROOT_DIR/root/.healthchecks/nym"
    assert_mode "$ROOT_DIR/root/.healthchecks" 700
    assert_mode "$dir" 700
    assert_mode "$dir/.env" 600
    assert_contains "$dir/.env" "HC_PING_URL='http://127.0.0.1:$SERVER_PORT/svc-uuid'"
    assert_contains "$dir/.env" "SERVICES='nym-node'"
    assert_contains "$dir/.env" "PORTS='1789'"
    assert_contains "$dir/.env" "CERTS='$cert'"
    assert_contains "$dir/.env" "HTTP_URL='http://127.0.0.1:$SERVER_PORT/health'"
    assert_contains "$dir/.env" "HTTP_EXPECT='\"status\" *: *\"up\"'"
    assert_contains "$OUT" "Ping URL: http://127.0.0.1:$SERVER_PORT/svc-uuid"
    assert_contains "$OUT" "TLS $cert: valid until"
    assert_contains "$OUT" "HTTP http://127.0.0.1:$SERVER_PORT/health: 200, expected text found"
    assert_contains "$OUT" "Period 5 minutes, Grace Time 10 minutes"
    run_script --dry-run
    assert_contains "$OUT" "Ping URL: http://127.0.0.1:$SERVER_PORT/svc-uuid"
    assert_contains "$OUT" "Service: nym"
}

test_add_again_keeps_values() {
    printf 'cron active\n' > "$STUB_DIR/services"
    add_service nym "HC_PING_URL='http://127.0.0.1:1/svc'" "SERVICES='cron'" "PORTS='22'" \
        "CERTS='localhost:9'" "HTTP_URL='http://127.0.0.1:9/health'" "HTTP_EXPECT='\"status\" *: *\"up\"'"
    INPUT=$'\n\n\n\n\n'
    run_script add nym
    assert_rc 0
    local env="$ROOT_DIR/root/.healthchecks/nym/.env"
    assert_contains "$env" "HC_PING_URL='http://127.0.0.1:1/svc'"
    assert_contains "$env" "SERVICES='cron'"
    assert_contains "$env" "PORTS='22'"
    assert_contains "$env" "CERTS='localhost:9'"
    assert_contains "$env" "HTTP_URL='http://127.0.0.1:9/health'"
    assert_contains "$env" "HTTP_EXPECT='\"status\" *: *\"up\"'"
}

test_add_shows_the_configured_interval() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'INTERVAL="1"'
    add_service nym "HC_PING_URL='http://127.0.0.1:1/svc'" "PORTS='22'"
    INPUT=$'\n\n\n\n'   # URL, services, ports, certificates; health URL: Enter
    run_script add nym
    assert_rc 0
    assert_contains "$OUT" "the next run (within 1 minute) checks it."
    assert_contains "$OUT" "Period 1 minute, Grace Time 2 minutes."
}

test_add_requires_something_to_check() {
    printf 'cron active\n' > "$STUB_DIR/services"
    add_service nym "PORTS='22'"
    # URL, services: Enter; ports: "-"; certificates: Enter; health URL: "-" -> nothing to check ->
    # services: cron; ports, certificates and health URL: Enter
    INPUT=$'\n\n-\n\n-\ncron\n\n\n'
    run_script add nym
    assert_rc 0
    assert_contains "$ERR" "Nothing to check: set at least one service, port, certificate or health check URL."
    assert_contains "$ROOT_DIR/root/.healthchecks/nym/.env" "SERVICES='cron'"
    assert_contains "$ROOT_DIR/root/.healthchecks/nym/.env" "PORTS=''"
}

test_add_rejects_invalid_answers() {
    printf 'cron active\n' > "$STUB_DIR/services"
    INPUT="http://127.0.0.1:$SERVER_PORT/test-uuid"$'\nftp://x\nhttp://127.0.0.1:1/svc\ncron\n\n\nhttp://127.0.0.1:9/health\n(up\nup'
    run_script add nym
    assert_rc 0
    [[ $(grep -c "of a separate check (not the server's)" "$ERR") == 2 ]] ||
        fail "the server's URL and ftp:// must both be rejected: $(cat "$ERR")"
    assert_contains "$ERR" "Expected a single-line regular expression"
    assert_contains "$ROOT_DIR/root/.healthchecks/nym/.env" "HC_PING_URL='http://127.0.0.1:1/svc'"
    assert_contains "$ROOT_DIR/root/.healthchecks/nym/.env" "HTTP_EXPECT='up'"
}

test_add_and_remove_check_the_name() {
    run_script add "bad name"
    assert_rc 2
    assert_contains "$ERR" "invalid service name: bad name"
    run_script remove ../etc
    assert_rc 2
    run_script add
    assert_rc 2
    assert_contains "$ERR" "Usage:"
}

test_remove_service() {
    add_service nym "HC_PING_URL='http://127.0.0.1:1/svc'" "PORTS='22'"
    INPUT=$'n\n'
    run_script remove nym
    assert_rc 0
    assert_contains "$OUT" "Cancelled."
    [[ -e $ROOT_DIR/root/.healthchecks/nym/.env ]] || fail "the service was removed although the answer was n"
    INPUT=$'y\n'
    run_script remove nym
    assert_rc 0
    [[ ! -e $ROOT_DIR/root/.healthchecks/nym ]] || fail "the service directory is still there"
    assert_contains "$OUT" "Service nym removed."
    assert_contains "$OUT" "pause or delete it in healthchecks.io"
}

test_remove_unknown_service_exits_1() {
    run_script remove nope
    assert_rc 1
    assert_contains "$ERR" "no such service: nope"
}

test_uninstall_keeps_service_files() {
    INPUT=$'\n\n\n\n\n'
    run_script install
    assert_rc 0
    add_service nym "PORTS='22'"
    INPUT=$'y\n'
    run_script uninstall
    assert_rc 0
    [[ -e $ROOT_DIR/root/.healthchecks/nym/.env ]] || fail "uninstall removed a service file"
    assert_contains "$OUT" "Service files in /root/.healthchecks were kept (nym)"
}
