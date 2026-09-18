# TLS certificates in CERTS: the expiry and validity of what a host presents, checked against
# certificates from the test CA (see make_test_certs).

# cert_conf <entry>... — the server config with these CERTS.
cert_conf() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" "CERTS=\"$*\""
}

test_valid_certificate() {
    local port
    port=$(tls_port good)
    cert_conf "localhost:$port"
    run_script --dry-run
    assert_rc 0
    assert_contains "$OUT" "All good"
    grep -qE "^TLS localhost:$port: valid until [0-9]{4}-[0-9]{2}-[0-9]{2} \([0-9]+ days\)$" "$OUT" ||
        fail "no summary line for a valid certificate: $(cat "$OUT")"
}

test_certificate_expiring_soon() {
    local port
    port=$(tls_port soon)
    cert_conf "localhost:$port"
    run_script
    assert_rc 0
    assert_requests "POST /test-uuid/fail"
    grep -qE "^- TLS localhost:$port: certificate expires in 5 days \([0-9]{4}-[0-9]{2}-[0-9]{2}, threshold 14 days\)$" "$BODY" ||
        fail "no expiry problem: $(cat "$BODY")"
}

test_certificate_threshold_is_configurable() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" \
        "CERTS=\"localhost:$(tls_port soon)\"" 'CERT_MIN_DAYS="3"'
    run_script --dry-run
    assert_contains "$OUT" "All good"
    assert_contains "$OUT" "valid until"
}

test_expired_certificate() {
    local port
    port=$(tls_port expired)
    cert_conf "localhost:$port"
    run_script --dry-run
    assert_contains "$OUT" "- TLS localhost:$port: certificate expired on 2020-01-02"
    assert_contains "$OUT" "TLS localhost:$port: expired on 2020-01-02"
    assert_not_contains "$OUT" "not valid"
}

test_hostname_mismatch() {
    local port
    port=$(tls_port other)
    cert_conf "localhost:$port"
    run_script --dry-run
    grep -qiE "^- TLS localhost:$port: certificate not valid \(hostname mismatch\)$" "$OUT" ||
        fail "no hostname problem: $(cat "$OUT")"
}

test_self_signed_certificate() {
    local port
    port=$(tls_port self)
    cert_conf "localhost:$port"
    run_script --dry-run
    grep -qiE "^- TLS localhost:$port: certificate not valid \(self[- ]signed certificate\)$" "$OUT" ||
        fail "no trust problem: $(cat "$OUT")"
}

test_certificate_connection_failed() {
    cert_conf "localhost:9"
    run_script --dry-run
    assert_contains "$OUT" "- TLS localhost:9: connection failed"
}

test_certificate_default_port_is_443() {
    cert_conf "localhost"
    run_script --dry-run
    assert_contains "$OUT" "TLS localhost:443: "
}

test_invalid_certificate_settings_exit_2() {
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'CERTS="https://example.com"'
    run_script
    assert_rc 2
    assert_contains "$ERR" "invalid certificate entry in"
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'CERTS="example.com:70000"'
    run_script
    assert_rc 2
    write_conf "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/test-uuid\"" 'CERT_MIN_DAYS="0"'
    run_script
    assert_rc 2
    assert_contains "$ERR" "invalid CERT_MIN_DAYS"
    assert_requests ""
}

test_service_certificate_goes_to_its_own_check() {
    local port
    port=$(tls_port expired)
    add_service gw "HC_PING_URL=\"http://127.0.0.1:$SERVER_PORT/svc-uuid\"" "CERTS=\"localhost:$port\""
    run_script
    assert_rc 0
    assert_requests $'POST /svc-uuid/fail\nPOST /test-uuid'
    assert_contains "$(body_of /svc-uuid/fail)" "- TLS localhost:$port: certificate expired on 2020-01-02"
    assert_not_contains "$(body_of /test-uuid)" "TLS"
}

test_invalid_certificate_entry_in_service_file() {
    add_service gw 'CERTS="gw.example.com:0"'
    run_script --dry-run
    assert_contains "$OUT" "- Service gw: invalid certificate entry: gw.example.com:0"
}
