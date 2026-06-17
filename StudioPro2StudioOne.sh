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

# ── UUIDs ─────────────────────────────────────────────────────────────────────

# Pro EQ
OLD_EQ_UUID="D9AE9ACD-69B4-4B43-B8D5-983E39C559A5"
NEW_EQ_UUID="073C4094-E062-4FB5-8328-74608DD1A3A4"

# Compressor (8.1 → old)
COMP_81_UUID="36F3F4D1-CBB4-4BF7-A7E3-EBCCED53718B"
COMP_OLD_UUID="54F19B72-352C-4AA5-A2AF-67F86F30D6BE"

# ── Helper: read FormatVersion ────────────────────────────────────────────────
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

# ── Helper: detect 8.1 by compressor UUID ────────────────────────────────────
is_81() {
  local file="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  unzip -q "$file" -d "$tmpdir" 2>/dev/null
  local found=false
  if grep -q "$COMP_81_UUID" "$tmpdir/Devices/audiomixer.xml" 2>/dev/null; then
    found=true
  fi
  rm -rf "$tmpdir"
  [[ "$found" == true ]]
}

# ── Helper: classify a file ───────────────────────────────────────────────────
# Returns: "81", "80", "7", or ""
classify() {
  local file="$1"
  local ver
  ver=$(get_version "$file")
  if [[ "$ver" == "9" ]]; then
    if is_81 "$file"; then
      echo "81"
    else
      echo "80"
    fi
  elif [[ "$ver" == "8" ]]; then
    echo "7"
  else
    echo ""
  fi
}

# ── Helper: process a single file ────────────────────────────────────────────
process_file() {
  local INPUT="$1"
  local CLASS="$2"   # 81, 80, or 7
  local TARGET="$3"  # "80", "SO7", or "SO6"

  local BASENAME DIRNAME OUTPUT WORKDIR
  BASENAME=$(basename "$INPUT" .song)
  DIRNAME=$(dirname "$INPUT")
  OUTPUT="${DIRNAME}/${BASENAME}_${TARGET}.song"
  WORKDIR=$(mktemp -d)

  echo ""
  echo "Processing: $(basename "$INPUT")"

  unzip -q "$INPUT" -d "$WORKDIR"

  local METAINFO="$WORKDIR/metainfo.xml"
  local AUDIOMIXER="$WORKDIR/Devices/audiomixer.xml"

  # ── Patch FormatVersion ──
  local CURRENT_VER TARGET_VER
  CURRENT_VER=$(grep -oP '(?<=<Attribute id="Document:FormatVersion" value=")[^"]+' "$METAINFO" 2>/dev/null || true)
  case "$TARGET" in
    80)  TARGET_VER="9" ;;
    SO7) TARGET_VER="8" ;;
    SO6) TARGET_VER="7" ;;
  esac

  if [[ "$CURRENT_VER" != "$TARGET_VER" ]]; then
    echo "  Patching metainfo.xml ..."
    local BEFORE
    BEFORE=$(grep -c "<Attribute id=\"Document:FormatVersion\" value=\"$CURRENT_VER\"/>" "$METAINFO" || true)
    sed -i "s|<Attribute id=\"Document:FormatVersion\" value=\"$CURRENT_VER\"/>|<Attribute id=\"Document:FormatVersion\" value=\"$TARGET_VER\"/>|g" "$METAINFO"
    if [[ "$BEFORE" -eq 0 ]]; then
      echo "  Warning: FormatVersion string not found — no changes made to metainfo.xml."
    else
      echo "  OK: $BEFORE instance(s) replaced."
    fi
  fi

  if [[ -f "$AUDIOMIXER" ]]; then
    # ── Fix Pro EQ (any FormatVersion 9 project) and Compressor (8.1 source only) ──
    if [[ "$CLASS" == "81" || "$CLASS" == "80" ]]; then
      echo "  Fixing Pro EQ$([ "$CLASS" == "81" ] && echo " and Compressor")..."
      python3 - "$WORKDIR" "$AUDIOMIXER" "$CLASS" << 'PYEOF'
import sys, os, re, json

workdir, audiomixer_path, src_class = sys.argv[1], sys.argv[2], sys.argv[3]
fix_compressor = (src_class == "81")

# Known plugin identifiers — preset-internal cid never changes between versions
PRO_EQ_CID      = "073C4094-E062-4FB5-8328-74608DD1A3A4"
COMP_CID        = "54F19B72-352C-4AA5-A2AF-67F86F30D6BE"
PRO_EQ_8_1_CLASS = "D9AE9ACD-69B4-4B43-B8D5-983E39C559A5"
COMP_8_1_CLASS   = "36F3F4D1-CBB4-4BF7-A7E3-EBCCED53718B"

renamed = 0
unhandled = []

# ── Step 1: find and convert/rename .dsppreset files ──
rename_map = {}  # old_relpath -> new_relpath

for dirpath, _, files in os.walk(workdir):
    for fn in files:
        if not fn.endswith(".dsppreset"):
            continue
        full = os.path.join(dirpath, fn)
        rel = os.path.relpath(full, workdir)
        with open(full, "rb") as f:
            raw = f.read()
        text = raw.decode("utf-8-sig", errors="ignore").lstrip()

        if text.startswith("<?xml") or text.startswith("<AudioEffectPreset"):
            # XML dsppreset — check cid
            m = re.search(r'cid="\{([0-9A-Fa-f-]{36})\}"', text)
            cid = m.group(1).upper() if m else ""
            is_comp = (cid == COMP_CID)
            is_eq   = (cid == PRO_EQ_CID)
            if is_eq or (is_comp and fix_compressor):
                new_full = full[: -len(".dsppreset")] + ".fxpreset"
                os.rename(full, new_full)
                new_rel = rel[: -len(".dsppreset")] + ".fxpreset"
                rename_map[rel] = new_rel
                renamed += 1
            # else: legitimate .dsppreset plugin (Fat Channel, Ampire, etc.), or
            # Compressor on a non-8.1 source where it's not at risk — leave untouched

        elif text.startswith("{"):
            # JSON dsppreset
            try:
                data = json.loads(text)
            except Exception:
                unhandled.append(rel + " (JSON parse error)")
                continue
            classname = data.get("classname", "unknown")
            if classname == "Compressor" and fix_compressor:
                p = data.get("parameters", {}).get("studiocomp", {})
                def get(k, default=0.0):
                    v = p.get(k, default)
                    return float(v)
                ratio = get("ratio", 2.0)
                xml_ratio = 1.0 - (1.0 / ratio) if ratio != 0 else 0.0
                xml_attack  = get("attack",  15.0)  / 1000.0
                xml_release = get("release", 120.0) / 1000.0
                ingain_db = get("ingain", 0.0)
                xml_ingain = round(10 ** (ingain_db / 20.0), 10)
                threshold = get("threshold", -10.0)
                knee      = get("knee", 6.0)
                gain      = get("gain", 0.0)
                autospeed = get("autospeed", 0.0)
                auto      = get("autogain", 0.0)
                adaptive  = get("dualband", 0.0)
                linked    = get("linked", 1.0)
                lookahead = get("lookahead", 1.0)
                resetmin  = get("resetmin", 0.0)
                mix       = get("mix", 1.0)
                isc       = get("internalsidechain", 0.0)
                scl       = get("sidechainlisten", 0.0)
                scfl      = get("sidechainfreqlow", 20.0)
                scfh      = get("sidechainfreqhigh", 16000.0)
                swap      = get("swapfreqs", 0.0)

                xml_out = (
                    '<?xml version="1.0" encoding="UTF-8"?>\n'
                    f'<AudioEffectPreset cid="{{{COMP_CID}}}" version="1" algorithmVersion="1">\n'
                    f'\t<Attributes x:id="ParameterData" linked="{int(linked)}" lookAhead="{int(lookahead)}" resetmin="{int(resetmin)}" mix="{mix!r}" ratio="{xml_ratio!r}" threshold="{threshold!r}"\n'
                    f'\t            knee="{knee!r}" auto="{int(auto)}" gain="{gain!r}" ingain="{xml_ingain!r}" autospeed="{autospeed!r}" attack="{xml_attack!r}"\n'
                    f'\t            release="{xml_release!r}" adaptive="{int(adaptive)}" internalsidechain="{int(isc)}" sidechainlisten="{int(scl)}"\n'
                    f'\t            sidechainfreqlow="{scfl!r}" sidechainfreqhigh="{scfh!r}" swapfreqs="{int(swap)}"/>\n'
                    '</AudioEffectPreset>\n'
                )
                new_full = full[: -len(".dsppreset")] + ".fxpreset"
                with open(new_full, "w", encoding="utf-8") as f:
                    f.write(xml_out)
                os.remove(full)
                new_rel = rel[: -len(".dsppreset")] + ".fxpreset"
                rename_map[rel] = new_rel
                renamed += 1
            elif classname == "Pro EQ":
                def flat(p):
                    f = {}
                    for section, vals in p.items():
                        if isinstance(vals, dict):
                            for k, v in vals.items():
                                f[k] = v
                    return f
                fp = flat(data.get("parameters", {}))
                def g(k, default=0.0):
                    return float(fp.get(k, default))

                comp = data.get("component", {}).get("autogaincomponent", {})
                legacy_auto = comp.get("legacyAutoGain", 0)

                gain_db   = g("gain", 0.0)
                xml_gain  = round(10 ** (gain_db / 20.0), 10)
                autogain2 = g("autogain", 1.0)

                fields = [
                    "linearphasesoft","linearphasefreq","linearphaseactive",
                    "lcfreq","lcslope","lcactive",
                    "lfgain","lffreq","lfq","lftype","lfactive","lfdynamic","lfdynthreshold","lfdynrange","lfsolo",
                    "lmfgain","lmffreq","lmfq","lmfactive","lmfdynamic","lmfdynthreshold","lmfdynrange","lmfsolo",
                    "mfgain","mffreq","mfq","mfactive","mfdynamic","mfdynthreshold","mfdynrange","mfsolo",
                    "hmfgain","hmffreq","hmfq","hmfactive","hmfdynamic","hmfdynthreshold","hmfdynrange","hmfsolo",
                    "hfgain","hffreq","hfq","hftype","hfactive","hfdynamic","hfdynthreshold","hfdynrange","hfsolo",
                    "hcfreq","hcslope","hcactive",
                    "highqual","showfft","analyzerRangeMin","analyzerRangeMax","viewmode",
                    "showControls","showDynamics","displayRange",
                ]
                vals = {k: g(k) for k in fields}

                def fmt(v):
                    if v == int(v):
                        return str(int(v))
                    return repr(v)

                attr_str = " ".join(f'{k}="{fmt(v)}"' for k, v in vals.items())
                xml_out = (
                    '<?xml version="1.0" encoding="UTF-8"?>\n'
                    f'<AudioEffectPreset cid="{{{PRO_EQ_CID}}}" version="1" algorithmVersion="1">\n'
                    f'\t<Attributes x:id="ParameterData" {attr_str} '
                    f'gain="{fmt(xml_gain)}" autogain2="{fmt(autogain2)}" autogain="{fmt(float(legacy_auto))}"/>\n'
                    '</AudioEffectPreset>\n'
                )
                new_full = full[: -len(".dsppreset")] + ".fxpreset"
                with open(new_full, "w", encoding="utf-8") as f:
                    f.write(xml_out)
                os.remove(full)
                new_rel = rel[: -len(".dsppreset")] + ".fxpreset"
                rename_map[rel] = new_rel
                renamed += 1
            else:
                # All other classnames (Fat Channel, Ampire, De-Esser, etc.) are
                # natively JSON .dsppreset in v7 too — no action, no warning needed.
                pass
        else:
            unhandled.append(rel + " (unrecognised format)")

# ── Step 2: patch audiomixer.xml ──
with open(audiomixer_path, "rb") as f:
    raw = f.read()
text = raw.decode("utf-8", errors="ignore")

# Global, safe UUID swaps — these classIDs are unique to these plugins' 8.1 variant
text = text.replace(PRO_EQ_8_1_CLASS, PRO_EQ_CID)
if fix_compressor:
    text = text.replace(COMP_8_1_CLASS, COMP_CID)

# Scoped presetType fix — only within ghostData blocks for Pro EQ / Compressor classIDs
known_cids = [PRO_EQ_CID] + ([COMP_CID] if fix_compressor else [])
pattern = re.compile(
    r'(<Attributes x:id="ghostData" presetType=")dsppreset(">\s*'
    r'<Attributes x:id="classInfo" classID="\{(?:' + '|'.join(known_cids) + r')\}")',
    re.DOTALL
)
text, n_preset = pattern.subn(r'\1fxpreset\2', text)

# Scoped subCategory fix — only within Compressor's classInfo block, 8.1 source only
n_sub = 0
if fix_compressor:
    sub_pattern = re.compile(
        r'(classID="\{' + COMP_CID + r'\}" name="Compressor".*?subCategory=")\(Native\)/Mixing(")',
        re.DOTALL
    )
    text, n_sub = sub_pattern.subn(r'\1(Native)/Dynamics\2', text)

# Update presetPath references for renamed files
for old_rel, new_rel in rename_map.items():
    old_path = old_rel.replace(os.sep, "/")
    new_path = new_rel.replace(os.sep, "/")
    text = text.replace(old_path, new_path)

with open(audiomixer_path, "wb") as f:
    f.write(text.encode("utf-8"))

print(f"  OK: {renamed} preset file(s) converted/renamed, {n_preset} presetType fix(es), {n_sub} subCategory fix(es).")
if unhandled:
    print("  Warning: the following plugins use .dsppreset format and were not converted")
    print("  (settings may not load correctly — provide these files to add support):")
    for u in unhandled:
        print(f"    - {u}")
PYEOF
    fi

    # ── Fix Pro EQ (already handled above for 8.1; this covers 8.0/v7 Pro EQ UUID drift if any) ──
    EQ_COUNT=$(grep -c "$OLD_EQ_UUID" "$AUDIOMIXER" || true)
    if [[ "$EQ_COUNT" -gt 0 && "$CLASS" != "81" ]]; then
      echo "  Fixing Pro EQ..."
      sed -i "s|$OLD_EQ_UUID|$NEW_EQ_UUID|g" "$AUDIOMIXER"
      echo "  OK: $EQ_COUNT instance(s) replaced."
    fi
  else
    echo "  Warning: Devices/audiomixer.xml not found — skipping."
  fi

  # ── Re-archive ──
  echo "  Saving to: $(basename "$OUTPUT")"
  (cd "$WORKDIR" && zip -qr - .) > "$OUTPUT"
  rm -rf "$WORKDIR"
}

# ── Scan all files ────────────────────────────────────────────────────────────
echo ""
echo "Scanning $([ $# -eq 1 ] && echo "1 file" || echo "$# files")..."

HAS_81=false
HAS_80=false
HAS_V7=false
SKIPPED=()
declare -A FILE_CLASS

for f in "$@"; do
  CL=$(classify "$f")
  FILE_CLASS["$f"]="$CL"
  case "$CL" in
    81) HAS_81=true ;;
    80) HAS_80=true ;;
    7)  HAS_V7=true ;;
    *)  SKIPPED+=("$(basename "$f") (unrecognised version)") ;;
  esac
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
RESET="\033[0m"

NOTE="All files will be converted at once and placed in the same folder as the original. The original .song file will stay intact."

single=false
[[ $# -eq 1 ]] && single=true

show_note() {
  if [[ "$single" == false ]]; then
    echo ""
    echo "$NOTE"
  fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────
TARGET=""

if $HAS_81 && ! $HAS_80 && ! $HAS_V7; then
  INTRO=$($single && echo "This is a Studio Pro v8.1 Project." || echo "These are Studio Pro v8.1 Projects.")
  echo ""; echo "$INTRO How should We proceed?"
  echo ""
  echo -e "${GREEN}  1) Convert to Studio Pro 8.0"
  echo "  2) Convert to Studio One 7"
  echo "  3) Convert to Studio One 6"
  echo -e "  4) Cancel${RESET}"
  show_note; echo ""
  read -rp "Enter your choice [1/2/3/4]: " CHOICE
  case "$CHOICE" in
    1) TARGET="80" ;;
    2) TARGET="SO7" ;;
    3) TARGET="SO6" ;;
    4) echo "Cancelled."; exit 0 ;;
    *) echo "Invalid choice. Aborting."; exit 1 ;;
  esac

elif $HAS_80 && ! $HAS_81 && ! $HAS_V7; then
  INTRO=$($single && echo "This is a Studio Pro v8.0 Project." || echo "These are Studio Pro v8.0 Projects.")
  echo ""; echo "$INTRO How should We proceed?"
  echo ""
  echo -e "${GREEN}  1) Convert to Studio One 7"
  echo "  2) Convert to Studio One 6"
  echo -e "  3) Cancel${RESET}"
  show_note; echo ""
  read -rp "Enter your choice [1/2/3]: " CHOICE
  case "$CHOICE" in
    1) TARGET="SO7" ;;
    2) TARGET="SO6" ;;
    3) echo "Cancelled."; exit 0 ;;
    *) echo "Invalid choice. Aborting."; exit 1 ;;
  esac

elif $HAS_V7 && ! $HAS_81 && ! $HAS_80; then
  INTRO=$($single && echo "This is a Studio One v7 Project." || echo "These are Studio One v7 Projects.")
  echo ""; echo "$INTRO How should We proceed?"
  echo ""
  echo -e "${GREEN}  1) Convert to Studio One 6"
  echo -e "  2) Cancel${RESET}"
  show_note; echo ""
  read -rp "Enter your choice [1/2]: " CHOICE
  case "$CHOICE" in
    1) TARGET="SO6" ;;
    2) echo "Cancelled."; exit 0 ;;
    *) echo "Invalid choice. Aborting."; exit 1 ;;
  esac

else
  echo ""
  echo "Mixed project versions detected. How should we proceed?"
  echo ""
  echo -e "${GREEN}  1) Convert to Studio Pro 8.0  (8.1 files only; others skipped)"
  echo "  2) Convert to Studio One 7   (8.1 and 8.0 files; v7 files skipped)"
  echo "  3) Convert to Studio One 6   (all files converted)"
  echo -e "  4) Cancel${RESET}"
  show_note; echo ""
  read -rp "Enter your choice [1/2/3/4]: " CHOICE
  case "$CHOICE" in
    1) TARGET="80" ;;
    2) TARGET="SO7" ;;
    3) TARGET="SO6" ;;
    4) echo "Cancelled."; exit 0 ;;
    *) echo "Invalid choice. Aborting."; exit 1 ;;
  esac
fi

# ── Process all files ─────────────────────────────────────────────────────────
DONE=0
SKIPPED_CONVERT=0

for f in "$@"; do
  CL="${FILE_CLASS[$f]}"
  [[ -z "$CL" ]] && continue

  SKIP=false
  case "$TARGET" in
    80)  [[ "$CL" != "81" ]] && SKIP=true ;;
    SO7) [[ "$CL" == "7"  ]] && SKIP=true ;;
    SO6) ;;
  esac

  if $SKIP; then
    echo ""
    case "$CL" in
      80) echo "Skipping: $(basename "$f") — already a Studio Pro 8.0 project." ;;
      7)  echo "Skipping: $(basename "$f") — already a Studio One v7 project." ;;
    esac
    (( SKIPPED_CONVERT++ )) || true
  else
    process_file "$f" "$CL" "$TARGET"
    (( DONE++ )) || true
  fi
done

echo ""
if [[ "$SKIPPED_CONVERT" -gt 0 ]]; then
  echo "Done! $DONE file(s) converted, $SKIPPED_CONVERT skipped (already at target version)."
else
  echo "Done! $DONE file(s) converted."
fi
