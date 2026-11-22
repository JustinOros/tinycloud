#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$HERE/harness.sh"

SANDBOX=$(mktemp -d)
FLASH_NO_MAIN=1
export FLASH_NO_MAIN
TC_FLASH_DIR=$SANDBOX/work
export TC_FLASH_DIR
. "$ROOT/tools/flash-sd.sh"
set +e

head -c 3000000 /dev/urandom > "$SANDBOX/os.img"
xz -k -c "$SANDBOX/os.img" > "$SANDBOX/os.img.xz"
gzip -k -c "$SANDBOX/os.img" > "$SANDBOX/os.img.gz"
head -c 8388608 /dev/zero > "$SANDBOX/card"
FAKE_CARD=$SANDBOX/card
FAKE_SIZE=8388608
LOG=$SANDBOX/log
: > "$LOG"

priv() { "$@"; }
ensure_priv() { return 0; }
list_disks() { printf 'fake1|%s|Fake Card\nfake2|2000000|Tiny Card\n' "$FAKE_SIZE"; }
raw_path() { printf '%s' "$FAKE_CARD"; }
unmount_disk() { echo "unmount $1" >> "$LOG"; }
eject_disk() { echo "eject $1" >> "$LOG"; }
dd_write() { dd if="$1" of="$2" bs=1048576 conv=notrunc 2> /dev/null; }

reset_state() {
  DISK=
  ASSUME_YES=false
  IMAGE=$SANDBOX/os.img
  head -c 8388608 /dev/zero > "$FAKE_CARD"
  : > "$LOG"
}

run_flash() {
  main "$@" < /dev/null > "$SANDBOX/out" 2>&1
  RC=$?
  OUT=$(cat "$SANDBOX/out")
}

reset_state
VERIFY_BLOCKS=1
run_flash --image "$SANDBOX/os.img" --disk fake1 --yes
assert_contains "verify shows progress" "$OUT" "100%"
assert_eq "chunked verify passes" 0 "$RC"
head -c 3000000 /dev/urandom > "$SANDBOX/os2.img"
dd if="$SANDBOX/os.img" of="$FAKE_CARD" bs=1048576 conv=notrunc 2> /dev/null
printf 'X' | dd of="$FAKE_CARD" bs=1 seek=2500000 conv=notrunc 2> /dev/null
DISK=fake1
IMG_FILE=$SANDBOX/os.img
IMG_SIZE=3000000
verify_image > "$SANDBOX/out" 2>&1
assert_eq "corruption in a late chunk caught" 1 "$?"
VERIFY_BLOCKS=64
reset_state
run_flash --image "$SANDBOX/os.img" --disk fake1 --yes
assert_eq "plain image flashes" 0 "$RC"
assert_eq "card holds the image" 1 "$(head -c 3000000 "$FAKE_CARD" | cmp -s - "$SANDBOX/os.img" && echo 1 || echo 0)"
assert_contains "verified" "$OUT" "The card matches the image."
assert_contains "card unmounted first" "$(cat "$LOG")" "unmount fake1"
assert_contains "card ejected after" "$(cat "$LOG")" "eject fake1"
assert_contains "next steps shown" "$OUT" "setup-node.sh"
assert_contains "erase warning names the disk" "$OUT" "ERASE everything on fake1"

reset_state
run_flash --image "$SANDBOX/os.img.xz" --disk fake1 --yes
assert_eq "xz image flashes" 0 "$RC"
assert_eq "xz card holds the image" 1 "$(head -c 3000000 "$FAKE_CARD" | cmp -s - "$SANDBOX/os.img" && echo 1 || echo 0)"
assert_eq "unpacked copy kept for next time" 1 "$([ -s "$SANDBOX/os.img" ] && echo 1 || echo 0)"

reset_state
run_flash --image "$SANDBOX/os.img.gz" --disk fake1 --yes
assert_eq "gz image flashes" 0 "$RC"

reset_state
printf 'fake1\n' | run_flash --image "$SANDBOX/os.img" --disk fake1
assert_eq "typed confirmation proceeds" 0 "$RC"

reset_state
printf 'wrong\n' > "$SANDBOX/in"
main --image "$SANDBOX/os.img" --disk fake1 < "$SANDBOX/in" > "$SANDBOX/out" 2>&1
assert_eq "wrong confirmation stops" 1 "$?"
assert_contains "cancel says so" "$(cat "$SANDBOX/out")" "Cancelled."
assert_eq "nothing written when cancelled" 1 "$(head -c 8388608 /dev/zero | cmp -s - "$FAKE_CARD" && echo 1 || echo 0)"
assert_eq "nothing unmounted when cancelled" 0 "$(grep -c unmount "$LOG")"

reset_state
printf '1\nfake1\n' > "$SANDBOX/in"
main --image "$SANDBOX/os.img" < "$SANDBOX/in" > "$SANDBOX/out" 2>&1
assert_eq "menu choice works" 0 "$?"
assert_contains "menu lists disks" "$(cat "$SANDBOX/out")" "1) fake1"
assert_contains "menu shows size and name" "$(cat "$SANDBOX/out")" "8 MB  Fake Card"
assert_eq "big sizes use gigabytes" "256.1 GB" "$(human_size 256060514304)"

reset_state
printf '\nfake1\n' > "$SANDBOX/in"
main --image "$SANDBOX/os.img" < "$SANDBOX/in" > "$SANDBOX/out" 2>&1
assert_eq "empty choice refused with several disks" 1 "$?"

reset_state
printf '9\n' > "$SANDBOX/in"
main --image "$SANDBOX/os.img" < "$SANDBOX/in" > "$SANDBOX/out" 2>&1
assert_eq "out of range choice refused" 1 "$?"
assert_contains "out of range explained" "$(cat "$SANDBOX/out")" "not one of the choices"

reset_state
printf '9\nr\n1\nfake1\n' > "$SANDBOX/in"
main --image "$SANDBOX/os.img" < "$SANDBOX/in" > "$SANDBOX/out" 2>&1
assert_eq "bad choice and rescan then pick works" 0 "$?"
assert_contains "rescan offered" "$(cat "$SANDBOX/out")" "r to rescan"

reset_state
printf 'q\n' > "$SANDBOX/in"
main --image "$SANDBOX/os.img" < "$SANDBOX/in" > "$SANDBOX/out" 2>&1
assert_eq "quit at the disk menu" 1 "$?"

reset_state
list_disks() { :; }
printf '\nq\n' > "$SANDBOX/in"
main --image "$SANDBOX/os.img" < "$SANDBOX/in" > "$SANDBOX/out" 2>&1
assert_eq "empty list rescans then quits" 1 "$?"
assert_contains "empty list prompts rescan" "$(cat "$SANDBOX/out")" "press Enter to rescan"
list_disks() { printf 'fake1|%s|Fake Card\nfake2|2000000|Tiny Card\n' "$FAKE_SIZE"; }

reset_state
run_flash --image "$SANDBOX/os.img" --disk disk0 --yes
assert_eq "disk that is not removable refused" 1 "$RC"
assert_contains "refusal explained" "$OUT" "not a removable disk"
assert_eq "refusal writes nothing" 0 "$(grep -c unmount "$LOG")"

reset_state
run_flash --image "$SANDBOX/os.img" --disk fake2 --yes
assert_eq "image bigger than the card refused" 1 "$RC"
assert_contains "size problem explained" "$OUT" "larger than the card"
assert_eq "too small card untouched" 1 "$(head -c 8388608 /dev/zero | cmp -s - "$FAKE_CARD" && echo 1 || echo 0)"

reset_state
run_flash --image "$SANDBOX/missing.img" --disk fake1 --yes
assert_eq "missing image refused" 1 "$RC"
assert_contains "missing image explained" "$OUT" "not found"

reset_state
printf 'x' > "$SANDBOX/odd.bin"
run_flash --image "$SANDBOX/odd.bin" --disk fake1 --yes
assert_eq "unknown file type refused" 1 "$RC"

reset_state
after_write() { printf 'X' | dd of="$FAKE_CARD" bs=1 seek=1000 conv=notrunc 2> /dev/null; }
run_flash --image "$SANDBOX/os.img" --disk fake1 --yes
assert_eq "bad card caught by the read back" 1 "$RC"
assert_contains "bad card explained" "$OUT" "does not match"
assert_eq "bad card is not ejected as good" 0 "$(grep -c eject "$LOG")"
after_write() { sync; }

reset_state
list_disks() { :; }
run_flash --image "$SANDBOX/os.img" --yes
assert_eq "no disks found" 1 "$RC"
assert_contains "no disks explained" "$OUT" "No removable disks found"
list_disks() { printf 'fake1|%s|Fake Card\nfake2|2000000|Tiny Card\n' "$FAKE_SIZE"; }

reset_state
run_flash --bogus
assert_eq "unknown option refused" 1 "$RC"
assert_contains "usage shown" "$OUT" "usage:"
run_flash --disk 'bad;name' --yes
assert_eq "bad disk name refused" 1 "$RC"
run_flash --image
assert_eq "missing option value refused" 1 "$RC"

STUBS=$SANDBOX/stubs
mkdir -p "$STUBS"
cat > "$STUBS/diskutil" << 'EOT'
#!/bin/sh
case "$1 $2" in
  "list external")
    printf '/dev/disk4 (external, physical):\n   #:                       TYPE NAME                    SIZE       IDENTIFIER\n   0:     FDisk_partition_scheme                        *256.1 GB   disk4\n\n/dev/disk6 (external, physical):\n   #:                       TYPE NAME                    SIZE       IDENTIFIER\n   0:      GUID_partition_scheme                        *4.5 TB     disk6\n'
    ;;
  "info disk4")
    printf '   Device Identifier:         disk4\n   Device / Media Name:       STORAGE DEVICE\n   Disk Size:                 256.1 GB (256060514304 Bytes) (exactly 500118192 512-Byte-Units)\n'
    ;;
  "info disk6")
    printf '   Device / Media Name:       Elements 2621\n   Disk Size:                 4.5 TB (4500000000000 Bytes) (exactly 8789062500 512-Byte-Units)\n'
    ;;
esac
EOT
cat > "$STUBS/lsblk" << 'EOT'
#!/bin/sh
case "$*" in
  "-dnbPo NAME,SIZE,RM,TRAN,TYPE")
    printf 'NAME="sda" SIZE="500107862016" RM="0" TRAN="sata" TYPE="disk"\nNAME="sdb" SIZE="256060514304" RM="1" TRAN="usb" TYPE="disk"\nNAME="mmcblk0" SIZE="127865454592" RM="0" TRAN="" TYPE="disk"\nNAME="sdc" SIZE="64023257088" RM="0" TRAN="usb" TYPE="disk"\nNAME="loop0" SIZE="1000000" RM="0" TRAN="" TYPE="loop"\n'
    ;;
  "-nro MOUNTPOINT /dev/sdc") printf '/\n' ;;
  "-nro MOUNTPOINT /dev/"*) printf '\n' ;;
  "-dno MODEL /dev/sdb") printf 'Generic STORAGE DEVICE  \n' ;;
  "-dno MODEL /dev/"*) printf '\n' ;;
esac
EOT
chmod +x "$STUBS/diskutil" "$STUBS/lsblk"
OLD_PATH=$PATH
PATH=$STUBS:$PATH
mac=$(list_disks_mac)
assert_eq "mac lists both external disks" 2 "$(printf '%s\n' "$mac" | wc -l | tr -d ' ')"
assert_contains "mac disk id size and name" "$mac" "disk4|256060514304|STORAGE DEVICE"
assert_contains "mac second disk" "$mac" "disk6|4500000000000|Elements 2621"
assert_not_contains "mac never lists the internal disk" "$mac" "disk0"
lin=$(list_disks_linux)
assert_contains "linux lists the usb disk with its model" "$lin" "sdb|256060514304|Generic STORAGE DEVICE"
assert_not_contains "linux skips the internal sata disk" "$lin" "sda"
assert_not_contains "linux skips a usb disk holding the root filesystem" "$lin" "sdc"
assert_not_contains "linux skips loop devices" "$lin" "loop0"
assert_not_contains "linux skips a non removable card slot" "$lin" "mmcblk0"
PATH=$OLD_PATH

TOOLS=$SANDBOX/tools
mkdir -p "$TOOLS"
make_installer() {
  cat > "$TOOLS/$1" << EOT
#!/bin/sh
echo "$1 \$*" >> "$SANDBOX/installs"
for last in "\$@"; do :; done
case "\$last" in
  $2) printf '#!/bin/sh\\n' > "$TOOLS/$3"; chmod +x "$TOOLS/$3" ;;
esac
EOT
  chmod +x "$TOOLS/$1"
}
OLD_PATH=$PATH
PATH=$TOOLS:$PATH
: > "$SANDBOX/installs"

OS=Linux
ASSUME_YES=true
make_installer apt-get faketool faketool
need_tool faketool > "$SANDBOX/out" 2>&1
assert_eq "missing tool installed on apt systems" 0 "$?"
assert_contains "apt refreshes then installs" "$(cat "$SANDBOX/installs")" "apt-get install -y faketool"
rm -f "$TOOLS/faketool" "$TOOLS/apt-get"
hash -r

make_installer dnf faketool faketool
package_manager() { printf 'dnf'; }
need_tool faketool > "$SANDBOX/out" 2>&1
assert_eq "missing tool installed on dnf systems" 0 "$?"
assert_contains "dnf install used" "$(cat "$SANDBOX/installs")" "dnf install -y faketool"
unset -f package_manager
. "$ROOT/tools/flash-sd.sh"
set +e
OS=Linux
ASSUME_YES=true
rm -f "$TOOLS/faketool" "$TOOLS/dnf"
hash -r

assert_eq "xz is xz-utils on apt" xz-utils "$(package_for xz apt-get)"
assert_eq "xz is xz elsewhere" xz "$(package_for xz dnf)"
assert_eq "cmp comes from diffutils" diffutils "$(package_for cmp pacman)"
assert_eq "dd comes from coreutils" coreutils "$(package_for dd apk)"
assert_eq "other tools keep their name" curl "$(package_for curl apt-get)"

OS=Darwin
running_as_root() { return 1; }
make_installer brew faketool faketool
need_tool faketool > "$SANDBOX/out" 2>&1
assert_eq "missing tool installed with brew" 0 "$?"
assert_contains "brew install used" "$(cat "$SANDBOX/installs")" "brew install faketool"
rm -f "$TOOLS/faketool"
hash -r
running_as_root() { return 0; }
need_tool faketool > "$SANDBOX/out" 2>&1
assert_eq "brew refused when run as root" 1 "$?"
assert_contains "brew root refusal explained" "$(cat "$SANDBOX/out")" "without sudo"
assert_eq "nothing installed when refused" 0 "$([ -e "$TOOLS/faketool" ] && echo 1 || echo 0)"
running_as_root() { [ "$(id -u)" -eq 0 ]; }
rm -f "$TOOLS/brew"

ASSUME_YES=false
OS=Linux
make_installer apt-get faketool faketool
: > "$SANDBOX/installs"
printf 'n\n' | need_tool faketool > "$SANDBOX/out" 2>&1
assert_eq "declining the install stops" 1 "$?"
assert_contains "declined install says what to do" "$(cat "$SANDBOX/out")" "Install it and run this again"
assert_eq "declined install runs nothing" 0 "$(wc -c < "$SANDBOX/installs" | tr -d ' ')"
printf 'y\n' | need_tool faketool > "$SANDBOX/out" 2>&1
assert_eq "agreeing installs" 0 "$?"
assert_contains "prompt names the tool and manager" "$(cat "$SANDBOX/out")" "Install faketool with apt?"
rm -f "$TOOLS/faketool"
hash -r
printf '\n' | need_tool faketool > "$SANDBOX/out" 2>&1
assert_eq "enter alone means yes" 0 "$?"
rm -f "$TOOLS/faketool" "$TOOLS/apt-get"
hash -r
ASSUME_YES=true
OS=Darwin

PATH=$OLD_PATH
OS=Darwin
need_tool nosuchtool99 > "$SANDBOX/out" 2>&1
assert_eq "no brew gives a clear failure" 1 "$?"
assert_contains "brew help given" "$(cat "$SANDBOX/out")" "https://brew.sh"

OS=Linux
make_installer apt-get never faketool2
PATH=$TOOLS:$PATH
need_tool faketool2 > "$SANDBOX/out" 2>&1
assert_eq "install that does not provide the tool fails" 1 "$?"
assert_contains "still missing said out loud" "$(cat "$SANDBOX/out")" "still missing"
PATH=$OLD_PATH
OS=$(uname -s)
ASSUME_YES=false
rm -f "$TOOLS/apt-get"

fetch_checksum() { printf '%s' "$FAKE_SUM"; }
printf 'data' > "$SANDBOX/dl.bin"
FAKE_SUM=$(sha256_of "$SANDBOX/dl.bin")
check_download "$SANDBOX/dl.bin" url > "$SANDBOX/out" 2>&1
assert_eq "good checksum accepted" 0 "$?"
FAKE_SUM=0000000000000000000000000000000000000000000000000000000000000000
check_download "$SANDBOX/dl.bin" url > "$SANDBOX/out" 2>&1
assert_eq "bad checksum refused" 1 "$?"
assert_contains "bad checksum explained" "$(cat "$SANDBOX/out")" "does not match its checksum"
FAKE_SUM=
check_download "$SANDBOX/dl.bin" url > "$SANDBOX/out" 2>&1
assert_eq "missing checksum tolerated" 0 "$?"
assert_contains "missing checksum said out loud" "$(cat "$SANDBOX/out")" "not checked"

assert_eq "tested image is pinned" 1 "$(printf '%s' "$TESTED_URL" | grep -c 'trunk.120.*Orangepizero2w.*\.img\.xz$')"
assert_eq "tested image is marked" "TESTED/WORKING" "$(image_status "$TESTED_URL")"
assert_eq "other images are untested" "untested" "$(image_status https://x/26.11.0-trunk.119/a.img.xz)"
assert_contains "trunk 137 is known bad" "$(image_status https://x/26.11.0-trunk.137/a.img.xz)" "KNOWN BAD"
assert_eq "armbian names detected" 0 "$(is_armbian Armbian_community_x.img.xz; echo $?)"
assert_eq "other names not armbian" 1 "$(is_armbian 2024-raspios.img.xz; echo $?)"

discover_images() { printf 'Armbian x|https://github.com/armbian/community/releases/download/26.11.0-trunk.119/b.img.xz\n'; }
IMAGE=
ASSUME_YES=false
printf '1\n' > "$SANDBOX/in"
choose_image < "$SANDBOX/in" > "$SANDBOX/out" 2>&1
assert_eq "menu pick 1 is the tested image" "$TESTED_URL" "$IMAGE"
assert_contains "menu marks tested" "$(cat "$SANDBOX/out")" "(TESTED/WORKING)"
assert_contains "menu marks untested" "$(cat "$SANDBOX/out")" "(untested)"
IMAGE=
printf '2\n' > "$SANDBOX/in"
choose_image < "$SANDBOX/in" > "$SANDBOX/out" 2>&1
assert_contains "menu pick 2 is the other image" "$IMAGE" "trunk.119"
IMAGE=
printf '3\n/tmp/my.img\n' > "$SANDBOX/in"
choose_image < "$SANDBOX/in" > "$SANDBOX/out" 2>&1
assert_eq "menu custom path" "/tmp/my.img" "$IMAGE"
IMAGE=
printf '9\n' > "$SANDBOX/in"
choose_image < "$SANDBOX/in" > "$SANDBOX/out" 2>&1
assert_eq "menu bad choice refused" 1 "$?"
IMAGE=
ASSUME_YES=true
choose_image > /dev/null 2>&1
assert_eq "yes mode uses the tested image" "$TESTED_URL" "$IMAGE"
ASSUME_YES=false

P_SSID='Home "Net"'; P_WIFIKEY='p$ss`w\rd'; P_COUNTRY=US; P_TZ=America/Phoenix; P_USER=justin; P_PASS='a"b$c'; P_ROOT_PASS=rootrandom123; P_GITHUB=JustinOros
render_preset > "$SANDBOX/preset"
assert_contains "preset escapes quotes" "$(cat "$SANDBOX/preset")" 'PRESET_NET_WIFI_SSID="Home \"Net\""'
assert_contains "preset escapes dollar and backtick" "$(cat "$SANDBOX/preset")" 'PRESET_NET_WIFI_KEY="p\$ss\`w\\rd"'
assert_contains "preset has user" "$(cat "$SANDBOX/preset")" 'PRESET_USER_NAME="justin"'
assert_contains "preset has key url" "$(cat "$SANDBOX/preset")" 'PRESET_USER_KEY="https://github.com/JustinOros.keys"'
assert_eq "preset sourceable" "Home \"Net\"" "$(sh -c ". $SANDBOX/preset; printf %s \"\$PRESET_NET_WIFI_SSID\"")"
assert_contains "root gets its own password" "$(cat "$SANDBOX/preset")" 'PRESET_ROOT_PASSWORD="rootrandom123"'
assert_eq "user password not given to root" 0 "$(grep ROOT_PASSWORD "$SANDBOX/preset" | grep -c 'a\\"b')"
assert_eq "random password is 32 plain characters" 1 "$(random_password | grep -Ec '^[A-Za-z0-9]{32}$')"
assert_eq "random passwords differ" 1 "$([ "$(random_password)" != "$(random_password)" ] && echo 1 || echo 0)"
assert_eq "preset password round trips" 'a"b$c' "$(sh -c ". $SANDBOX/preset; printf %s \"\$PRESET_USER_PASSWORD\"")"
P_SSID=
render_preset > "$SANDBOX/preset"
assert_contains "wired preset" "$(cat "$SANDBOX/preset")" 'PRESET_NET_ETHERNET_ENABLED="1"'

IMAGE=Armbian_community_x.img.xz
HEADLESS=ask
ASSUME_YES=false
printf '\njustin\nuserpass1\nuserpass1\nn\nrootpass1\nrootpass1\n\n\ns\n' > "$SANDBOX/in"
collect_headless < "$SANDBOX/in" > "$SANDBOX/out" 2>&1
assert_eq "headless flow completes with no sudo" 0 "$?"
assert_eq "no sudo recorded" no "$P_SUDO"
assert_eq "root password asked when no sudo" rootpass1 "$P_ROOT_PASS"
assert_eq "user password kept" userpass1 "$P_PASS"
printf '\njustin\nuserpass1\nuserpass1\n\n\n\ns\n' > "$SANDBOX/in"
collect_headless < "$SANDBOX/in" > "$SANDBOX/out" 2>&1
assert_eq "headless flow completes with sudo" 0 "$?"
assert_eq "sudo defaults to yes" yes "$P_SUDO"
assert_eq "random root password with sudo" 1 "$(printf '%s' "$P_ROOT_PASS" | grep -Ec '^[A-Za-z0-9]{32}$')"
IMAGE=
dd if=/dev/zero of="$SANDBOX/fs.part" bs=1048576 count=8 2> /dev/null
mke2fs -q -t ext4 -F "$SANDBOX/fs.part" > /dev/null 2>&1
debugfs -w -R "mkdir /root" "$SANDBOX/fs.part" > /dev/null 2>&1
head -c 1048576 /dev/zero > "$SANDBOX/hl.img"
cat "$SANDBOX/fs.part" >> "$SANDBOX/hl.img"
printf '\200\000\000\000\203\000\000\000\000\010\000\000\000\040\000\000' > "$SANDBOX/ent"
dd if="$SANDBOX/ent" of="$SANDBOX/hl.img" bs=1 seek=446 conv=notrunc 2> /dev/null
printf '\125\252' | dd of="$SANDBOX/hl.img" bs=1 seek=510 conv=notrunc 2> /dev/null
od() { command od "$@"; echo; }
assert_eq "le_value ignores extra blank lines" 2048 "$(le_value "$SANDBOX/hl.img" 454 4)"
unset -f od
DEBUGFS=$(command -v debugfs)
assert_eq "ed25519 key accepted" 0 "$(valid_ssh_key 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabc user@host'; echo $?)"
assert_eq "rsa key accepted" 0 "$(valid_ssh_key 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQ'; echo $?)"
assert_eq "junk refused" 1 "$(valid_ssh_key 'hello world'; echo $?)"
assert_eq "quote injection refused" 1 "$(valid_ssh_key "ssh-ed25519 AAAA'; rm -rf /; '"; echo $?)"
assert_eq "root offset found" 1048576 "$(find_root_offset "$SANDBOX/hl.img")"
P_ENABLED=true; P_SSID=Net; P_WIFIKEY=secretkey1; P_USER=justin; P_PASS=hunter22x; P_ROOT_PASS=rootrandom123; P_TZ=UTC; P_COUNTRY=US; P_GITHUB=; P_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabc'
IMG_FILE=$SANDBOX/hl.img
need_debugfs() { return 0; }
apply_preset > "$SANDBOX/out" 2>&1
assert_eq "preset applied" 0 "$?"
assert_contains "image copy used" "$IMG_FILE" "headless.img"
assert_contains "preset readable from image" "$(debugfs -R 'cat /root/.not_logged_in_yet' "$IMG_FILE?offset=1048576" 2> /dev/null)" 'PRESET_USER_NAME="justin"'
assert_contains "provisioning script in image" "$(debugfs -R 'cat /root/provisioning.sh' "$IMG_FILE?offset=1048576" 2> /dev/null)" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabc"
assert_contains "provisioning adds sudo" "$(debugfs -R 'cat /root/provisioning.sh' "$IMG_FILE?offset=1048576" 2> /dev/null)" 'usermod -aG sudo'
P_KEY=
P_SUDO=no
assert_eq "no sudo removes the group" 1 "$(render_provisioning | grep -c 'gpasswd -d')"
assert_eq "no sudo never adds the group" 0 "$(render_provisioning | grep -c 'usermod -aG sudo')"
P_SUDO=yes
assert_eq "no key still adds sudo" 1 "$(render_provisioning | grep -c 'usermod -aG sudo')"
assert_eq "no key writes no key lines" 0 "$(render_provisioning | grep -c authorized_keys)"
assert_eq "provisioning script is valid sh" 0 "$(debugfs -R 'cat /root/provisioning.sh' "$IMG_FILE?offset=1048576" 2> /dev/null | sh -n; echo $?)"
assert_eq "original image untouched" 0 "$(debugfs -R 'stat /root/.not_logged_in_yet' "$SANDBOX/hl.img?offset=1048576" 2>&1 | grep -c 'Type: regular')"
cleanup
assert_eq "copy cleaned up" 1 "$([ -e "$TC_FLASH_DIR/headless.img" ]; echo $?)"

finish
