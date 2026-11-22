#!/bin/sh
set -u

DEFAULT_IMAGE=https://github.com/armbian/community/releases/download/26.11.0-trunk.120/Armbian_community_26.11.0-trunk.120_Orangepizero2w_trixie_current_6.18.60_minimal.img.xz
WORK_DIR=${TC_FLASH_DIR:-${HOME:-/tmp}/Downloads}
IMAGE=$DEFAULT_IMAGE
DISK=
ASSUME_YES=false
OS=$(uname -s)
BLOCK=1048576

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  return 1
}

usage() {
  say "usage: flash-sd.sh [--image FILE_OR_URL] [--disk ID] [--yes]"
  say ""
  say "Writes an operating system image to an SD card and checks the result."
  say "With no options it downloads the Armbian image for the Orange Pi Zero 2W."
}

parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      --image)
        [ $# -ge 2 ] || { usage >&2; return 1; }
        IMAGE=$2
        shift 2
        ;;
      --disk)
        [ $# -ge 2 ] || { usage >&2; return 1; }
        DISK=$2
        shift 2
        ;;
      --yes)
        ASSUME_YES=true
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        return 1
        ;;
    esac
  done
  if [ -n "$DISK" ] && ! printf '%s' "$DISK" | grep -Eq '^[A-Za-z0-9]+$'; then
    fail "that is not a valid disk name"
    return 1
  fi
}

priv() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_priv() {
  if [ "$(id -u)" -ne 0 ]; then
    say "Writing a disk needs your password."
    sudo -v
  fi
}

need_tool() {
  if command -v "$1" > /dev/null 2>&1; then
    return 0
  fi
  fail "$1 is not installed. $2"
}

check_tools() {
  need_tool curl "Install it first." || return 1
  need_tool dd "Install it first." || return 1
  need_tool cmp "Install it first." || return 1
  case $IMAGE in
    *.xz) need_tool xz "On a Mac run: brew install xz" || return 1 ;;
    *.gz) need_tool gzip "Install it first." || return 1 ;;
  esac
}

human_size() {
  awk -v b="$1" 'BEGIN { if (b < 1000000000) printf "%.0f MB", b / 1000000; else printf "%.1f GB", b / 1000000000 }'
}

list_disks_mac() {
  for ld_id in $(diskutil list external physical 2> /dev/null | sed -n 's|^/dev/\(disk[0-9][0-9]*\).*|\1|p'); do
    ld_info=$(diskutil info "$ld_id" 2> /dev/null)
    ld_size=$(printf '%s\n' "$ld_info" | sed -n 's/.*Disk Size:.*(\([0-9][0-9]*\) Bytes).*/\1/p' | head -n 1)
    ld_name=$(printf '%s\n' "$ld_info" | sed -n 's|^ *Device / Media Name: *||p' | head -n 1)
    printf '%s|%s|%s\n' "$ld_id" "${ld_size:-0}" "${ld_name:-unknown}"
  done
}

lsblk_value() {
  printf '%s' "$1" | sed -n "s/.*$2=\"\\([^\"]*\\)\".*/\\1/p"
}

list_disks_linux() {
  lsblk -dnbPo NAME,SIZE,RM,TRAN,TYPE 2> /dev/null | while IFS= read -r ll_line; do
    ll_name=$(lsblk_value "$ll_line" NAME)
    ll_size=$(lsblk_value "$ll_line" SIZE)
    ll_rm=$(lsblk_value "$ll_line" RM)
    ll_tran=$(lsblk_value "$ll_line" TRAN)
    ll_type=$(lsblk_value "$ll_line" TYPE)
    [ "$ll_type" = disk ] || continue
    if [ "$ll_rm" != 1 ] && [ "$ll_tran" != usb ]; then
      continue
    fi
    if lsblk -nro MOUNTPOINT "/dev/$ll_name" 2> /dev/null | grep -qx '/'; then
      continue
    fi
    ll_model=$(lsblk -dno MODEL "/dev/$ll_name" 2> /dev/null | sed 's/ *$//')
    printf '%s|%s|%s\n' "$ll_name" "${ll_size:-0}" "${ll_model:-unknown}"
  done
}

list_disks() {
  case $OS in
    Darwin) list_disks_mac ;;
    *) list_disks_linux ;;
  esac
}

raw_path() {
  case $OS in
    Darwin) printf '/dev/r%s' "$1" ;;
    *) printf '/dev/%s' "$1" ;;
  esac
}

unmount_disk() {
  case $OS in
    Darwin) priv diskutil unmountDisk "/dev/$1" > /dev/null ;;
    *)
      lsblk -nro MOUNTPOINT "/dev/$1" 2> /dev/null | grep -v '^$' | while IFS= read -r ud_mount; do
        priv umount "$ud_mount"
      done
      ;;
  esac
}

eject_disk() {
  case $OS in
    Darwin) diskutil eject "/dev/$1" > /dev/null 2>&1 ;;
    *) sync ;;
  esac
}

dd_write() {
  case $OS in
    Darwin) priv dd if="$1" of="$2" bs=$BLOCK ;;
    *) priv dd if="$1" of="$2" bs=$BLOCK status=progress conv=fsync ;;
  esac
}

dd_read() {
  priv dd if="$1" bs=$BLOCK count="$2" 2> /dev/null
}

after_write() {
  sync
}

pick_disk() {
  pd_list=$(list_disks)
  if [ -z "$pd_list" ]; then
    fail "no removable disks found. Put the SD card in the reader and run this again."
    return 1
  fi
  if [ -n "$DISK" ]; then
    pd_line=$(printf '%s\n' "$pd_list" | awk -F '|' -v d="$DISK" '$1 == d')
    if [ -z "$pd_line" ]; then
      fail "$DISK is not a removable disk. Refusing."
      return 1
    fi
  else
    say "Removable disks:"
    pd_n=0
    for pd_row in $(printf '%s\n' "$pd_list" | tr ' ' '_'); do
      pd_n=$((pd_n + 1))
      pd_id=${pd_row%%|*}
      pd_rest=${pd_row#*|}
      pd_bytes=${pd_rest%%|*}
      pd_name=$(printf '%s' "${pd_rest#*|}" | tr '_' ' ')
      printf '  %s) %s  %s  %s\n' "$pd_n" "$pd_id" "$(human_size "$pd_bytes")" "$pd_name"
    done
    printf 'Which one is the SD card? [1]: '
    read -r pd_choice || return 1
    pd_choice=${pd_choice:-1}
    if ! printf '%s' "$pd_choice" | grep -Eq '^[0-9]+$' || [ "$pd_choice" -lt 1 ] || [ "$pd_choice" -gt "$pd_n" ]; then
      fail "that is not one of the choices"
      return 1
    fi
    pd_line=$(printf '%s\n' "$pd_list" | sed -n "${pd_choice}p")
    DISK=${pd_line%%|*}
  fi
  DISK_BYTES=$(printf '%s' "$pd_line" | cut -d '|' -f 2)
  DISK_NAME=$(printf '%s' "$pd_line" | cut -d '|' -f 3)
}

sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

fetch_checksum() {
  curl -fsSL "$1" 2> /dev/null | awk '{print $1}' | head -n 1
}

check_download() {
  cd_expected=$(fetch_checksum "$2")
  if ! printf '%s' "$cd_expected" | grep -Eq '^[0-9A-Fa-f]{64}$'; then
    say "No checksum is published for this image, so the download was not checked."
    return 0
  fi
  cd_actual=$(sha256_of "$1")
  if [ "$cd_actual" != "$(printf '%s' "$cd_expected" | tr 'A-F' 'a-f')" ]; then
    fail "the download does not match its checksum. Delete $1 and run this again."
    return 1
  fi
  say "Download checksum matches."
}

download_image() {
  di_name=${IMAGE##*/}
  mkdir -p "$WORK_DIR" || return 1
  PACKED=$WORK_DIR/$di_name
  if [ ! -s "$PACKED" ]; then
    say "Downloading $di_name"
    curl -fL -C - --progress-bar -o "$PACKED" "$IMAGE" || { fail "the download failed"; return 1; }
  else
    say "Using the copy already in $WORK_DIR"
  fi
  check_download "$PACKED" "$IMAGE.sha"
}

unpack_image() {
  case $PACKED in
    *.xz) up_out=${PACKED%.xz}; up_cmd="xz -dc" ;;
    *.gz) up_out=${PACKED%.gz}; up_cmd="gzip -dc" ;;
    *.img)
      IMG_FILE=$PACKED
      return 0
      ;;
    *)
      fail "I only know how to write .img, .img.xz, and .img.gz files"
      return 1
      ;;
  esac
  if [ ! -s "$up_out" ] || [ "$PACKED" -nt "$up_out" ]; then
    say "Unpacking"
    $up_cmd "$PACKED" > "$up_out.part" || { rm -f "$up_out.part"; fail "could not unpack the image"; return 1; }
    mv "$up_out.part" "$up_out" || return 1
  fi
  IMG_FILE=$up_out
}

prepare_image() {
  case $IMAGE in
    http://* | https://*) download_image || return 1 ;;
    *)
      if [ ! -f "$IMAGE" ]; then
        fail "$IMAGE not found"
        return 1
      fi
      PACKED=$IMAGE
      ;;
  esac
  unpack_image || return 1
  IMG_SIZE=$(wc -c < "$IMG_FILE" | tr -d ' ')
  if [ "$IMG_SIZE" -gt "$DISK_BYTES" ]; then
    fail "the image is larger than the card"
    return 1
  fi
}

confirm_erase() {
  say ""
  say "This will ERASE everything on $DISK ($(human_size "$DISK_BYTES"), $DISK_NAME)."
  if [ "$ASSUME_YES" = true ]; then
    return 0
  fi
  printf 'Type %s to continue: ' "$DISK"
  read -r ce_answer || return 1
  if [ "$ce_answer" != "$DISK" ]; then
    say "Cancelled."
    return 1
  fi
}

write_image() {
  if [ "$OS" = Darwin ]; then
    say "Writing. Press Ctrl+T to see progress."
  else
    say "Writing."
  fi
  dd_write "$IMG_FILE" "$(raw_path "$DISK")" || { fail "the write failed"; return 1; }
  after_write
}

verify_image() {
  say "Checking what was written"
  vi_blocks=$(((IMG_SIZE + BLOCK - 1) / BLOCK))
  if dd_read "$(raw_path "$DISK")" "$vi_blocks" | head -c "$IMG_SIZE" | cmp -s - "$IMG_FILE"; then
    say "The card matches the image."
    return 0
  fi
  fail "the card does not match the image. It may be bad. Try another card."
  return 1
}

finish_up() {
  say ""
  say "Done. You can take the card out."
  say ""
  say "Next:"
  say "  1. Put the card in the board, attach a screen and keyboard, and power it on."
  say "  2. In the first-login wizard, make your user, join your Wi-Fi, and set the timezone."
  say "  3. Then run setup-node.sh on the board."
}

main() {
  parse_args "$@" || return 1
  check_tools || return 1
  pick_disk || return 1
  prepare_image || return 1
  confirm_erase || return 1
  ensure_priv || return 1
  unmount_disk "$DISK" || return 1
  write_image || return 1
  verify_image || return 1
  eject_disk "$DISK"
  finish_up
}

if [ "${FLASH_NO_MAIN:-}" != 1 ]; then
  main "$@"
fi
