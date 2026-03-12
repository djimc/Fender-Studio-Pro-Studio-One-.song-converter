#!/bin/bash
# Usage: ./StudioPro2StudioOne.sh <file1.song> [file2.song ...]

# ── Validate arguments ────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <file1.song> [file2.song ...]"
  exit 1
fi

for f in "$@"; do
  if [[ ! -f "$f" ]]; then
    echo "Error: File '$f' not found."
    exit 1
  fi
done

OLD_UUID="D9AE9ACD-69B4-4B43-B8D5-983E39C559A5"
NEW_UUID="073C4094-E062-4FB5-8328-74608DD1A3A4"

# ── Helper: read FormatVersion from a .song file ──────────────────────────────
get_version() {
  local file="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  unzip -q "$file" -d "$tmpdir" 2>/dev/null
  local ver
  ver=$(grep -oP '(?<=<Attribute id="Document:FormatVersion" value=")[^"]+' "$tmpdir/metainfo.xml" 2>/dev/null || true)
  rm -rf "$tmpdir"
  echo "$ver"
}

# ── Helper: process a single file ────────────────────────────────────────────
process_file() {
  local INPUT="$1"
  local TARGET_VERSION="$2"
  local SUFFIX="$3"

  local BASENAME DIRNAME OUTPUT WORKDIR
  BASENAME=$(basename "$INPUT" .song)
  DIRNAME=$(dirname "$INPUT")
  OUTPUT="${DIRNAME}/${BASENAME}_${SUFFIX}.song"
  WORKDIR=$(mktemp -d)

  echo ""
  echo "Processing: $(basename "$INPUT")"

  unzip -q "$INPUT" -d "$WORKDIR"

  local METAINFO="$WORKDIR/metainfo.xml"
  local CURRENT_VERSION
  CURRENT_VERSION=$(grep -oP '(?<=<Attribute id="Document:FormatVersion" value=")[^"]+' "$METAINFO" 2>/dev/null || true)

  # Patch metainfo.xml
  echo "  Patching metainfo.xml ..."
  local BEFORE
  BEFORE=$(grep -c "<Attribute id=\"Document:FormatVersion\" value=\"$CURRENT_VERSION\"/>" "$METAINFO" || true)
  sed -i "s|<Attribute id=\"Document:FormatVersion\" value=\"$CURRENT_VERSION\"/>|<Attribute id=\"Document:FormatVersion\" value=\"$TARGET_VERSION\"/>|g" "$METAINFO"
  if [[ "$BEFORE" -eq 0 ]]; then
    echo "  Warning: FormatVersion string not found — no changes made to metainfo.xml."
  else
    echo "  OK: $BEFORE instance(s) replaced."
  fi

  # Patch audiomixer.xml
  local AUDIOMIXER="$WORKDIR/Devices/audiomixer.xml"
  if [[ -f "$AUDIOMIXER" ]]; then
    echo "  Fixing Pro EQ..."
    local COUNT
    COUNT=$(grep -c "$OLD_UUID" "$AUDIOMIXER" || true)
    if [[ "$COUNT" -eq 0 ]]; then
      echo "  No need to fix Pro EQ."
    else
      sed -i "s|$OLD_UUID|$NEW_UUID|g" "$AUDIOMIXER"
      echo "  OK: $COUNT instance(s) replaced."
    fi
  else
    echo "  Warning: Devices/audiomixer.xml not found — skipping."
  fi

  # Re-archive
  echo "  Saving to: $(basename "$OUTPUT")"
  (cd "$WORKDIR" && zip -qr - .) > "$OUTPUT"
  rm -rf "$WORKDIR"
}

# ── Scan all files and collect versions ──────────────────────────────────────
echo ""
echo "Scanning $([ $# -eq 1 ] && echo "1 file" || echo "$# files")..."

HAS_V9=false
HAS_V8=false
SKIPPED=()

for f in "$@"; do
  VER=$(get_version "$f")
  if [[ "$VER" == "9" ]]; then
    HAS_V9=true
  elif [[ "$VER" == "8" ]]; then
    HAS_V8=true
  else
    SKIPPED+=("$f (unrecognised version: $VER)")
  fi
done

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo ""
  echo "  The following file(s) will be skipped (no conversion available):"
  for s in "${SKIPPED[@]}"; do
    echo "    - $s"
  done
fi

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN="\033[0;32m"
RED="\033[0;31m"
RESET="\033[0m"

NOTE="All files will be converted at once and placed in the same folder as the original. The original .song file will stay intact."

# ── Singular or plural intro ──────────────────────────────────────────────────
if [[ $# -eq 1 ]]; then
  INTRO_V9="This is a Studio Pro v8 Project. How should We proceed?"
  INTRO_V8="This is a Studio One v7 Project. How should We proceed?"
else
  INTRO_V9="These are Studio Pro v8 Projects. How should We proceed?"
  INTRO_V8="These are Studio One v7 Projects. How should We proceed?"
fi

# ── Determine menu based on versions found ────────────────────────────────────
TARGET_VERSION=""
SUFFIX=""

if $HAS_V9 && ! $HAS_V8; then
  echo ""
  echo "$INTRO_V9"
  echo ""
  echo -e "${GREEN}  1) Convert to Studio One 7"
  echo "  2) Convert to Studio One 6"
  echo -e "  3) Cancel${RESET}"
  echo ""
  echo "$NOTE"
  echo ""
  read -rp "Enter your choice [1/2/3]: " CHOICE
  case "$CHOICE" in
    1) TARGET_VERSION="8"; SUFFIX="SO7" ;;
    2) TARGET_VERSION="7"; SUFFIX="SO6" ;;
    3) echo "Cancelled."; exit 0 ;;
    *) echo "Invalid choice. Aborting."; exit 1 ;;
  esac

elif $HAS_V8 && ! $HAS_V9; then
  echo ""
  echo "$INTRO_V8"
  echo ""
  echo -e "${GREEN}  1) Convert to Studio One 6"
  echo -e "  2) Cancel${RESET}"
  echo ""
  echo "$NOTE"
  echo ""
  read -rp "Enter your choice [1/2]: " CHOICE
  case "$CHOICE" in
    1) TARGET_VERSION="7"; SUFFIX="SO6" ;;
    2) echo "Cancelled."; exit 0 ;;
    *) echo "Invalid choice. Aborting."; exit 1 ;;
  esac

elif $HAS_V9 && $HAS_V8; then
  echo ""
  echo "Mixed project versions detected (Studio Pro v8 and Studio One v7). How should we proceed?"
  echo ""
  echo -e "${GREEN}  1) Convert to Studio One 7  (Studio One v7 files will be skipped — already at this version)"
  echo "  2) Convert to Studio One 6  (all files will be converted)"
  echo -e "  3) Cancel${RESET}"
  echo ""
  echo "$NOTE"
  echo ""
  read -rp "Enter your choice [1/2/3]: " CHOICE
  case "$CHOICE" in
    1) TARGET_VERSION="8"; SUFFIX="SO7" ;;
    2) TARGET_VERSION="7"; SUFFIX="SO6" ;;
    3) echo "Cancelled."; exit 0 ;;
    *) echo "Invalid choice. Aborting."; exit 1 ;;
  esac

else
  echo ""
  echo "No convertible files found. Aborting."
  exit 1
fi

# ── Process all files ─────────────────────────────────────────────────────────
DONE=0
SKIPPED_CONVERT=0
for f in "$@"; do
  VER=$(get_version "$f")
  if [[ "$VER" == "9" || "$VER" == "8" ]]; then
    if [[ "$VER" == "8" && "$TARGET_VERSION" == "8" ]]; then
      echo ""
      echo "Skipping: $(basename "$f") — already a Studio One v7 project."
      (( SKIPPED_CONVERT++ )) || true
    else
      process_file "$f" "$TARGET_VERSION" "$SUFFIX"
      (( DONE++ )) || true
    fi
  fi
done

echo ""
if [[ "$SKIPPED_CONVERT" -gt 0 ]]; then
  echo "Done! $DONE file(s) converted, $SKIPPED_CONVERT skipped (already at target version)."
else
  echo "Done! $DONE file(s) converted."
fi
