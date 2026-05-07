#!/usr/bin/env bats
# Tests for scripts/policy/check-manifests.sh.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../check-manifests.sh"
    [[ -x "$SCRIPT" ]] || skip "check-manifests.sh not executable"
    PKG_DIR="$BATS_TEST_TMPDIR/packages"
    mkdir -p "$PKG_DIR"
}

# write_manifest PACKAGE FILE_BODY
write_manifest() {
    local name=$1; shift
    mkdir -p "$PKG_DIR/$name"
    printf '%s\n' "$@" > "$PKG_DIR/$name/manifest.v3"
}

# ---- passing fixtures -----------------------------------------------

@test "passes with version + description + startup_service" {
    write_manifest OrderService '<?xml version="1.0"?>' \
        '<Manifest>' \
        '  <version>1.0.0</version>' \
        '  <description>Order microservice flows</description>' \
        '  <startup_services>' \
        '    <service>orders.startup:init</service>' \
        '  </startup_services>' \
        '</Manifest>'
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *PASS:* ]]
}

@test "passes with explicit <no-startup-needed/> marker" {
    write_manifest UtilService '<?xml version="1.0"?>' \
        '<Manifest>' \
        '  <version>2.1.0</version>' \
        '  <description>Pure-utility helpers, no startup needed.</description>' \
        '  <no-startup-needed/>' \
        '</Manifest>'
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 0 ]
}

@test "passes with snake-case <no_startup_needed/> alias" {
    write_manifest UtilService '<?xml version="1.0"?>' \
        '<Manifest>' \
        '  <version>2.1.0</version>' \
        '  <description>Helpers</description>' \
        '  <no_startup_needed/>' \
        '</Manifest>'
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 0 ]
}

@test "passes with top-level <startup_service> sibling of <description>" {
    write_manifest LegacySvc '<?xml version="1.0"?>' \
        '<Manifest>' \
        '  <version>0.1.0</version>' \
        '  <description>Legacy IS export style</description>' \
        '  <startup_service>legacy.startup:init</startup_service>' \
        '</Manifest>'
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 0 ]
}

@test "passes with legacy <package_version> + <Description>" {
    write_manifest LegacyShape '<?xml version="1.0"?>' \
        '<Manifest>' \
        '  <package_version>3.0.0</package_version>' \
        '  <Description>Legacy capitalised description</Description>' \
        '  <no-startup-needed/>' \
        '</Manifest>'
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 0 ]
}

# ---- failing fixtures -----------------------------------------------

@test "fails when <version> is missing" {
    write_manifest BrokenSvc '<?xml version="1.0"?>' \
        '<Manifest>' \
        '  <description>Missing version</description>' \
        '  <no-startup-needed/>' \
        '</Manifest>'
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *version* ]] || true
}

@test "fails when <version> is empty" {
    write_manifest BrokenSvc '<?xml version="1.0"?>' \
        '<Manifest>' \
        '  <version></version>' \
        '  <description>Empty version</description>' \
        '  <no-startup-needed/>' \
        '</Manifest>'
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 2 ]
}

@test "fails when <description> is missing" {
    write_manifest BrokenSvc '<?xml version="1.0"?>' \
        '<Manifest>' \
        '  <version>1.0.0</version>' \
        '  <no-startup-needed/>' \
        '</Manifest>'
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 2 ]
}

@test "fails when neither <startup_service> nor <no-startup-needed/> is present" {
    write_manifest BrokenSvc '<?xml version="1.0"?>' \
        '<Manifest>' \
        '  <version>1.0.0</version>' \
        '  <description>Forgot to declare startup intent</description>' \
        '</Manifest>'
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *startup* ]] || true
}

@test "fails on malformed XML" {
    mkdir -p "$PKG_DIR/Broken"
    printf '<Manifest><version>1.0.0\n' > "$PKG_DIR/Broken/manifest.v3"
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *malformed* ]] || true
}

# ---- argument validation --------------------------------------------

@test "fails setup error on missing packages-dir" {
    run "$SCRIPT" --packages-dir "$BATS_TEST_TMPDIR/nope"
    [ "$status" -eq 1 ]
}

@test "passes (vacuously) when packages-dir is empty" {
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 0 ]
}
