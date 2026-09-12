#!/usr/bin/env bats
setup() {
  export TMP; TMP=$(mktemp -d)
  export HOME="$TMP/home"
  mkdir -p "$HOME" "$TMP/tree"
  . "$BLUEPRINT_ROOT/lib/update-results.sh"
  . "$BLUEPRINT_ROOT/lib/update-components.sh"
}
teardown() { chmod -R u+rwX "$TMP"; rm -rf "$TMP"; }

legacy_digest() {
  local root=$1 inventory path relative mode kind value digest
  inventory=$(mktemp "${TMPDIR:-/tmp}/aicoding-release-integrity.XXXXXX") || return 1
  while IFS= read -r -d '' path; do
    relative=${path#"$root/"}
    [ "$relative" != .aicoding-release-integrity ] || continue
    mode=$(stat -c '%a' -- "$path" 2>/dev/null) || { rm -f "$inventory"; return 1; }
    if [ -L "$path" ]; then
      kind=link; value=$(readlink -- "$path") || { rm -f "$inventory"; return 1; }
    elif [ -f "$path" ]; then
      kind=file; value=$(sha256sum -- "$path" | awk '{print $1}') \
        || { rm -f "$inventory"; return 1; }
    elif [ -d "$path" ]; then
      kind=directory; value=
    else
      rm -f "$inventory"
      return 1
    fi
    printf '%s\0%s\0%s\0%s\0' "$relative" "$kind" "$mode" "$value" >>"$inventory" \
      || { rm -f "$inventory"; return 1; }
  done < <(find "$root" -mindepth 1 -print0 2>/dev/null | sort -z)
  digest=$(sha256sum "$inventory" | awk '{print $1}') || { rm -f "$inventory"; return 1; }
  rm -f "$inventory" || return 1
  printf '%s\n' "$digest"
}

@test "release digest preserves legacy receipts including unusual names and modes" {
  mkdir -p "$TMP/tree/nested" "$TMP/tree/empty"
  printf content > "$TMP/tree/nested/plain"
  chmod 751 "$TMP/tree/nested/plain"
  printf content > "$TMP/tree/space name"
  printf content > "$TMP/tree/"$'newline\nname'
  printf content > "$TMP/tree/"$'back\\slash'
  printf content > "$TMP/tree/ä-name"
  ln -s $'absent\n\n' "$TMP/tree/trailing-newline-link"
  ln -s /nonexistent/outside "$TMP/tree/external"
  printf ignored > "$TMP/tree/.aicoding-release-integrity"
  local expected
  expected=$(legacy_digest "$TMP/tree")
  run _aicoding_release_tree_digest_impl "$TMP/tree"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "release digest fails closed on missing and unreadable directories" {
  run _aicoding_release_tree_digest_impl "$TMP/missing"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  mkdir "$TMP/tree/denied"
  chmod 000 "$TMP/tree/denied"
  run _aicoding_release_tree_digest_impl "$TMP/tree"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "release digest rejects unreadable files and special paths" {
  printf hidden > "$TMP/tree/denied"
  chmod 000 "$TMP/tree/denied"
  run _aicoding_release_tree_digest_impl "$TMP/tree"
  [ "$status" -ne 0 ]
  rm -f "$TMP/tree/denied"
  mkfifo "$TMP/tree/pipe"
  run _aicoding_release_tree_digest_impl "$TMP/tree"
  [ "$status" -ne 0 ]
}

@test "release digest timeout bounds a stalled hasher" {
  mkdir "$TMP/stubs"
  printf '#!/bin/sh\nsleep 5\n' > "$TMP/stubs/python3"
  chmod +x "$TMP/stubs/python3"
  export PATH="$TMP/stubs:$PATH" AICODING_VENDOR_TIMEOUT=0.1
  run _aicoding_release_tree_digest_impl "$TMP/tree"
  [ "$status" -eq 124 ]
  [ -z "$output" ]
}

@test "release digest does not traverse external symlinks" {
  mkdir "$TMP/outside"
  printf first > "$TMP/outside/file"
  ln -s "$TMP/outside" "$TMP/tree/link"
  local before
  before=$(_aicoding_release_tree_digest_impl "$TMP/tree")
  printf changed > "$TMP/outside/file"
  [ "$(_aicoding_release_tree_digest_impl "$TMP/tree")" = "$before" ]
  ln -s "$TMP/tree" "$TMP/root-link"
  local link
  for link in "$TMP/root-link" "$TMP/root-link/"; do
    run _aicoding_release_tree_digest_impl "$link"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
}

@test "release digest preserves legacy trailing-slash root semantics" {
  printf content > "$TMP/tree/file"
  local root expected
  for root in "$TMP/tree/" "$TMP/tree//"; do
    expected=$(legacy_digest "$root")
    run _aicoding_release_tree_digest_impl "$root"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
  done
}
