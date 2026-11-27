#!/usr/bin/env bash
# Builds the signed split APKs of a tagged version and publishes them as the
# GitHub Release of that tag. The agentd website links the APKs of the latest
# GitHub Release by name (agentd-app-<version>-<abi>.apk, SHA256SUMS): keep
# the names.
#
#   scripts/release.sh [--dry-run] [vX.Y.Z]
#
# The version defaults to the tag on HEAD. --dry-run builds and fills
# dist/release-<version>/ but does not write to GitHub.
set -euo pipefail

# Upload key certificate (docs/signing.md).
UPLOAD_CERT_SHA256="16202bd52cf253261e67d28170dfc42a49d42be82612b1dda78d2af167fcf3bb"
ABIS=(arm64-v8a armeabi-v7a x86_64)

die() { echo "release: $*" >&2; exit 1; }

dry=false
tag=""
for a in "$@"; do
  case "$a" in
    --dry-run) dry=true ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    v*) tag="$a" ;;
    *) die "unknown argument: $a" ;;
  esac
done

cd "$(git rev-parse --show-toplevel)"

if [[ -z "$tag" ]]; then
  tag="$(git tag --points-at HEAD --list 'v*' | sort -V | tail -1)"
  [[ -n "$tag" ]] || die "HEAD has no v* tag; tag it first or pass the tag"
fi
[[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "tag $tag is not vX.Y.Z"
version="${BASH_REMATCH[1]}"

[[ "$(git rev-parse "$tag^{commit}" 2>/dev/null)" == "$(git rev-parse HEAD)" ]] || die "$tag is not on HEAD; check it out first"
[[ -z "$(git status --porcelain)" ]] || die "working tree is not clean"

pub="$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' pubspec.yaml)"
[[ "$pub" == "$version" ]] || die "pubspec.yaml version is $pub, tag is $tag"

remote="$(git ls-remote --tags origin "refs/tags/$tag" | awk '{print $1}')"
[[ -n "$remote" ]] || die "$tag is not pushed to origin"
[[ "$remote" == "$(git rev-parse "$tag")" ]] || die "$tag on origin differs from the local tag"

command -v gh >/dev/null || die "gh is not installed"
if gh release view "$tag" >/dev/null 2>&1; then die "a GitHub Release for $tag already exists"; fi

# Never fall back to the debug key (build.gradle.kts would).
[[ -f android/key.properties ]] || die "android/key.properties is missing (docs/signing.md)"
store="$(sed -n 's/^storeFile=//p' android/key.properties)"
[[ -n "$store" && -f "$store" ]] || die "keystore of android/key.properties not found"

export PATH="/apps/flutter/bin:$PATH"
echo "release: building $tag"
flutter build apk --release --split-per-abi

out="dist/release-$version"
rm -rf "$out"
mkdir -p "$out"
for abi in "${ABIS[@]}"; do
  src="build/app/outputs/flutter-apk/app-$abi-release.apk"
  [[ -f "$src" ]] || die "missing $src"
  cp "$src" "$out/agentd-app-$version-$abi.apk"
done
(cd "$out" && sha256sum agentd-app-"$version"-*.apk > SHA256SUMS)

apksigner="$(command -v apksigner || ls -1 "${ANDROID_HOME:-/apps/android-sdk}"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1 || true)"
if [[ -n "$apksigner" ]]; then
  for f in "$out"/*.apk; do
    certs="$("$apksigner" verify --print-certs "$f" 2>/dev/null)" || die "signature check failed: $f"
    grep -qi "SHA-256 digest: $UPLOAD_CERT_SHA256" <<<"$certs" || die "$f is not signed with the upload key"
  done
  echo "release: signatures verified (upload key)"
else
  echo "release: apksigner not found, signatures not verified" >&2
fi

prev="$(git describe --tags --abbrev=0 --match 'v*' "$tag^" 2>/dev/null || true)"
notes="$out/NOTES.md"
{
  echo "agentd mobile client $version (Android). APKs signed with the Digio upload key (package \`es.digio.agentd\`)."
  echo
  if [[ -n "$prev" ]]; then echo "Changes since $prev:"; echo; fi
  git log --no-merges --format='- %s' ${prev:+"$prev..$tag"}
} > "$notes"

echo
ls -l "$out"
echo

if $dry; then
  echo "release: dry run, nothing published. Notes: $notes"
  echo "release: publish with: scripts/release.sh $tag"
  exit 0
fi

gh release create "$tag" --title "agentd-app $version" --notes-file "$notes" --latest \
  "$out"/agentd-app-"$version"-*.apk "$out/SHA256SUMS"
echo "release: published $tag"
