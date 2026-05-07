#!/usr/bin/env bats
# Tests for scripts/policy/check-image-size.sh.
# Two cases minimum (passing fixture, failing fixture). Several extra
# cases here exercise the unit-parsing helper because a bug there
# would silently waive the gate.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../check-image-size.sh"
    [[ -x "$SCRIPT" ]] || skip "check-image-size.sh not executable"
    TARBALL="$BATS_TEST_TMPDIR/svc.tar"
}

# ---- passing fixture -------------------------------------------------

@test "passes when --size-bytes is below the default 2GiB ceiling" {
    run "$SCRIPT" --size-bytes 1073741824   # 1 GiB
    [ "$status" -eq 0 ]
    [[ "$output" == PASS:* ]]
}

@test "passes when tarball is smaller than --max-size 2GB" {
    # 100 MiB sparse file
    truncate -s 100M "$TARBALL"
    run "$SCRIPT" --tarball "$TARBALL" --max-size 2GB
    [ "$status" -eq 0 ]
}

# ---- failing fixture -------------------------------------------------

@test "fails (exit 2) when --size-bytes is above the default ceiling" {
    # 2 GiB + 1 byte
    run "$SCRIPT" --size-bytes 2147483649
    [ "$status" -eq 2 ]
    [[ "$output" == *FAIL:* ]]
}

@test "fails when tarball is bigger than --max-size 1MB" {
    truncate -s 5M "$TARBALL"
    run "$SCRIPT" --tarball "$TARBALL" --max-size 1MB
    [ "$status" -eq 2 ]
}

# ---- argument validation --------------------------------------------

@test "rejects when no input source is given" {
    run "$SCRIPT"
    [ "$status" -eq 1 ]
}

@test "rejects more than one input source" {
    run "$SCRIPT" --image foo:bar --size-bytes 1
    [ "$status" -eq 1 ]
}

@test "rejects --max-bytes and --max-size together" {
    run "$SCRIPT" --size-bytes 1 --max-bytes 1 --max-size 1GB
    [ "$status" -eq 1 ]
}

@test "rejects unparseable --max-size unit" {
    run "$SCRIPT" --size-bytes 1 --max-size "five gigs"
    [ "$status" -eq 1 ]
}

# ---- unit-parser sanity ---------------------------------------------

@test "1.5GiB ceiling rejects 1.6GiB content" {
    bytes=$((1717986918))   # 1.6 GiB
    run "$SCRIPT" --size-bytes "$bytes" --max-size 1.5GiB
    [ "$status" -eq 2 ]
}

@test "GB and GiB units are NOT the same" {
    # 2 GB == 2_000_000_000; 2 GiB == 2_147_483_648.
    # A payload of 2_100_000_000 bytes:
    #   - exceeds 2GB  -> FAIL
    #   - is below 2GiB -> PASS
    run "$SCRIPT" --size-bytes 2100000000 --max-size 2GB
    [ "$status" -eq 2 ]
    run "$SCRIPT" --size-bytes 2100000000 --max-size 2GiB
    [ "$status" -eq 0 ]
}
