#!/bin/sh
SMB_CONF_DIR=${SMB_CONF_DIR:-/etc/samba}

smb_file() {
  printf '%s/tinycloud.conf' "$SMB_CONF_DIR"
}

smb_present() {
  [ -f "$(smb_file)" ]
}

valid_smb_user() {
  [ "$1" != root ] && printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]{0,30}$'
}

valid_smb_mode() {
  case $1 in
    ro | rw) return 0 ;;
  esac
  return 1
}

smb_mode_name() {
  case $1 in
    1 | rw) printf 'rw' ;;
    2 | ro) printf 'ro' ;;
  esac
}

valid_smb_choice() {
  [ -n "$(smb_mode_name "$1")" ]
}

valid_smb_password() {
  case $1 in
    *'
'*) return 1 ;;
  esac
  [ "${#1}" -ge 8 ]
}

smb_hide() {
  stty -echo <&3 2> /dev/null || true
}

smb_show() {
  stty echo <&3 2> /dev/null || true
}

ask_secret() {
  as_try=0
  while [ "$as_try" -lt 3 ]; do
    smb_hide
    printf '%s: ' "$1"
    if ! read -r as_one <&3; then
      smb_show
      return 1
    fi
    printf '\n'
    printf 'Type it again: '
    if ! read -r as_two <&3; then
      smb_show
      return 1
    fi
    printf '\n'
    smb_show
    if [ "$as_one" != "$as_two" ]; then
      say "They do not match."
    elif ! valid_smb_password "$as_one"; then
      say "Use at least 8 characters."
    else
      ANSWER=$as_one
      return 0
    fi
    as_try=$((as_try + 1))
  done
  fail "no valid password"
}

smb_password() {
  if [ -n "${TC_SMB_PASSWORD:-}" ]; then
    valid_smb_password "$TC_SMB_PASSWORD" || { fail "TC_SMB_PASSWORD must be at least 8 characters"; return 1; }
    SMB_PASSWORD=$TC_SMB_PASSWORD
    return 0
  fi
  if [ "$ASSUME_YES" = true ]; then
    fail "set TC_SMB_PASSWORD to use --smb yes with --yes"
    return 1
  fi
  ask_secret "SMB password (8 or more characters)" || return 1
  SMB_PASSWORD=$ANSWER
}

choose_smb_mode() {
  smb_role=${ROLE:-$(existing_value ROLE)}
  case $SMB_MODE in
    ro) return 0 ;;
    rw)
      if [ "$smb_role" = reader ]; then
        fail "a reader node receives only, so its share must be read-only"
        return 1
      fi
      return 0
      ;;
    '') ;;
    *) fail "--smb-mode must be ro or rw"; return 1 ;;
  esac
  if [ "$smb_role" = reader ]; then
    SMB_MODE=ro
    say "This node is a reader, so the share is read-only."
    return 0
  fi
  if [ "$ASSUME_YES" = true ]; then
    SMB_MODE=ro
    return 0
  fi
  say "SMB access:"
  say "  1) read-write  add files to your own folder ($NODE_HOME/data/library/$SMB_OWNER), they sync"
  say "  2) read-only   browse everyone's folders"
  choose_value "Which one? (number)" 1 valid_smb_choice || return 1
  SMB_MODE=$(smb_mode_name "$ANSWER")
}

choose_smb_access() {
  case $SMB_GUEST in
    yes | no | '') ;;
    *) fail "--smb-guest must be yes or no"; return 1 ;;
  esac
  if [ "$SMB_GUEST" = yes ] && [ "$SMB_MODE" = rw ]; then
    fail "read-write needs a password, so --smb-guest yes needs --smb-mode ro"
    return 1
  fi
  if [ -z "$SMB_GUEST" ]; then
    SMB_GUEST=no
    if [ "$SMB_MODE" = rw ]; then
      say "Read-write always needs a password."
    elif [ "$ASSUME_YES" != true ] && ! ask_yes "Require a username and password? (recommended)" y; then
      say "Without a password, anyone on your network can read these files."
      if ask_yes "Share with no password anyway?" n; then
        SMB_GUEST=yes
      fi
    fi
  fi
  [ "$SMB_GUEST" = no ] || return 0
  if [ -z "$SMB_USER" ]; then
    choose_value "SMB username" "$SMB_OWNER" valid_smb_user || return 1
    SMB_USER=$ANSWER
  fi
  valid_smb_user "$SMB_USER" || { fail "bad SMB username"; return 1; }
  smb_password || return 1
}

choose_smb() {
  case $SMB in
    yes | no) ;;
    '')
      if [ "$ASSUME_YES" = true ]; then
        SMB=no
        return 0
      fi
      if ask_yes "Share your files on your local network over SMB, for copying from a PC?" n; then
        SMB=yes
      else
        SMB=no
      fi
      ;;
    *) fail "--smb must be yes or no"; return 1 ;;
  esac
  [ "$SMB" = yes ] || return 0
  SMB_OWNER=${OWNER:-$(existing_value OWNER)}
  valid_name "$SMB_OWNER" || { fail "the owner is not known yet, so the share cannot be set up"; return 1; }
  choose_smb_mode || return 1
  choose_smb_access || return 1
}

smb_summary() {
  [ "$SMB" = yes ] || return 0
  if [ "$SMB_MODE" = rw ]; then
    printf 'read-write, your own folder'
  else
    printf 'read-only, the whole library'
  fi
  if [ "$SMB_GUEST" = yes ]; then
    printf ', no password'
  else
    printf ', user %s' "$SMB_USER"
  fi
}

render_smb_share() {
  printf '[global]\n'
  printf '  server min protocol = SMB2\n'
  if [ "$3" = yes ]; then
    printf '  map to guest = Bad User\n'
  fi
  printf '  load printers = no\n'
  printf '  disable spoolss = yes\n'
  printf '\n[homes]\n  available = no\n  browseable = no\n'
  printf '\n[printers]\n  available = no\n  browseable = no\n'
  printf '\n[print$]\n  available = no\n  browseable = no\n'
  printf '\n[tinycloud]\n'
  printf '  comment = TinyCloud\n'
  printf '  path = %s\n' "$1"
  printf '  browseable = yes\n'
  if [ "$2" = rw ]; then
    printf '  read only = no\n'
  else
    printf '  read only = yes\n'
  fi
  printf '  hosts allow = 127.0.0.1 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 fc00::/7 fe80::/10\n'
  if [ "$3" = yes ]; then
    printf '  guest ok = yes\n  guest only = yes\n'
  else
    printf '  guest ok = no\n  valid users = %s\n' "$4"
    printf '  ; tinycloud-smb-user=%s\n' "$4"
  fi
  printf '  force user = %s\n  force group = %s\n' "$5" "$6"
  printf '  create mask = 0664\n  directory mask = 0775\n'
  printf '  follow symlinks = no\n'
}

smb_include_line() {
  printf 'include = %s' "$(smb_file)"
}

smb_add_include() {
  sai_main=$SMB_CONF_DIR/smb.conf
  if [ ! -f "$sai_main" ]; then
    printf '[global]\n' > "$sai_main" || return 1
  fi
  if ! grep -qxF "$(smb_include_line)" "$sai_main"; then
    printf '\n%s\n' "$(smb_include_line)" >> "$sai_main" || return 1
  fi
}

smb_drop_include() {
  sdi_main=$SMB_CONF_DIR/smb.conf
  [ -f "$sdi_main" ] || return 0
  sdi_tmp=$(mktemp) || return 1
  grep -vxF "$(smb_include_line)" "$sdi_main" > "$sdi_tmp"
  cat "$sdi_tmp" > "$sdi_main"
  rm -f "$sdi_tmp"
}

smb_make_user() {
  if getent passwd "$1" > /dev/null 2>&1; then
    return 0
  fi
  useradd --system --no-create-home --shell /usr/sbin/nologin "$1"
}

smb_restart() {
  systemctl enable smbd nmbd > /dev/null 2>&1
  systemctl restart smbd || return 1
  systemctl restart nmbd > /dev/null 2>&1 || true
}

smb_enable() {
  if [ "$SMB_MODE" = rw ]; then
    se_path=$NODE_HOME/data/library/$SMB_OWNER
  else
    se_path=$NODE_HOME/data/library
  fi
  if [ "$DRY_RUN" = true ]; then
    say "+ install samba"
    say "+ write $(smb_file) ($SMB_MODE, $se_path)"
    if [ "$SMB_GUEST" != yes ]; then
      say "+ add the SMB user $SMB_USER"
    fi
    say "+ systemctl restart smbd nmbd"
    return 0
  fi
  if ! ensure_package samba; then
    say "Skipping the SMB share."
    return 0
  fi
  se_user=$(getent passwd 1000 | cut -d : -f 1)
  se_group=$(id -gn 1000 2> /dev/null)
  if [ -z "$se_user" ] || [ -z "$se_group" ]; then
    fail "no account has user ID 1000, which owns the library. Create one and run setup again."
    return 1
  fi
  mkdir -p "$se_path" "$SMB_CONF_DIR" || return 1
  chown 1000:1000 "$se_path" 2> /dev/null || true
  render_smb_share "$se_path" "$SMB_MODE" "$SMB_GUEST" "$SMB_USER" "$se_user" "$se_group" > "$(smb_file)" || return 1
  chmod 644 "$(smb_file)"
  smb_add_include || return 1
  if ! testparm -s "$SMB_CONF_DIR/smb.conf" > /dev/null 2>&1; then
    smb_drop_include
    rm -f "$(smb_file)"
    fail "the Samba settings did not check out, so the share was not enabled"
    return 1
  fi
  if [ "$SMB_GUEST" != yes ]; then
    smb_make_user "$SMB_USER" || { fail "could not create the SMB user"; return 1; }
    if ! printf '%s\n%s\n' "$SMB_PASSWORD" "$SMB_PASSWORD" | smbpasswd -a -s "$SMB_USER" > /dev/null 2>&1; then
      fail "could not set the SMB password"
      return 1
    fi
  fi
  smb_restart || { fail "Samba did not start"; return 1; }
}

smb_disable() {
  smb_present || return 0
  sd_user=$(sed -n 's/^ *; tinycloud-smb-user=//p' "$(smb_file)" | head -n 1)
  if [ "$DRY_RUN" = true ]; then
    say "+ remove $(smb_file)"
    say "+ systemctl restart smbd"
    return 0
  fi
  rm -f "$(smb_file)"
  smb_drop_include
  if [ -n "$sd_user" ]; then
    smbpasswd -x "$sd_user" > /dev/null 2>&1 || true
  fi
  systemctl restart smbd > /dev/null 2>&1 || true
  say "The SMB share is removed. Samba itself is still installed."
}

setup_smb() {
  case $SMB in
    yes) smb_enable ;;
    no) smb_disable ;;
  esac
}
