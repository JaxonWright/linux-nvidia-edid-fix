#!/bin/bash
set -euo pipefail

VERSION="1.0.0"
EDID_DIR="/lib/firmware/edid"
BOOT_BACKUP_DIR="/var/backups/edid-fix"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
header(){ echo -e "\n${BLUE}==${NC} ${BLUE}$*${NC}"; }

DRY_RUN=false
FORCE=false
REVERT=false

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Fixes NVIDIA GPU EDID issues over DisplayPort 1.4 by forcing the monitor's
real EDID via the kernel drm.edid_firmware parameter.

Works around: Monitor detected only at 640x480 over DP 1.4 (fake NVIDIA EDID).

Requires: Monitor must be in DP 1.2 mode (or any mode where EDID is read
          correctly) when running. If the script detects only a dummy EDID,
          it will instruct you to switch the monitor's OSD to DP 1.2 first.

Options:
  --dry-run         Preview changes without applying
  --force           Skip confirmation prompts
  --revert          Remove the EDID fix and restore original boot config
  --help, -h        Show this help message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --force) FORCE=true; shift ;;
        --revert) REVERT=true; shift ;;
        --help|-h) usage ;;
        *) error "Unknown option: $1"; usage ;;
    esac
done

[ "$(id -u)" -ne 0 ] && { error "This script must be run as root (use sudo)"; exit 1; }

header "NVIDIA DP 1.4 EDID Fix v$VERSION"

# --- Dependency check ---
for cmd in dd od wc grep sed ls head tr cat mkdir cp basename awk; do
    command -v "$cmd" &>/dev/null || { error "Missing required tool: $cmd"; exit 1; }
done

# --- Helpers ---
read_edid_byte() {
    dd if="$1/edid" bs=1 skip="$2" count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n'
}

get_edid_size() {
    wc -c < "$1/edid" 2>/dev/null || echo 0
}

is_connected() {
    [ "$(cat "$1/status" 2>/dev/null)" = "connected" ]
}

is_dummy_edid() {
    local size b8 b9
    size=$(get_edid_size "$1")
    [ "$size" -ne 128 ] && return 1
    b8=$(read_edid_byte "$1" 8)
    b9=$(read_edid_byte "$1" 9)
    [ "$b8" = "3a" ] && [ "$b9" = "c4" ]
}

has_valid_edid() {
    local size
    size=$(get_edid_size "$1")
    [ "$size" -ge 256 ]
}

decode_pnp_id() {
    local b8 b9
    b8=$(read_edid_byte "$1" 8)
    b9=$(read_edid_byte "$1" 9)
    [ -z "$b8" ] || [ -z "$b9" ] && { echo "unknown"; return; }
    local c1 c2 c3
    c1=$(( (0x$b8 >> 2) & 0x1f ))
    c2=$(( ((0x$b8 & 0x3) << 3) | (0x$b9 >> 5) ))
    c3=$(( 0x$b9 & 0x1f ))
    awk -v a="$((c1+64))" -v b="$((c2+64))" -v c="$((c3+64))" 'BEGIN{printf "%c%c%c", a, b, c}'
}

get_connector_name() {
    basename "$1"
}

get_modes() {
    cat "$1/modes" 2>/dev/null | tr '\n' ' ' || echo "none"
}

get_basename_stripped() {
    local name
    name=$(get_connector_name "$1")
    name="${name#card*-}"
    echo "$name"
}

# --- Bootloader detection ---
detect_bootloader() {
    if [ -d /boot/loader/entries ] && ls /boot/loader/entries/*.conf &>/dev/null; then
        local entry
        entry=$(ls -t /boot/loader/entries/*.conf 2>/dev/null | head -1)
        if [ -n "$entry" ] && grep -q "^options" "$entry" 2>/dev/null; then
            BOOT_CONFIG="$entry"
            BOOT_TYPE="systemd-boot"
            return 0
        fi
    fi
    if [ -f /etc/default/grub ]; then
        BOOT_CONFIG="/etc/default/grub"
        BOOT_TYPE="grub"
        return 0
    fi
    return 1
}

add_kernel_param() {
    local param="$1"
    case "$BOOT_TYPE" in
        systemd-boot)
            if grep -q "drm.edid_firmware" "$BOOT_CONFIG"; then
                warn "Kernel parameter 'drm.edid_firmware' already present in $BOOT_CONFIG"
                return 0
            fi
            if [ "$DRY_RUN" = false ]; then
                BOOT_BACKUP=$(mktemp -p "$BOOT_BACKUP_DIR" "boot-entry-$(date +%s)-XXXXXXXX.conf" 2>/dev/null || echo "")
                if [ -n "$BOOT_BACKUP" ]; then
                    cp "$BOOT_CONFIG" "$BOOT_BACKUP"
                fi
                sed -i "s|^options|options $param|" "$BOOT_CONFIG"
                ok "Added '$param' to $BOOT_CONFIG"
                [ -n "$BOOT_BACKUP" ] && info "Backup: $BOOT_BACKUP"
            else
                info "[DRY-RUN] Would add '$param' to $BOOT_CONFIG"
            fi
            ;;
        grub)
            local grub_line='GRUB_CMDLINE_LINUX_DEFAULT'
            local current
            current=$(grep "^${grub_line}=" "$BOOT_CONFIG" 2>/dev/null | head -1 || true)
            if echo "$current" | grep -q "drm.edid_firmware"; then
                warn "Kernel parameter 'drm.edid_firmware' already present in $BOOT_CONFIG"
                return 0
            fi
            if [ -z "$current" ]; then
                error "Could not find '$grub_line' in $BOOT_CONFIG"
                error "Add the parameter '$param' manually to GRUB_CMDLINE_LINUX_DEFAULT"
                exit 1
            fi
            if [ "$DRY_RUN" = false ]; then
                BOOT_BACKUP=$(mktemp -p "$BOOT_BACKUP_DIR" "grub-$(date +%s)-XXXXXXXX" 2>/dev/null || echo "")
                if [ -n "$BOOT_BACKUP" ]; then
                    cp "$BOOT_CONFIG" "$BOOT_BACKUP"
                fi
                sed -i "s|^${grub_line}=\"\(.*\)\"$|${grub_line}=\"\1 $param\"|" "$BOOT_CONFIG"
                ok "Added '$param' to $BOOT_CONFIG"
                [ -n "$BOOT_BACKUP" ] && info "Backup: $BOOT_BACKUP"
            else
                info "[DRY-RUN] Would add '$param' to $BOOT_CONFIG"
            fi
            ;;
    esac
}

# --- Revert ---
do_revert() {
    header "Revert"
    info "Searching for EDID files installed by this script..."
    local found=false
    for f in "$EDID_DIR"/*.bin; do
        [ -f "$f" ] || continue
        if grep -q "drm.edid_firmware.*$(basename "$f")" "$BOOT_CONFIG" 2>/dev/null; then
            found=true
            if [ "$DRY_RUN" = false ]; then
                rm "$f"
                ok "Removed $f"
            else
                info "[DRY-RUN] Would remove $f"
            fi
        fi
    done
    if [ "$found" = false ]; then
        warn "No EDID files found in $EDID_DIR that match boot config"
    fi

    info "Restoring boot config from backup..."
    local latest_backup=""
    if [ -d "$BOOT_BACKUP_DIR" ]; then
        latest_backup=$(ls -t "$BOOT_BACKUP_DIR"/* 2>/dev/null | head -1)
    fi
    if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
        if [ "$DRY_RUN" = false ]; then
            cp "$latest_backup" "$BOOT_CONFIG"
            ok "Restored $BOOT_CONFIG from $latest_backup"
        else
            info "[DRY-RUN] Would restore $BOOT_CONFIG from $latest_backup"
        fi
    else
        warn "No backups found in $BOOT_BACKUP_DIR"
        warn "You'll need to manually remove 'drm.edid_firmware=...' from kernel cmdline"
    fi

    if [ "$DRY_RUN" = false ]; then
        case "$BOOT_TYPE" in
            grub)
                info "Run 'grub-mkconfig -o /boot/grub/grub.cfg' to apply the reverted config"
                ;;
        esac
        echo
        info "Revert complete. Reboot to apply."
    fi
    exit 0
}

# ===========================================================================
# Main
# ===========================================================================

if [ "$REVERT" = true ]; then
    detect_bootloader || { error "Bootloader detection failed. Revert manually."; exit 1; }
    do_revert
fi

# --- Detect bootloader ---
detect_bootloader || { error "Bootloader detection failed. Unsupported bootloader?"; exit 1; }

# --- Find DRM connectors ---
DRM_DIRS=()
for d in /sys/class/drm/card*-*-*; do
    [ -d "$d" ] || continue
    DRM_DIRS+=("$d")
done

if [ ${#DRM_DIRS[@]} -eq 0 ]; then
    error "No DRM connectors found at /sys/class/drm/"
    exit 1
fi

# --- Classify connectors ---
DUMMY_CONNECTORS=()
VALID_CONNECTORS=()
OTHER_CONNECTORS=()

for d in "${DRM_DIRS[@]}"; do
    is_connected "$d" || continue
    connector_name=$(get_basename_stripped "$d")
    # Skip eDP (internal laptop displays)
    case "$connector_name" in
        eDP*|LVDS*|DSI*) OTHER_CONNECTORS+=("$d"); continue ;;
    esac
    if is_dummy_edid "$d"; then
        DUMMY_CONNECTORS+=("$d")
    elif has_valid_edid "$d"; then
        VALID_CONNECTORS+=("$d")
    else
        OTHER_CONNECTORS+=("$d")
    fi
done

# --- Status summary ---
header "Detected External Connectors"
for d in "${DRM_DIRS[@]}"; do
    is_connected "$d" || continue
    cname=$(get_basename_stripped "$d")
    size=$(get_edid_size "$d")
    pnp=$(decode_pnp_id "$d" 2>/dev/null || echo "?")
    modes=$(get_modes "$d")
    modes="${modes:0:60}..."
    if is_dummy_edid "$d"; then
        warn "  $cname - DUMMY EDID (${size}B, manuf=$pnp, modes: $modes)"
    elif has_valid_edid "$d"; then
        ok "  $cname - VALID EDID (${size}B, manuf=$pnp, modes: $modes)"
    else
        info "  $cname - other (${size}B, manuf=$pnp)"
    fi
done

# --- Decision ---
CONNECTOR_TO_FIX=""

if [ ${#DUMMY_CONNECTORS[@]} -eq 0 ]; then
    echo
    info "No dummy NVIDIA EDID detected — no issue found on this system."
    info "All connected displays have valid EDIDs and should work correctly."
    echo
    info "If you're sure the DP 1.4 issue is present but wasn't detected:"
    info "  The script may need to run while your monitor is in DP 1.4 mode."
    info "  Switch the monitor OSD to DP 1.4, then re-run this script."
    exit 0
fi

echo
if [ ${#VALID_CONNECTORS[@]} -eq 0 ]; then
    error "Found ${#DUMMY_CONNECTORS[@]} connector(s) with dummy NVIDIA EDID but no valid EDID."
    echo
    info "Your monitor likely needs to be switched to DP 1.2 mode in its OSD."
    info "The monitor will correctly report its EDID in DP 1.2 mode."
    info "Steps:"
    info "  1. Switch your monitor to DP 1.2 (via OSD menu)"
    info "  2. Run this script again"
    info "  3. When prompted, switch back to DP 1.4 and reboot"
    exit 1
fi

echo
info "${#DUMMY_CONNECTORS[@]} problematic connector(s) and ${#VALID_CONNECTORS[@]} valid EDID source(s) found."

if [ ${#DUMMY_CONNECTORS[@]} -eq 1 ]; then
    CONNECTOR_TO_FIX="${DUMMY_CONNECTORS[0]}"
else
    warn "Multiple connectors with dummy EDID found."
    echo
    for i in "${!DUMMY_CONNECTORS[@]}"; do
        cname=$(get_basename_stripped "${DUMMY_CONNECTORS[$i]}")
        echo "  [$i] $cname"
    done
    read -r -p "Select connector to fix [0-$(( ${#DUMMY_CONNECTORS[@]} - 1 ))]: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -lt "${#DUMMY_CONNECTORS[@]}" ]; then
        CONNECTOR_TO_FIX="${DUMMY_CONNECTORS[$sel]}"
    else
        error "Invalid selection"
        exit 1
    fi
fi

# --- Find matching valid EDID ---
VALID_SOURCE=""
if [ ${#VALID_CONNECTORS[@]} -eq 1 ]; then
    VALID_SOURCE="${VALID_CONNECTORS[0]}"
else
    echo
    warn "Multiple valid EDID sources found. Select which monitor's EDID to use:"
    for i in "${!VALID_CONNECTORS[@]}"; do
        cname=$(get_basename_stripped "${VALID_CONNECTORS[$i]}")
        pnp=$(decode_pnp_id "${VALID_CONNECTORS[$i]}")
        echo "  [$i] $cname (manuf: $pnp)"
    done
    read -r -p "Select EDID source [0-$(( ${#VALID_CONNECTORS[@]} - 1 ))]: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -lt "${#VALID_CONNECTORS[@]}" ]; then
        VALID_SOURCE="${VALID_CONNECTORS[$sel]}"
    else
        error "Invalid selection"
        exit 1
    fi
fi

# --- Confirm ---
CONNECTOR_NAME=$(get_basename_stripped "$CONNECTOR_TO_FIX")
MANUF=$(decode_pnp_id "$VALID_SOURCE")
EDID_SIZE=$(get_edid_size "$VALID_SOURCE")
VALID_NAME=$(get_basename_stripped "$VALID_SOURCE")

echo
cat <<EOF
Ready to apply fix:

  Problem connector:  $CONNECTOR_NAME
  EDID source:        $VALID_NAME
  Monitor manufacturer: $MANUF
  EDID size:          ${EDID_SIZE} bytes
  EDID destination:   $EDID_DIR/$CONNECTOR_NAME.bin
  Kernel parameter:   drm.edid_firmware=$CONNECTOR_NAME:edid/$CONNECTOR_NAME.bin
  Bootloader:         $BOOT_TYPE ($BOOT_CONFIG)

EOF

if [ "$FORCE" = false ]; then
    read -r -p "Apply this fix? [y/N] " confirm
    case "$confirm" in
        y|Y) ;;
        *) info "Cancelled."; exit 0 ;;
    esac
fi

# --- Apply ---
header "Applying Fix"

mkdir -p "$EDID_DIR"
mkdir -p "$BOOT_BACKUP_DIR"

if [ "$DRY_RUN" = true ]; then
    info "[DRY-RUN] Would copy $VALID_SOURCE/edid -> $EDID_DIR/$CONNECTOR_NAME.bin"
else
    cp "$VALID_SOURCE/edid" "$EDID_DIR/$CONNECTOR_NAME.bin"
    ok "Copied EDID to $EDID_DIR/$CONNECTOR_NAME.bin (${EDID_SIZE} bytes)"
fi

add_kernel_param "drm.edid_firmware=$CONNECTOR_NAME:edid/$CONNECTOR_NAME.bin"

# --- Post-install instructions ---
echo
case "$BOOT_TYPE" in
    grub)
        echo -e "${YELLOW}IMPORTANT: You use GRUB.${NC}"
        info "Run this command to regenerate your GRUB config:"
        info "  sudo grub-mkconfig -o /boot/grub/grub.cfg"
        echo
        ;;
esac

echo
info "Fix applied successfully!"
echo
info "Next steps:"
info "  1. Switch your monitor's OSD back to DP 1.4 mode"
if [ "$BOOT_TYPE" = "grub" ]; then
    info "  2. Run 'sudo grub-mkconfig -o /boot/grub/grub.cfg'"
    info "  3. Reboot your system"
else
    info "  2. Reboot your system"
fi
info "  3. Monitor should now display at full resolution over DP 1.4"
echo
info "To revert: sudo $0 --revert"
