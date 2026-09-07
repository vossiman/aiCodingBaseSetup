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
  # Byte length, not character length: base64 groups bytes, and a non-ASCII
  # value has more bytes than characters.
  local LC_ALL=C
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

# Two keys can hold the same value (a password reused across services), and
# two different values can share a base64 core. Either way one sed rule
# would eat every occurrence and the other key would never be reported, so
# patterns are deduplicated and their marker names every key, [REDACTED:A,B];
# the caller reports each name.
redact_literal_rules() {
  local mode="$1" f="${2:-$HOME/.aicodingsetup/.secrets.env}"
  local line key val marker jval out='' keys=0 expected=0 k core rule i
  local -a vals=() names=()
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
    [ "$(LC_ALL=C; printf '%d' "${#val}")" -ge 8 ] || continue
    keys=$(( keys + 1 ))
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || key="_"
    for i in "${!vals[@]}"; do
      if [ "${vals[$i]}" = "$val" ]; then names[$i]="${names[$i]},$key"; val=""; break; fi
    done
    [ -n "$val" ] || continue
    vals+=("$val"); names+=("$key")
  done < "$f" || return 1

  [ "$keys" -eq "$expected" ] || return 1

  # Every pattern each value produces (raw, JSON-escaped, base64 cores),
  # keyed by the pattern text so two values that happen to share a pattern
  # (identical values, or distinct values with the same base64 core) end up
  # in ONE rule whose marker names every key involved. Then longest pattern
  # first: a pattern that contains another must be replaced before the
  # shorter one can eat part of it and leave its key unreported. That order
  # also puts a JSON-escaped form ahead of its raw form.
  local -a pats=() pnames=()
  local j found
  _add() {  # _add PATTERN NAMES
    local pat="$1" nm="$2"
    for j in "${!pats[@]}"; do
      if [ "${pats[$j]}" = "$pat" ]; then
        case ",${pnames[$j]}," in *",$nm,"*) ;; *) pnames[$j]="${pnames[$j]},$nm" ;; esac
        return 0
      fi
    done
    pats+=("$pat"); pnames+=("$nm")
  }
  for i in "${!vals[@]}"; do
    val="${vals[$i]}"
    _add "$val" "${names[$i]}"
    jval="$(redact_literal_json_escape "$val")"
    [ "$jval" != "$val" ] && _add "$jval" "${names[$i]}"
    if [ "$mode" = sessions ] && [ "$(LC_ALL=C; printf '%d' "${#val}")" -ge 12 ]; then
      for k in 0 1 2; do
        core="$(redact_literal_b64_core "$val" "$k")"
        [ "${#core}" -ge 12 ] || continue
        _add "$core" "${names[$i]}"
        _add "$(printf '%s' "$core" | tr '+/' '-_')" "${names[$i]}"
      done
    fi
  done
  unset -f _add

  local -a order=()
  while IFS= read -r i; do order+=("$i"); done < <(
    for i in "${!pats[@]}"; do LC_ALL=C printf '%d %d\n' "${#pats[$i]}" "$i"; done | sort -k1,1nr -k2,2n | awk '{print $2}')

  for i in "${order[@]}"; do
    marker="[REDACTED]"
    if [ "$mode" = sessions ]; then
      # Drop the "_" placeholders left by unnameable keys; keep the rest.
      key="$(printf '%s' "${pnames[$i]}" | tr ',' '\n' | grep -vx '_' | sort -u | paste -sd, -)"
      [ -n "$key" ] && marker="[REDACTED:$key]"
    fi
    rule="$(_redact_literal_rule "${pats[$i]}" "$marker")" || return 1
    out+="$rule"$'\n'
  done
  printf '%s' "$out"
}
