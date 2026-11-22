#!/bin/sh
set -u

TESTED_TAG=26.11.0-trunk.120
TESTED_URL=https://github.com/armbian/community/releases/download/26.11.0-trunk.120/Armbian_community_26.11.0-trunk.120_Orangepizero2w_trixie_current_6.18.60_minimal.img.xz
KNOWN_BAD_TAGS="26.11.0-trunk.137"
RELEASES_API='https://api.github.com/repos/armbian/community/releases?per_page=6'
WORK_DIR=${TC_FLASH_DIR:-${HOME:-/tmp}/Downloads}
IMAGE=
DISK=
ASSUME_YES=false
HEADLESS=ask
OS=$(uname -s)
BLOCK=1048576
BIG_DISK_BYTES=512000000000
PRESET_COPY=
PRESET_TMP=

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  return 1
}

usage() {
  say "usage: flash-sd.sh [--image FILE_OR_URL] [--disk ID] [--headless | --no-headless] [--yes]"
  say ""
  say "Writes an operating system image to an SD card and checks the result."
  say "With no options it shows a menu of images. Armbian images can also be"
  say "set up to join Wi-Fi and create your user on first boot, with no screen."
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
      --headless)
        HEADLESS=yes
        shift
        ;;
      --no-headless)
        HEADLESS=no
        shift
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

cleanup() {
  [ -n "${PRESET_COPY:-}" ] && rm -f "$PRESET_COPY"
  [ -n "${PRESET_TMP:-}" ] && rm -f "$PRESET_TMP"
  return 0
}

running_as_root() {
  [ "$(id -u)" -eq 0 ]
}

priv() {
  if running_as_root; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_priv() {
  if ! running_as_root; then
    say "Writing a disk needs your password."
    sudo -v
  fi
}

package_manager() {
  if [ "$OS" = Darwin ]; then
    command -v brew > /dev/null 2>&1 && printf 'brew'
    return 0
  fi
  for pm_name in apt-get dnf pacman zypper apk; do
    if command -v "$pm_name" > /dev/null 2>&1; then
      printf '%s' "$pm_name"
      return 0
    fi
  done
}

package_for() {
  case $1 in
    xz)
      if [ "$2" = apt-get ]; then
        printf 'xz-utils'
      else
        printf 'xz'
      fi
      ;;
    cmp) printf 'diffutils' ;;
    dd) printf 'coreutils' ;;
    debugfs) printf 'e2fsprogs' ;;
    *) printf '%s' "$1" ;;
  esac
}

confirm_install() {
  if [ "$ASSUME_YES" = true ]; then
    return 0
  fi
  printf '%s is needed but not installed. Install %s with %s? [Y/n]: ' "$1" "$2" "${3%-get}"
  read -r ci_answer || return 1
  case $ci_answer in
    '' | [Yy] | [Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

install_tool() {
  it_mgr=$(package_manager)
  if [ -z "$it_mgr" ]; then
    if [ "$OS" = Darwin ]; then
      fail "$1 is missing and Homebrew is not installed. Get Homebrew from https://brew.sh and run this again."
    else
      fail "$1 is missing and no package manager was found. Install it by hand."
    fi
    return 1
  fi
  if [ "$it_mgr" = brew ] && running_as_root; then
    fail "$1 is missing. Run this without sudo so Homebrew can install it. It asks for your password when needed."
    return 1
  fi
  it_pkg=$(package_for "$1" "$it_mgr")
  if ! confirm_install "$1" "$it_pkg" "$it_mgr"; then
    fail "$1 is needed. Install it and run this again."
    return 1
  fi
  say "Installing $it_pkg"
  case $it_mgr in
    brew) brew install "$it_pkg" ;;
    apt-get) priv apt-get update -qq && priv apt-get install -y "$it_pkg" ;;
    dnf) priv dnf install -y "$it_pkg" ;;
    pacman) priv pacman -S --noconfirm "$it_pkg" ;;
    zypper) priv zypper --non-interactive install "$it_pkg" ;;
    apk) priv apk add "$it_pkg" ;;
  esac
}

need_tool() {
  if command -v "$1" > /dev/null 2>&1; then
    return 0
  fi
  install_tool "$1" || return 1
  hash -r 2> /dev/null
  if ! command -v "$1" > /dev/null 2>&1; then
    fail "$1 is still missing after the install"
    return 1
  fi
}

locate_debugfs() {
  DEBUGFS=
  for ld_path in "$(command -v debugfs 2> /dev/null)" /opt/homebrew/opt/e2fsprogs/sbin/debugfs /usr/local/opt/e2fsprogs/sbin/debugfs /sbin/debugfs /usr/sbin/debugfs; do
    if [ -n "$ld_path" ] && [ -x "$ld_path" ]; then
      DEBUGFS=$ld_path
      return 0
    fi
  done
  return 1
}

need_debugfs() {
  locate_debugfs && return 0
  install_tool debugfs || return 1
  hash -r 2> /dev/null
  if ! locate_debugfs; then
    fail "debugfs is still missing after the install"
    return 1
  fi
}

check_tools() {
  need_tool curl || return 1
  need_tool dd || return 1
  need_tool cmp || return 1
  case $IMAGE in
    *.xz) need_tool xz || return 1 ;;
    *.gz) need_tool gzip || return 1 ;;
  esac
}

human_size() {
  awk -v b="$1" 'BEGIN { if (b < 1000000000) printf "%.0f MB", b / 1000000; else printf "%.1f GB", b / 1000000000 }'
}

is_armbian() {
  case ${1##*/} in
    [Aa]rmbian*) return 0 ;;
  esac
  return 1
}

image_label() {
  il_name=${1##*/}
  il_name=${il_name%.img.xz}
  il_name=${il_name#Armbian_community_}
  il_tag=${il_name%%_*}
  il_rest=${il_name#*_}
  il_board=${il_rest%%_*}
  il_rest=${il_rest#*_}
  il_distro=${il_rest%%_*}
  il_rest=${il_rest#*_}
  il_branch=${il_rest%%_*}
  il_rest=${il_rest#*_}
  il_kernel=${il_rest%%_*}
  il_variant=${il_rest#*_}
  printf 'Armbian %s, %s, %s %s, kernel %s, %s' "${il_tag#*-}" "$il_board" "$il_distro" "$il_branch" "$il_kernel" "$il_variant"
}

discover_images() {
  curl -fsSL --max-time 15 "$RELEASES_API" 2> /dev/null |
    grep -o 'Armbian_community_[^"]*_Orangepizero2w_[^"]*\.img\.xz' |
    sort -u -r -V |
    head -n 6 |
    while IFS= read -r di_name; do
      di_tag=${di_name#Armbian_community_}
      di_tag=${di_tag%%_*}
      printf '%s|https://github.com/armbian/community/releases/download/%s/%s\n' "$(image_label "$di_name")" "$di_tag" "$di_name"
    done
}

image_status() {
  is_url=$1
  if [ "$is_url" = "$TESTED_URL" ]; then
    printf 'TESTED/WORKING'
    return 0
  fi
  for is_bad in $KNOWN_BAD_TAGS; do
    case $is_url in
      *"/$is_bad/"*)
        printf 'KNOWN BAD: did not boot'
        return 0
        ;;
    esac
  done
  printf 'untested'
}

build_catalog() {
  printf '%s|%s\n' "$(image_label "${TESTED_URL##*/}" | sed 's/Orangepizero2w/Orange Pi Zero 2W/')" "$TESTED_URL"
  discover_images | while IFS= read -r bc_line; do
    bc_url=${bc_line#*|}
    [ "$bc_url" = "$TESTED_URL" ] && continue
    printf '%s\n' "$bc_line" | sed 's/Orangepizero2w/Orange Pi Zero 2W/'
  done
}

choose_image() {
  if [ -n "$IMAGE" ]; then
    return 0
  fi
  if [ "$ASSUME_YES" = true ]; then
    IMAGE=$TESTED_URL
    return 0
  fi
  say "Looking for images..."
  ci_catalog=$(build_catalog)
  ci_count=$(printf '%s\n' "$ci_catalog" | grep -c .)
  say "Images:"
  ci_n=0
  while IFS= read -r ci_line; do
    ci_n=$((ci_n + 1))
    printf '  %s) %s  (%s)\n' "$ci_n" "${ci_line%%|*}" "$(image_status "${ci_line#*|}")"
  done << EOT
$ci_catalog
EOT
  ci_other=$((ci_count + 1))
  printf '  %s) Other: type a URL or a file path\n' "$ci_other"
  printf 'Which image? [1]: '
  read -r ci_choice || return 1
  ci_choice=${ci_choice:-1}
  if ! printf '%s' "$ci_choice" | grep -Eq '^[0-9]+$' || [ "$ci_choice" -lt 1 ] || [ "$ci_choice" -gt "$ci_other" ]; then
    fail "that is not one of the choices"
    return 1
  fi
  if [ "$ci_choice" -eq "$ci_other" ]; then
    printf 'URL or file path: '
    read -r IMAGE || return 1
    if [ -z "$IMAGE" ]; then
      fail "no image given"
      return 1
    fi
    return 0
  fi
  ci_pick=$(printf '%s\n' "$ci_catalog" | sed -n "${ci_choice}p")
  IMAGE=${ci_pick#*|}
  if [ "$(image_status "$IMAGE")" != "TESTED/WORKING" ]; then
    say "This image has not been tested on your hardware here."
  fi
  case $(image_status "$IMAGE") in
    "KNOWN BAD"*)
      printf 'This build did not boot on the board. Use it anyway? [y/N]: '
      read -r ci_ok || return 1
      case $ci_ok in
        [Yy] | [Yy][Ee][Ss]) ;;
        *)
          say "Cancelled."
          return 1
          ;;
      esac
      ;;
  esac
}

check_tools_for_image() {
  check_tools
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
  while :; do
    pd_list=$(list_disks)
    if [ -n "$DISK" ]; then
      [ -n "$pd_list" ] && pd_line=$(printf '%s\n' "$pd_list" | awk -F '|' -v d="$DISK" '$1 == d')
      if [ -z "${pd_line:-}" ]; then
        fail "$DISK is not a removable disk. Refusing."
        return 1
      fi
      break
    fi
    if [ -z "$pd_list" ]; then
      say "No removable disks found."
      printf 'Put the SD card in the reader, then press Enter to rescan (q to quit): '
      read -r pd_again || return 1
      [ "$pd_again" = q ] && return 1
      continue
    fi
    say "Removable disks:"
    pd_n=0
    while IFS='|' read -r pd_id pd_bytes pd_name; do
      pd_n=$((pd_n + 1))
      pd_note=
      if [ "${pd_bytes:-0}" -gt "$BIG_DISK_BYTES" ]; then
        pd_note="  (over 512 GB, unlikely to be an SD card)"
      fi
      printf '  %s) %s  %s  %s%s\n' "$pd_n" "$pd_id" "$(human_size "$pd_bytes")" "$pd_name" "$pd_note"
    done << EOT
$pd_list
EOT
    if [ "$pd_n" -eq 1 ]; then
      printf 'Which one is the SD card? [1], r to rescan, q to quit: '
    else
      printf 'Which one is the SD card? (number), r to rescan, q to quit: '
    fi
    read -r pd_choice || return 1
    case $pd_choice in
      r | R) continue ;;
      q | Q) return 1 ;;
    esac
    if [ -z "$pd_choice" ] && [ "$pd_n" -eq 1 ]; then
      pd_choice=1
    fi
    if ! printf '%s' "$pd_choice" | grep -Eq '^[0-9]+$' || [ "$pd_choice" -lt 1 ] || [ "$pd_choice" -gt "$pd_n" ]; then
      say "That is not one of the choices."
      continue
    fi
    pd_line=$(printf '%s\n' "$pd_list" | sed -n "${pd_choice}p")
    DISK=${pd_line%%|*}
    break
  done
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
  if [ "$cd_actual" != "$(printf '%s' "$cd_expected" | tr '[:upper:]' '[:lower:]')" ]; then
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

read_secret() {
  if [ -t 0 ]; then
    stty -echo 2> /dev/null
    read -r RS_VALUE
    rs_rc=$?
    stty echo 2> /dev/null
    printf '\n'
    return $rs_rc
  fi
  read -r RS_VALUE
}

ask_value() {
  av_try=0
  while [ "$av_try" -lt 3 ]; do
    av_try=$((av_try + 1))
    if [ -n "$2" ]; then
      printf '%s [%s]: ' "$1" "$2"
    else
      printf '%s: ' "$1"
    fi
    read -r av_in || return 1
    av_in=${av_in:-$2}
    if printf '%s' "$av_in" | grep -Eq "$3"; then
      VALUE=$av_in
      return 0
    fi
    say "$4"
  done
  fail "too many tries"
  return 1
}

ask_secret() {
  as_try=0
  while [ "$as_try" -lt 3 ]; do
    as_try=$((as_try + 1))
    printf '%s: ' "$1"
    read_secret || return 1
    as_first=$RS_VALUE
    printf 'Type it again to confirm: '
    read_secret || return 1
    if [ "$as_first" != "$RS_VALUE" ]; then
      say "They did not match."
      continue
    fi
    if [ "${#as_first}" -lt "$2" ]; then
      say "Use at least $2 characters."
      continue
    fi
    if printf '%s' "$as_first" | LC_ALL=C grep -q '[^ -~]'; then
      say "Use plain keyboard characters only."
      continue
    fi
    SECRET=$as_first
    return 0
  done
  fail "too many tries"
  return 1
}

default_timezone() {
  dt_zone=$(readlink /etc/localtime 2> /dev/null | sed -n 's|.*/zoneinfo/||p')
  if [ -z "$dt_zone" ] && [ -r /etc/timezone ]; then
    dt_zone=$(head -n 1 /etc/timezone)
  fi
  printf '%s' "${dt_zone:-UTC}"
}

default_user() {
  id -un 2> /dev/null | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g'
}

collect_headless() {
  P_ENABLED=false
  if ! is_armbian "$IMAGE"; then
    return 0
  fi
  case $HEADLESS in
    no) return 0 ;;
    ask)
      if [ "$ASSUME_YES" = true ]; then
        return 0
      fi
      printf 'Set it up so it needs no screen or keyboard? [Y/n]: '
      read -r ch_answer || return 1
      case $ch_answer in
        '' | [Yy] | [Yy][Ee][Ss]) ;;
        *) return 0 ;;
      esac
      ;;
  esac
  ask_value "Username for the board" "$(default_user)" '^[a-z][a-z0-9_-]{0,31}$' "Use lowercase letters, digits, dash, or underscore, starting with a letter." || return 1
  P_USER=$VALUE
  ask_secret "Password for $P_USER (also used for root)" 8 || return 1
  P_PASS=$SECRET
  ask_value "Wi-Fi name (blank for wired only)" "" '^$|^[ -~]{1,32}$' "Use 1 to 32 plain characters." || return 1
  P_SSID=$VALUE
  P_WIFIKEY=
  P_COUNTRY=US
  if [ -n "$P_SSID" ]; then
    ask_secret "Wi-Fi password" 8 || return 1
    P_WIFIKEY=$SECRET
    ask_value "Wi-Fi country code" US '^[A-Z]{2}$' "Use two capital letters, like US." || return 1
    P_COUNTRY=$VALUE
  fi
  ask_value "Timezone" "$(default_timezone)" '^[A-Za-z0-9_+/-]{1,64}$' "That does not look like a timezone, like America/Phoenix." || return 1
  P_TZ=$VALUE
  ask_value "GitHub username for your SSH key (blank to skip)" "" '^$|^[A-Za-z0-9-]{1,39}$' "Use a GitHub username." || return 1
  P_GITHUB=$VALUE
  if [ -n "$P_GITHUB" ] && ! github_key_exists "$P_GITHUB"; then
    say "Warning: no public SSH key found at https://github.com/$P_GITHUB.keys, so the board will not get one."
    P_GITHUB=
  fi
  P_ENABLED=true
}

github_key_exists() {
  curl -fsS --max-time 10 "https://github.com/$1.keys" 2> /dev/null | grep -q '^ssh-'
}

escape_value() {
  printf '%s' "$1" | sed 's/[\\"$`]/\\&/g'
}

render_preset() {
  printf 'PRESET_NET_CHANGE_DEFAULTS="1"\n'
  if [ -n "$P_SSID" ]; then
    printf 'PRESET_NET_ETHERNET_ENABLED="0"\n'
    printf 'PRESET_NET_WIFI_ENABLED="1"\n'
    printf 'PRESET_NET_WIFI_SSID="%s"\n' "$(escape_value "$P_SSID")"
    printf 'PRESET_NET_WIFI_KEY="%s"\n' "$(escape_value "$P_WIFIKEY")"
    printf 'PRESET_NET_WIFI_COUNTRYCODE="%s"\n' "$P_COUNTRY"
  else
    printf 'PRESET_NET_ETHERNET_ENABLED="1"\n'
    printf 'PRESET_NET_WIFI_ENABLED="0"\n'
  fi
  printf 'PRESET_CONNECT_WIRELESS="n"\n'
  printf 'PRESET_NET_USE_STATIC="0"\n'
  printf 'SET_LANG_BASED_ON_LOCATION="n"\n'
  printf 'PRESET_LOCALE="en_US.UTF-8"\n'
  printf 'PRESET_TIMEZONE="%s"\n' "$P_TZ"
  printf 'PRESET_ROOT_PASSWORD="%s"\n' "$(escape_value "$P_PASS")"
  printf 'PRESET_USER_NAME="%s"\n' "$P_USER"
  printf 'PRESET_USER_PASSWORD="%s"\n' "$(escape_value "$P_PASS")"
  printf 'PRESET_DEFAULT_REALNAME="%s"\n' "$P_USER"
  if [ -n "$P_GITHUB" ]; then
    printf 'PRESET_USER_KEY="https://github.com/%s.keys"\n' "$P_GITHUB"
  fi
}

byte_at() {
  dd if="$1" bs=1 skip="$2" count=1 2> /dev/null | od -An -v -tu1 | tr -d ' \n'
}

le_value() {
  dd if="$1" bs=1 skip="$2" count="$3" 2> /dev/null | od -An -v -tu1 | awk '{ v = 0; for (i = NF; i >= 1; i--) v = v * 256 + $i; printf "%.0f", v }'
}

partition_offsets() {
  po_img=$1
  if [ "$(byte_at "$po_img" 510)" != 85 ] || [ "$(byte_at "$po_img" 511)" != 170 ]; then
    return 0
  fi
  po_gpt=false
  for po_i in 0 1 2 3; do
    po_base=$((446 + po_i * 16))
    po_type=$(byte_at "$po_img" $((po_base + 4)))
    [ "${po_type:-0}" = 0 ] && continue
    if [ "$po_type" = 238 ]; then
      po_gpt=true
      continue
    fi
    printf '%s\n' $(($(le_value "$po_img" $((po_base + 8)) 4) * 512))
  done
  if [ "$po_gpt" = true ]; then
    po_sig=$(dd if="$po_img" bs=1 skip=512 count=8 2> /dev/null)
    [ "$po_sig" = "EFI PART" ] || return 0
    po_lba=$(le_value "$po_img" 584 8)
    po_num=$(le_value "$po_img" 592 4)
    po_size=$(le_value "$po_img" 596 4)
    [ "$po_num" -gt 16 ] && po_num=16
    po_i=0
    while [ "$po_i" -lt "$po_num" ]; do
      po_entry=$((po_lba * 512 + po_i * po_size))
      if [ "$(le_value "$po_img" "$po_entry" 8)" != 0 ] || [ "$(le_value "$po_img" $((po_entry + 8)) 8)" != 0 ]; then
        printf '%s\n' $(($(le_value "$po_img" $((po_entry + 32)) 8) * 512))
      fi
      po_i=$((po_i + 1))
    done
  fi
}

find_root_offset() {
  for fr_off in $(partition_offsets "$1"); do
    if "$DEBUGFS" -R "stat /root" "$1?offset=$fr_off" 2> /dev/null | grep -q 'Type: directory'; then
      printf '%s' "$fr_off"
      return 0
    fi
  done
  return 1
}

apply_preset() {
  if [ "$P_ENABLED" != true ]; then
    return 0
  fi
  need_debugfs || return 1
  mkdir -p "$WORK_DIR" || return 1
  PRESET_COPY=$WORK_DIR/headless.img
  say "Preparing a copy of the image with your settings"
  rm -f "$PRESET_COPY"
  cp "$IMG_FILE" "$PRESET_COPY" || { fail "could not copy the image"; return 1; }
  chmod 600 "$PRESET_COPY"
  ap_off=$(find_root_offset "$PRESET_COPY") || { fail "could not find the system partition in this image"; return 1; }
  PRESET_TMP=$WORK_DIR/.preset.tmp
  (umask 077 && render_preset > "$PRESET_TMP") || { fail "could not write the settings"; return 1; }
  ap_target="$PRESET_COPY?offset=$ap_off"
  "$DEBUGFS" -w -R "rm /root/.not_logged_in_yet" "$ap_target" > /dev/null 2>&1
  "$DEBUGFS" -w -R "write $PRESET_TMP /root/.not_logged_in_yet" "$ap_target" > /dev/null 2>&1
  "$DEBUGFS" -w -R "sif /root/.not_logged_in_yet mode 0100600" "$ap_target" > /dev/null 2>&1
  "$DEBUGFS" -w -R "sif /root/.not_logged_in_yet uid 0" "$ap_target" > /dev/null 2>&1
  "$DEBUGFS" -w -R "sif /root/.not_logged_in_yet gid 0" "$ap_target" > /dev/null 2>&1
  if ! "$DEBUGFS" -R "cat /root/.not_logged_in_yet" "$ap_target" 2> /dev/null | cmp -s - "$PRESET_TMP"; then
    fail "the settings did not end up in the image"
    return 1
  fi
  rm -f "$PRESET_TMP"
  PRESET_TMP=
  IMG_FILE=$PRESET_COPY
}

confirm_erase() {
  say ""
  say "This will ERASE everything on $DISK ($(human_size "$DISK_BYTES"), $DISK_NAME)."
  if [ "$DISK_BYTES" -gt "$BIG_DISK_BYTES" ]; then
    say "WARNING: that disk is larger than any SD card should be. Make sure it is the right one."
  fi
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
  if [ "$P_ENABLED" = true ]; then
    say "  1. Put the card in the board and power it on. No screen or keyboard is needed."
    say "  2. The first boot takes a few minutes. Find the board's address in your router app."
    say "  3. Connect with: ssh $P_USER@ADDRESS"
    say "  4. Then run setup-node.sh on the board."
    say ""
    say "The password is stored on the card until the first boot finishes."
  else
    say "  1. Put the card in the board, attach a screen and keyboard, and power it on."
    say "  2. In the first-login wizard, make your user, join your Wi-Fi, and set the timezone."
    say "  3. Then run setup-node.sh on the board."
  fi
}

main() {
  trap cleanup EXIT
  trap 'cleanup; exit 130' INT TERM
  parse_args "$@" || return 1
  choose_image || return 1
  check_tools || return 1
  pick_disk || return 1
  collect_headless || return 1
  prepare_image || return 1
  apply_preset || return 1
  confirm_erase || return 1
  ensure_priv || return 1
  unmount_disk "$DISK" || return 1
  write_image || return 1
  verify_image || return 1
  eject_disk "$DISK"
  cleanup
  finish_up
}

if [ "${FLASH_NO_MAIN:-}" != 1 ]; then
  main "$@"
fi
