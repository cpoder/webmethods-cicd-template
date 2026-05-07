#!/usr/bin/env bats
# Tests for scripts/policy/check-package-naming.sh.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../check-package-naming.sh"
    [[ -x "$SCRIPT" ]] || skip "check-package-naming.sh not executable"
    PKG_DIR="$BATS_TEST_TMPDIR/packages"
    mkdir -p "$PKG_DIR"
}

mk_pkg() {
    local name=$1
    mkdir -p "$PKG_DIR/$name"
    cat > "$PKG_DIR/$name/manifest.v3" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<Manifest>
  <version>1.0.0</version>
</Manifest>
XML
}

# ---- passing fixture -------------------------------------------------

@test "passes when only allowed names are present" {
    mk_pkg "OrderService"
    mk_pkg "InvoiceService"
    mk_pkg "Customer"
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == PASS:* ]]
}

@test "ignores directories without manifest.v3 (e.g. .gitkeep stub)" {
    mkdir -p "$PKG_DIR/scratch"
    : > "$PKG_DIR/.gitkeep"
    mk_pkg "OrderService"
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 0 ]
}

# ---- failing fixture -------------------------------------------------

@test "fails on reserved exact name 'Default'" {
    mk_pkg "Default"
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Default is reserved"* ]] \
        || [[ "${stderr:-}" == *"Default is reserved"* ]] \
        || [[ "$output" == *Default* ]]
}

@test "fails on reserved exact name 'Test'" {
    mk_pkg "Test"
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 2 ]
}

@test "fails on reserved exact name 'Tmp'" {
    mk_pkg "Tmp"
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 2 ]
}

@test "fails on Wm-prefixed name (WmCorp)" {
    mk_pkg "WmCorp"
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 2 ]
}

@test "fails on bare prefix name 'Wm'" {
    mk_pkg "Wm"
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 2 ]
}

@test "lowercase 'default' is NOT reserved (case-sensitive policy)" {
    mk_pkg "default"
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 0 ]
}

# ---- allowlist semantics --------------------------------------------

@test "--allow exempts a single legacy package name" {
    mk_pkg "WmLegacy"
    run "$SCRIPT" --packages-dir "$PKG_DIR" --allow WmLegacy
    [ "$status" -eq 0 ]
    [[ "$output" == *PASS:* ]]
}

@test "POLICY_PKG_ALLOW env var also exempts" {
    mk_pkg "Default"
    POLICY_PKG_ALLOW="Default" run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 0 ]
}

# ---- argument validation --------------------------------------------

@test "fails setup error when packages-dir is missing" {
    run "$SCRIPT" --packages-dir "$BATS_TEST_TMPDIR/nope"
    [ "$status" -eq 1 ]
}
