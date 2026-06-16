# aiCodingBaseSetup — container-wide environment variables.
# Sourced from ~/.bashrc via the aicoding managed block in ~/.bashrc.
# Add export lines here; they apply to every container deployed from
# this blueprint after running install.sh or aicoding-update.

# Export the secrets file into every interactive shell so tools that read
# their token from the environment pick it up. In particular GH_TOKEN: it
# outranks the system keyring and ~/.config/gh/hosts.yml in gh's lookup order,
# so `gh` is authenticated in every workspace without a ~/.config/gh bind
# mount (and without the keyring-fallback fragility in headless containers).
# The file is mounted from the host and gitignored — tokens never get committed.
if [ -f "$HOME/.aicodingsetup/.secrets.env" ]; then
  set -a
  . "$HOME/.aicodingsetup/.secrets.env"
  set +a
fi

# paseo: point the CLI at this pod's daemon state (per-workspace home inside
# the shared ~/.aicodingsetup mount). Derivation lives in one place —
# aicoding-paseo-daemon — so interactive shells and the boot hook agree.
if command -v aicoding-paseo-daemon >/dev/null 2>&1; then
  _aicoding_paseo_home=$(aicoding-paseo-daemon --print-home 2>/dev/null) \
    && export PASEO_HOME="$_aicoding_paseo_home"
  unset _aicoding_paseo_home
fi
