#!/bin/zsh
# Publishes a Pepper release to Orbis through its release-only API, using Muesli's release tool: one tool and one
# release sign-in (kept in the Keychain) for both apps. Muesli's commands, scoped to Pepper:
#   scripts/publish.sh 1.2.4 [--dry-run]   upload dist/upload-1.2.4 (archives first, appcast last), publish, then
#                                          check the live feed and every file byte for byte
#   scripts/publish.sh --status            what Orbis serves for Pepper now
#   scripts/publish.sh --sign-in           once per Mac (shared with Muesli); --sign-out forgets it
# Muesli's repo is ~/Muesli unless MUESLI_REPO says otherwise. Contract: Muesli docs/ORBIS-INTEGRATION.md §6.1.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
muesli="${MUESLI_REPO:-$HOME/Muesli}"
if [ ! -x "$muesli/scripts/publish.sh" ]; then
  echo "Muesli's release tool isn't at $muesli/scripts/publish.sh (set MUESLI_REPO)." >&2
  exit 1
fi
PEPPER_REPO="$here" exec "$muesli/scripts/publish.sh" --app pepper "$@"
