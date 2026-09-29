# t3 releases live container-locally in $T3_RUNTIME_ROOT/<version>; a rebuild
# wipes them and the next start reinstalls the selected one.

t3_arch() { case "$(uname -m)" in aarch64|arm64) echo arm64 ;; *) echo x64 ;; esac; }
t3_launcher() { printf '%s/%s/node_modules/.bin/t3\n' "$T3_RUNTIME_ROOT" "$1"; }
# The server runs from the platform binary, not the node launcher, so the pid
# in server-runtime.json is the supervisor's direct child.
t3_exe() { printf '%s/%s/node_modules/@t3code/t3-linux-%s/t3\n' "$T3_RUNTIME_ROOT" "$1" "$(t3_arch)"; }

t3_installed() {
  local l e
  l=$(t3_launcher "$1"); e=$(t3_exe "$1")
  [ -x "$l" ] && [ -x "$e" ] && [ "$("$l" --version 2>/dev/null | t3_parse_version)" = "$1" ]
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
  rm -f "$stage.log"
  got=$("$stage/node_modules/.bin/t3" --version 2>/dev/null | t3_parse_version)
  if [ "$got" != "$v" ] || [ ! -x "$stage/node_modules/@t3code/t3-linux-$(t3_arch)/t3" ]; then
    t3_say "installed t3 reports '${got:-nothing}', expected $v"
    rm -rf "$stage"; return 1
  fi
  rm -rf "$final" && mv "$stage" "$final"
}

t3_latest() {
  local v
  v=$(timeout "$T3_NPM_VIEW_TIMEOUT" npm view t3 version </dev/null 2>/dev/null | t3_parse_version)
  t3_valid_version "$v" && printf '%s\n' "$v"
}
