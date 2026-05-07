#!/usr/bin/env bats
# Tests for scripts/policy/check-extended-settings.sh.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../check-extended-settings.sh"
    [[ -x "$SCRIPT" ]] || skip "check-extended-settings.sh not executable"
    CFG="$BATS_TEST_TMPDIR/config"
    mkdir -p "$CFG/base" "$CFG/dev"
    CATALOG_TXT="$BATS_TEST_TMPDIR/catalog.txt"
    cat > "$CATALOG_TXT" <<EOF
watt.server.threadPool
watt.server.threadPoolMin
watt.server.transactionTimeoutSecs
watt.net.timeout
watt.net.maxClientKeepaliveConns
watt.server.auditLog.policy
watt.server.audit.logRotateSize
watt.server.stats.pollTime
watt.server.stats.logFile.enabled
watt.server.errorMail
watt.debug.level
EOF
    CATALOG_JSON="$BATS_TEST_TMPDIR/catalog.json"
    cat > "$CATALOG_JSON" <<'JSON'
{
  "keys": [
    "watt.server.threadPool",
    "watt.server.threadPoolMin",
    "watt.net.timeout",
    "watt.debug.level"
  ]
}
JSON
}

# ---- passing fixture -------------------------------------------------

@test "passes when every key is in the catalog (text catalog)" {
    cat > "$CFG/base/extended-settings.properties" <<'EOF'
# OK keys only
watt.server.threadPool=120
watt.net.timeout=300
watt.debug.level=Info
EOF
    run "$SCRIPT" --config-dir "$CFG" --catalog "$CATALOG_TXT"
    [ "$status" -eq 0 ]
    [[ "$output" == *PASS:* ]]
}

@test "passes with JSON-format catalog" {
    cat > "$CFG/base/extended-settings.properties" <<'EOF'
watt.server.threadPool=120
watt.net.timeout=300
EOF
    run "$SCRIPT" --config-dir "$CFG" --catalog "$CATALOG_JSON"
    [ "$status" -eq 0 ]
}

@test "comments and blank lines are ignored" {
    cat > "$CFG/base/extended-settings.properties" <<'EOF'
# Watt server tuning

watt.server.threadPool=120
   # indented comment
watt.net.timeout=300

EOF
    run "$SCRIPT" --config-dir "$CFG" --catalog "$CATALOG_TXT"
    [ "$status" -eq 0 ]
}

@test "--properties checks a single file directly" {
    cat > "$CFG/base/extended-settings.properties" <<'EOF'
watt.server.threadPool=120
EOF
    run "$SCRIPT" --properties "$CFG/base/extended-settings.properties" \
                  --catalog "$CATALOG_TXT"
    [ "$status" -eq 0 ]
}

# ---- failing fixture -------------------------------------------------

@test "fails when an unknown key is present" {
    cat > "$CFG/base/extended-settings.properties" <<'EOF'
watt.server.threadPool=120
watt.server.bogusInvented=1
EOF
    run "$SCRIPT" --config-dir "$CFG" --catalog "$CATALOG_TXT"
    [ "$status" -eq 2 ]
    [[ "$output" == *bogusInvented* ]] || true
}

@test "reports each unknown key (no early exit)" {
    cat > "$CFG/base/extended-settings.properties" <<'EOF'
watt.first.unknown=1
watt.second.unknown=2
watt.server.threadPool=120
EOF
    run "$SCRIPT" --config-dir "$CFG" --catalog "$CATALOG_TXT"
    [ "$status" -eq 2 ]
    [[ "$output" == *first.unknown* ]] || true
    [[ "$output" == *second.unknown* ]] || true
}

@test "scans overlay files in addition to base" {
    cat > "$CFG/base/extended-settings.properties" <<'EOF'
watt.server.threadPool=120
EOF
    cat > "$CFG/dev/extended-settings.properties" <<'EOF'
watt.dev.invented=1
EOF
    run "$SCRIPT" --config-dir "$CFG" --catalog "$CATALOG_TXT"
    [ "$status" -eq 2 ]
    [[ "$output" == *dev.invented* ]] || true
}

# ---- allowlist ------------------------------------------------------

@test "--allow exempts a single custom key" {
    cat > "$CFG/base/extended-settings.properties" <<'EOF'
watt.server.threadPool=120
watt.corp.featureFlag=true
EOF
    run "$SCRIPT" --config-dir "$CFG" --catalog "$CATALOG_TXT" \
                  --allow watt.corp.featureFlag
    [ "$status" -eq 0 ]
}

@test "POLICY_SETTINGS_ALLOW env var also exempts" {
    cat > "$CFG/base/extended-settings.properties" <<'EOF'
watt.server.threadPool=120
watt.corp.A=1
watt.corp.B=2
EOF
    POLICY_SETTINGS_ALLOW="watt.corp.A watt.corp.B" \
        run "$SCRIPT" --config-dir "$CFG" --catalog "$CATALOG_TXT"
    [ "$status" -eq 0 ]
}

# ---- argument validation --------------------------------------------

@test "no extended-settings files = vacuous pass" {
    run "$SCRIPT" --config-dir "$CFG" --catalog "$CATALOG_TXT"
    [ "$status" -eq 0 ]
}

@test "fails setup error on missing config-dir" {
    run "$SCRIPT" --config-dir "$BATS_TEST_TMPDIR/nope" --catalog "$CATALOG_TXT"
    [ "$status" -eq 1 ]
}

@test "fails setup error on empty catalog" {
    : > "$BATS_TEST_TMPDIR/empty.txt"
    cat > "$CFG/base/extended-settings.properties" <<'EOF'
watt.server.threadPool=120
EOF
    run "$SCRIPT" --config-dir "$CFG" --catalog "$BATS_TEST_TMPDIR/empty.txt"
    [ "$status" -eq 1 ]
}

@test "fails setup error when no catalog source is reachable" {
    cat > "$CFG/base/extended-settings.properties" <<'EOF'
watt.server.threadPool=120
EOF
    run "$SCRIPT" --config-dir "$CFG" --mcp-cmd /usr/bin/false-binary-that-does-not-exist
    [ "$status" -eq 1 ]
}
