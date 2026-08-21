# aiCodingBaseSetup — container-wide environment variables.
# Sourced from ~/.bashrc via the aicoding managed block in ~/.bashrc.
# Add export lines here; they apply to every container deployed from
# this blueprint after running install.sh or aicoding-sync.

# Export the secrets file into every interactive shell so tools that read
# their token from the environment pick it up.
# The file is mounted from the host and gitignored — tokens never get committed.
if [ -f "$HOME/.aicodingsetup/.secrets.env" ]; then
  set -a
  . "$HOME/.aicodingsetup/.secrets.env"
  set +a
fi

# ...but NOT the GitHub token (2026-08-21). It used to be exported here on
# purpose, because it outranks ~/.config/gh/hosts.yml in gh's lookup order and
# so authenticated gh in every workspace without a ~/.config/gh bind mount.
# The cost was a leak path no file deny rule could close: any agent could run
# `printenv GH_TOKEN` and copy a live credential into its transcript.
#
# Nothing breaks by removing it, because neither consumer needs it any more:
#   git — authenticates through git-credential-aicoding, which reads the
#         secrets file directly. It never used the environment.
#   gh  — ensure_gh_stored_auth (lib/sync.sh) logs it in from the same file on
#         every boot sync, so gh uses its own stored credentials. That file,
#         ~/.config/gh/hosts.yml, is deny-listed like .secrets.env.
#
# Anything that genuinely needs the value should read the secrets file itself,
# the way the credential helper does, rather than relying on the environment.
unset GH_TOKEN GITHUB_TOKEN
