#!/bin/bash
set -euo pipefail

APP_NAME="HopTab"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TAP_REPO="royalbhati/homebrew-tap"
PLIST="$PROJECT_DIR/$APP_NAME/Info.plist"
PBXPROJ="$PROJECT_DIR/$APP_NAME.xcodeproj/project.pbxproj"

cd "$PROJECT_DIR"

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
BUMP="${1:-patch}"  # patch (default), minor, or major

if [[ ! "$BUMP" =~ ^(patch|minor|major)$ ]]; then
  echo "Usage: ./scripts/release.sh [patch|minor|major]"
  exit 1
fi

# ---------------------------------------------------------------------------
# Ensure clean working tree
# ---------------------------------------------------------------------------
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: working tree is dirty. Commit or stash changes first."
  exit 1
fi

# ---------------------------------------------------------------------------
# Compute next version
# ---------------------------------------------------------------------------
LATEST_TAG=$(git tag --sort=-v:refname | head -1)
LATEST_VERSION="${LATEST_TAG#v}"

IFS='.' read -r MAJOR MINOR PATCH <<< "$LATEST_VERSION"

case "$BUMP" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
esac

NEW_VERSION="$MAJOR.$MINOR.$PATCH"
NEW_TAG="v$NEW_VERSION"

echo "Release: $LATEST_TAG → $NEW_TAG ($BUMP bump)"

# ---------------------------------------------------------------------------
# Generate changelog from commits since last tag
# ---------------------------------------------------------------------------
echo ""
echo "## Changelog ($NEW_TAG)"
echo ""

CHANGELOG=$(git log "$LATEST_TAG"..HEAD --pretty=format:"- %s" --no-merges)

if [[ -z "$CHANGELOG" ]]; then
  echo "Warning: no new commits since $LATEST_TAG"
  read -rp "Continue anyway? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
  CHANGELOG="- Maintenance release"
fi

echo "$CHANGELOG"
echo ""

# ---------------------------------------------------------------------------
# Confirm
# ---------------------------------------------------------------------------
read -rp "Proceed with release $NEW_TAG? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# Stamp version in Info.plist and project.pbxproj
# ---------------------------------------------------------------------------
echo "Stamping version $NEW_VERSION..."

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$PLIST"

sed -i '' "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $NEW_VERSION;/" "$PBXPROJ"

# ---------------------------------------------------------------------------
# Commit, tag, push
# ---------------------------------------------------------------------------
git add "$PLIST" "$PBXPROJ"
git commit -m "Bump version to $NEW_VERSION"
git tag -a "$NEW_TAG" -m "$APP_NAME $NEW_TAG

$CHANGELOG"

echo "Pushing tag $NEW_TAG..."
git push origin HEAD
git push origin "$NEW_TAG"

echo ""
echo "Tag $NEW_TAG pushed — CI will build and create the GitHub release."

# ---------------------------------------------------------------------------
# Wait for release and update Homebrew cask
# ---------------------------------------------------------------------------
echo "Waiting for GitHub release to finish..."

MAX_WAIT=300
INTERVAL=10
ELAPSED=0

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  ASSET_URL=$(gh release view "$NEW_TAG" --json assets --jq ".assets[] | select(.name == \"$APP_NAME-$NEW_VERSION.zip\") | .url" 2>/dev/null || true)
  if [[ -n "$ASSET_URL" ]]; then
    break
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
  echo "  ... waiting ($ELAPSED/${MAX_WAIT}s)"
done

if [[ -z "${ASSET_URL:-}" ]]; then
  echo ""
  echo "Warning: timed out waiting for release asset."
  echo "Update the Homebrew cask manually once the release is ready:"
  echo "  gh release view $NEW_TAG"
  echo ""
  exit 0
fi

echo "Release asset found. Computing SHA256..."

DOWNLOAD_URL="https://github.com/royalbhati/$APP_NAME/releases/download/$NEW_TAG/$APP_NAME-$NEW_VERSION.zip"
SHA256=$(curl -sL "$DOWNLOAD_URL" | shasum -a 256 | awk '{print $1}')

echo "SHA256: $SHA256"

# ---------------------------------------------------------------------------
# Update Homebrew cask via PR
# ---------------------------------------------------------------------------
echo "Updating Homebrew cask..."

CASK_TMPDIR=$(mktemp -d)
gh repo clone "$TAP_REPO" "$CASK_TMPDIR" -- -q 2>/dev/null

CASK_FILE="$CASK_TMPDIR/Casks/hoptab.rb"

sed -i '' "s/version \".*\"/version \"$NEW_VERSION\"/" "$CASK_FILE"
sed -i '' "s/sha256 \".*\"/sha256 \"$SHA256\"/" "$CASK_FILE"

cd "$CASK_TMPDIR"
git add Casks/hoptab.rb
git commit -m "Update HopTab to $NEW_VERSION"
git push origin main

rm -rf "$CASK_TMPDIR"
cd "$PROJECT_DIR"

# ---------------------------------------------------------------------------
# Update release notes with Homebrew install option
# ---------------------------------------------------------------------------
# NOTE: do NOT wrap this heredoc in "$(cat <<EOF ...)". macOS ships bash 3.2 as
# /bin/bash, and it mis-parses an apostrophe (as in "What's New") inside a
# heredoc inside command substitution — which turned this entire script into a
# syntax error at load time. Writing to a file and passing --notes-file avoids it.
NOTES_FILE="$(mktemp -t hoptab-release-notes)"
trap 'rm -f "$NOTES_FILE"' EXIT

cat > "$NOTES_FILE" <<EOF
## What's New

$CHANGELOG

See [CHANGELOG.md](https://github.com/royalbhati/$APP_NAME/blob/$NEW_TAG/CHANGELOG.md) for the full history.

## Install

### Homebrew
\`\`\`bash
brew install --cask royalbhati/tap/hoptab
\`\`\`

### Manual
1. Download **$APP_NAME-$NEW_VERSION.zip** below
2. Unzip it
3. Drag **$APP_NAME.app** into your **Applications** folder
4. Launch it and grant **Accessibility** permission when prompted

Signed with a Developer ID certificate (Team GP4Y23ZTR6) and notarized by Apple,
so it opens normally — no Gatekeeper workaround needed.

### Verify the download
\`\`\`
shasum -a 256 $APP_NAME-$NEW_VERSION.zip
\`\`\`

\`$SHA256\`
EOF

gh release edit "$NEW_TAG" --notes-file "$NOTES_FILE"

echo ""
echo "Done! Released $NEW_TAG"
echo "  GitHub: https://github.com/royalbhati/$APP_NAME/releases/tag/$NEW_TAG"
echo "  Homebrew: brew upgrade --cask hoptab"
