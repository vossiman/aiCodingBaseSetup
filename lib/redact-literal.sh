#!/usr/bin/env bash
# lib/redact-literal.sh: turns the secrets file into sed rules. Sourced by
# bin/redact-transcript and bin/redact-sessions so the literal layer exists
# once. Never writes anything to disk and never prints a value except inside
# the sed script it returns to its caller.
#
# The secrets file is only ever READ.
#
# Modes:
#   transcript  s/V/[REDACTED]/g plus the JSON-escaped variant of V.
#   sessions    s/V/[REDACTED:KEY]/g plus JSON-escaped, plus the base64 runs
#               fully determined by V at each of the three byte alignments,
#               in both the standard and the URL-safe alphabet.
#
# Floors: values under 8 characters get no rule (too collision-prone to
# redact globally). Values under 12 get no base64 rule (the aligned core is
# too short to be unique).
#
# Fail-closed contract (shared by both callers): file absent means exit 0 and
# an empty script; file present but unreadable, or parsed to a different
# number of keys than an independent count, means exit 1 and an empty script.

redact_literal_json_escape() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '%s' "$v"
}

# Escapes ERE metacharacters (backslashes first). The class lists `[` last:
# `[.` inside a bracket expression opens a POSIX collating symbol.
redact_literal_ere_escape() {
  printf '%s' "$1" | sed -e 's,\\,\\\\,g' -e 's,[]^$*+?(){}|/.[],\\&,g'
}

# redact_literal_b64_core VALUE K: the base64 characters that depend only on
# VALUE when VALUE starts K bytes (0, 1, 2) into a 3-byte group. Leading
# characters that mix in the filler bytes are dropped (0, 2, 3 of them), the
# padding is dropped, and when (K + len) % 3 != 0 the last character mixes
# VALUE's final bits with whatever byte follows in a larger blob, so it is
# dropped too.
redact_literal_b64_core() {
  local v="$1" k="$2" filler="" enc
  case "$k" in 1) filler="A" ;; 2) filler="AA" ;; esac
  enc="$(printf '%s%s' "$filler" "$v" | base64 -w0)"
  enc="${enc%%=*}"
  case "$k" in 1) enc="${enc:2}" ;; 2) enc="${enc:3}" ;; esac
  if [ $(( (k + ${#v}) % 3 )) -ne 0 ]; then enc="${enc%?}"; fi
  printf '%s' "$enc"
}

# Counts KEY=value lines whose stripped value is >= 8 chars, independently of
# the rule generator, so a partial read shows up as a mismatch.
_redact_literal_expected() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    index($0, "=") == 0 { next }
    {
      v = $0; sub(/^[^=]*=/, "", v)
      sub(/"$/,    "", v); sub(/^"/,    "", v)
      sub(/\047$/, "", v); sub(/^\047/, "", v)
      if (length(v) >= 8) c++
    }
    END { print c + 0 }
  ' "$1"
}

# _redact_literal_rule PATTERN MARKER: one sed substitution line.
_redact_literal_rule() {
  local esc
  esc="$(redact_literal_ere_escape "$1")" || return 1
  [ -n "$esc" ] || return 1
  printf 's/%s/%s/g\n' "$esc" "$2"
}

redact_literal_rules() {
  local mode="$1" f="${2:-$HOME/.aicodingsetup/.secrets.env}"
  local line key val marker jval out='' keys=0 expected=0 k core rule
  case "$mode" in transcript|sessions) ;; *) return 1 ;; esac
  [ -e "$f" ] || return 0
  [ -r "$f" ] || return 1

  expected="$(_redact_literal_expected "$f")" || return 1
  case "$expected" in (''|*[!0-9]*) return 1 ;; esac

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ('#'*|'') continue ;; (*=*) ;; (*) continue ;; esac
    key="${line%%=*}"; key="${key#export }"; key="${key//[[:space:]]/}"
    val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    [ "${#val}" -ge 8 ] || continue
    keys=$(( keys + 1 ))

    if [ "$mode" = sessions ] && [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      marker="[REDACTED:$key]"
    else
      marker="[REDACTED]"
    fi

    rule="$(_redact_literal_rule "$val" "$marker")" || return 1
    out+="$rule"$'\n'
    jval="$(redact_literal_json_escape "$val")"
    if [ "$jval" != "$val" ]; then
      rule="$(_redact_literal_rule "$jval" "$marker")" || return 1
      out+="$rule"$'\n'
    fi

    if [ "$mode" = sessions ] && [ "${#val}" -ge 12 ]; then
      for k in 0 1 2; do
        core="$(redact_literal_b64_core "$val" "$k")"
        [ "${#core}" -ge 12 ] || continue
        rule="$(_redact_literal_rule "$core" "$marker")" || return 1
        out+="$rule"$'\n'
        rule="$(_redact_literal_rule "$(printf '%s' "$core" | tr '+/' '-_')" "$marker")" || return 1
        out+="$rule"$'\n'
      done
    fi
  done < "$f" || return 1

  [ "$keys" -eq "$expected" ] || return 1
  printf '%s' "$out"
}
