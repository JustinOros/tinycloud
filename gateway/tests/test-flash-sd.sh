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
  main "$@" > "$SANDBOX/out" 2>&1
  RC=$?
  OUT=$(cat "$SANDBOX/out")
}

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
assert_eq "empty choice picks the first disk" 0 "$?"

reset_state
printf '9\n' > "$SANDBOX/in"
main --image "$SANDBOX/os.img" < "$SANDBOX/in" > "$SANDBOX/out" 2>&1
assert_eq "out of range choice refused" 1 "$?"
assert_contains "out of range explained" "$(cat "$SANDBOX/out")" "not one of the choices"

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
assert_contains "no disks explained" "$OUT" "no removable disks found"
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

assert_eq "default image is pinned" 1 "$(printf '%s' "$DEFAULT_IMAGE" | grep -c 'trunk.120.*Orangepizero2w.*\.img\.xz$')"

finish
