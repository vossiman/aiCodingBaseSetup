# The npm package is installed container-locally in $T3_RUNTIME_ROOT/<version>;
# a rebuild wipes it and the next start reinstalls the selected one. Since t3
# 0.1.1 that package is only a launcher: on first run it downloads the
# executable for this platform from the GitHub Release into
# $T3CODE_HOME/runtime/versions/<version> (the folder t3's own `t3 update`
# uses) and verifies it against the release's SHA256SUMS. The executable
# therefore lives with the state on the host mount and survives a rebuild.

t3_launcher() { printf '%s/%s/node_modules/.bin/t3\n' "$T3_RUNTIME_ROOT" "$1"; }
t3_exe_dir() { printf '%s/runtime/versions/%s\n' "${T3CODE_HOME:?}" "$1"; }
# The server runs from the executable, not the node launcher, so the pid in
# server-runtime.json is the supervisor's direct child.
t3_exe() { printf '%s/t3\n' "$(t3_exe_dir "$1")"; }

# The launcher writes the marker last, after the checksum passed.
t3_exe_complete() {
  local d
  d=$(t3_exe_dir "$1")
  [ "$(cat "$d/.install-complete" 2>/dev/null)" = "$1" ] && [ -x "$d/t3" ]
}

t3_installed() {
  [ -x "$(t3_launcher "$1")" ] && t3_exe_complete "$1" \
    && [ "$("$(t3_exe "$1")" --version 2>/dev/null | t3_parse_version)" = "$1" ]
}

t3_install() {
  local v=$1 final stage got
  t3_valid_version "$v" || { t3_say "not a version: $v"; return 1; }
  t3_installed "$v" && return 0
  final="$T3_RUNTIME_ROOT/$v"; stage="$T3_RUNTIME_ROOT/.staging.$v.$$"
  mkdir -p "$T3_RUNTIME_ROOT" && rm -rf "$stage" && mkdir -p "$stage" || return 1
  if ! timeout "$T3_NPM_INSTALL_TIMEOUT" npm install --prefix "$stage" --no-audit --no-fund \
      --loglevel=error "t3@$v" </dev/null >"$stage.log" 2>&1; then
    t3_say "npm install t3@$v failed: $(tail -n 3 "$stage.log" 2>/dev/null | tr '\n' ' ')"
    rm -rf "$stage" "$stage.log"; return 1
  fi
  # The first run fetches the executable; its errors (404, checksum) go to stderr.
  got=$(timeout "$T3_FETCH_TIMEOUT" "$stage/node_modules/.bin/t3" --version </dev/null 2>"$stage.log" | t3_parse_version)
  if [ "$got" != "$v" ]; then
    t3_say "installed t3 reports '${got:-nothing}', expected $v: $(tail -n 3 "$stage.log" 2>/dev/null | tr '\n' ' ')"
    rm -rf "$stage" "$stage.log"; return 1
  fi
  if ! t3_exe_complete "$v"; then
    t3_say "t3 $v did not place its executable in $(t3_exe_dir "$v"): $(tail -n 3 "$stage.log" 2>/dev/null | tr '\n' ' ')"
    rm -rf "$stage" "$stage.log"; return 1
  fi
  rm -f "$stage.log"
  rm -rf "$final" && mv "$stage" "$final"
}

t3_latest() {
  local v
  v=$(timeout "$T3_NPM_VIEW_TIMEOUT" npm view t3 version </dev/null 2>/dev/null | t3_parse_version)
  t3_valid_version "$v" && printf '%s\n' "$v"
}
