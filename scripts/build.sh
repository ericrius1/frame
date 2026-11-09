#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$(dirname -- "$project_dir")"
staging_dir="$project_dir/.build/Frame.app"
destination="$output_dir/Frame.app"
archive_dir="$project_dir/.build/previous"
signing_identity="${FRAME_SIGNING_IDENTITY:-CC67698EC7F430EE933BB36F89186CFFB4568125}"
signing_identity="$(printf '%s' "$signing_identity" | tr -d ':' | tr '[:lower:]' '[:upper:]')"

# A certificate-backed identity remains recognizable across changed builds.
# Never replace it with an ad-hoc signature: privacy grants would stop matching.
if [[ ! "$signing_identity" =~ ^[0-9A-F]{40}$ ]]; then
    printf 'FRAME_SIGNING_IDENTITY must be the 40-character SHA-1 fingerprint of an existing code-signing identity.\n' >&2
    printf 'List available identities with: security find-identity -v -p codesigning\n' >&2
    exit 1
fi
valid_identities="$(security find-identity -v -p codesigning)"
if ! printf '%s\n' "$valid_identities" | awk -v identity="$signing_identity" \
    'toupper($2) == identity { found = 1 } END { exit !found }'; then
    printf 'The requested signing identity %s is not available and valid in the current keychain.\n' "$signing_identity" >&2
    printf 'Run security find-identity -v -p codesigning, then set FRAME_SIGNING_IDENTITY to an available certificate fingerprint.\n' >&2
    printf 'Frame has not been rebuilt or replaced. No ad-hoc fallback is used.\n' >&2
    exit 1
fi

ensure_destination_stopped() {
    python3 - "$destination/Contents/MacOS/Frame" <<'PY'
import os
import subprocess
import sys

executable = os.path.realpath(sys.argv[1])
processes = subprocess.run(['/bin/ps', '-axww', '-o', 'pid=,comm='],
                           check=True, capture_output=True, text=True).stdout
for line in processes.splitlines():
    fields = line.strip().split(None, 1)
    if len(fields) == 2 and os.path.realpath(fields[1]) == executable:
        print(f'Quit Frame (PID {fields[0]}) before building or replacing {sys.argv[1]}.', file=sys.stderr)
        sys.exit(1)
PY
}

archive_path() {
    printf '%s/Frame-%s-%s-%s.verifiedbundle' "$archive_dir" "$1" "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
}

ensure_destination_stopped

swift build --configuration release --package-path "$project_dir"
binary_dir="$(swift build --configuration release --package-path "$project_dir" --show-bin-path)"

if [[ -e "$staging_dir" || -L "$staging_dir" ]]; then
    mkdir -p "$archive_dir"
    mv -- "$staging_dir" "$(archive_path staging)"
fi
mkdir -p "$staging_dir/Contents/MacOS" "$staging_dir/Contents/Resources"
cp "$binary_dir/Frame" "$staging_dir/Contents/MacOS/Frame"
cp "$project_dir/Resources/Info.plist" "$staging_dir/Contents/Info.plist"

if [[ ! -f "$project_dir/Resources/Frame.icns" ]]; then
    iconset_dir="$project_dir/.build/Frame.iconset"
    swift "$project_dir/scripts/make-icon.swift" "$iconset_dir"
    iconutil --convert icns --output "$project_dir/Resources/Frame.icns" "$iconset_dir"
fi
cp "$project_dir/Resources/Frame.icns" "$staging_dir/Contents/Resources/Frame.icns"
plutil -lint "$staging_dir/Contents/Info.plist"
codesign --force --sign "$signing_identity" --identifier dev.frame.capture \
    --entitlements "$project_dir/Resources/Frame.entitlements" "$staging_dir"
codesign --verify --deep --strict "$staging_dir"
designated_requirement="$(codesign --display -r- "$staging_dir" 2>&1)"
if ! printf '%s\n' "$designated_requirement" | awk \
    '/^(# )?designated => / { found = 1; if ($0 ~ /^(# )?designated => cdhash /) hash_only = 1 } END { exit !(found && !hash_only) }'; then
    printf 'The built app has no stable designated requirement. The previous app has not been replaced.\n' >&2
    exit 1
fi
codesign --display --verbose=2 "$staging_dir"

# Recheck after compilation in case Frame was opened while the build ran.
# Keep the previous bundle recoverable until the verified replacement is in place.
ensure_destination_stopped
previous_destination=""
if [[ -e "$destination" || -L "$destination" ]]; then
    mkdir -p "$archive_dir"
    previous_destination="$(archive_path installed)"
    mv -- "$destination" "$previous_destination"
fi
if ! mv -- "$staging_dir" "$destination"; then
    if [[ -n "$previous_destination" && ! -e "$destination" ]]; then
        mv -- "$previous_destination" "$destination"
    fi
    printf 'Frame could not be replaced; the previous bundle was restored when possible.\n' >&2
    exit 1
fi
printf 'Built %s\n' "$destination"
if [[ -n "$previous_destination" ]]; then
    printf 'Previous build preserved at %s\n' "$previous_destination"
fi
