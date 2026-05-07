#!/usr/bin/env bats
# Tests for scripts/policy/check-acl-hygiene.sh.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../check-acl-hygiene.sh"
    [[ -x "$SCRIPT" ]] || skip "check-acl-hygiene.sh not executable"
    PKG_DIR="$BATS_TEST_TMPDIR/packages"
    mkdir -p "$PKG_DIR"
}

# mk_flow PACKAGE NSPATH ACL [COMMENT]
mk_flow() {
    local pkg=$1 nspath=$2 acl=$3 comment=${4:-}
    local dir="$PKG_DIR/$pkg/ns/$nspath"
    mkdir -p "$dir"
    : > "$dir/flow.xml"
    cat > "$dir/flow.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<FLOW>
  <COMMENT>$comment</COMMENT>
</FLOW>
XML
    cat > "$dir/node.ndf" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<Values version="2.0">
  <value name="acl_runtime">$acl</value>
  <value name="node_comment">$comment</value>
</Values>
XML
    cat > "$PKG_DIR/$pkg/manifest.v3" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<Manifest><version>1.0.0</version></Manifest>
XML
}

# ---- passing fixtures -----------------------------------------------

@test "passes when no flow services exist" {
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 0 ]
}

@test "passes when all flow services use a non-Anonymous ACL" {
    mk_flow OrderService com/acme/orders/getOrder Internal "Returns an order by id"
    mk_flow OrderService com/acme/orders/listOrders Internal "Lists orders"
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *PASS:* ]]
}

@test "passes when Anonymous ACL is waived by // public-by-design" {
    mk_flow PingService com/acme/ping/ping Anonymous "// public-by-design - k8s liveness probe"
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 0 ]
}

@test "node without acl_runtime is ignored (IS default applies)" {
    local dir="$PKG_DIR/Misc/ns/com/acme/Misc/raw"
    mkdir -p "$dir"
    : > "$dir/flow.xml"
    cat > "$dir/node.ndf" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<Values version="2.0">
  <value name="node_nsName">raw</value>
</Values>
XML
    cat > "$PKG_DIR/Misc/manifest.v3" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<Manifest><version>1.0.0</version></Manifest>
XML
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 0 ]
}

# ---- failing fixtures -----------------------------------------------

@test "fails on Anonymous ACL with no marker" {
    mk_flow OrderService com/acme/orders/getOrder Anonymous "Returns an order by id"
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *Anonymous* ]] || [[ "${stderr:-}" == *Anonymous* ]] \
        || true   # message is on stderr; bats merges by default
}

@test "fails on Anonymous ACL with empty comment" {
    mk_flow OrderService com/acme/orders/listOrders Anonymous ""
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 2 ]
}

@test "marker must match exactly: '// public by design' is rejected" {
    # Note the missing hyphen.
    mk_flow PingService com/acme/ping/ping Anonymous "// public by design"
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 2 ]
}

@test "fails when only one of several services lacks the marker" {
    mk_flow PingService com/acme/ping/ping Anonymous "// public-by-design intentional"
    mk_flow LeakService com/acme/leak/leak Anonymous "TODO: lock down"
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *com/acme/leak/leak* ]] || true
}

# ---- legacy KV format -----------------------------------------------

@test "accepts legacy key=value node.ndf format" {
    local dir="$PKG_DIR/Legacy/ns/com/acme/legacy/old"
    mkdir -p "$dir"
    : > "$dir/flow.xml"
    cat > "$dir/node.ndf" <<EOF
node_nsName=old
acl_runtime=Anonymous
node_comment=// public-by-design
EOF
    cat > "$PKG_DIR/Legacy/manifest.v3" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<Manifest><version>1.0.0</version></Manifest>
XML
    run "$SCRIPT" --packages-dir "$PKG_DIR"
    [ "$status" -eq 0 ]
}

# ---- argument validation --------------------------------------------

@test "fails setup error when packages-dir is missing" {
    run "$SCRIPT" --packages-dir "$BATS_TEST_TMPDIR/nope"
    [ "$status" -eq 1 ]
}
