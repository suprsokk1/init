#!/bin/bash
set -o allexport ${DEBUG:+-s xtrace}
source /etc/os-release

declare -a INSTALLED_EXECUTABLES
declare -a REQUIRE_EXECUTABLES
declare PULL_URL
declare PULL_BRANCH
declare DISTRO
declare DISTRO_VERSION
declare CHASSIS
declare ACCESS

dir=/dev/shm/"$(date -I)"
mkdir -p "$dir" &>/dev/null

pushd "$dir" &>/dev/null || exit
# SCRIPT="${OLDPWD}"/"${0}"
PS4=$'\b${BASH_SOURCE[0]##*/}:${FUNCNAME:+${FUNCNAME[0]}:}rc=${?}:$(tput setaf 230)$(printf "%0*d" 3 ${LINENO})$(tput sgr0): '
LC_ALL=C
NO_COLOR=1

if [ -n "$INSIDE_EMACS" -a -z "$@" ]; then
  set - --list
fi

: ${HOSTNAME:-$(< /etc/hostname)}
REQUIRE_EXECUTABLES=(jq jo)
PULL_URL="$(git -C $OLDPWD remote get-url origin)"
PULL_BRANCH="$(git -C $OLDPWD rev-parse --abbrev-ref HEAD)"
DISTRO="$ID"
DISTRO_VERSION="${VERSION_ID//./-}"
CHASSIS=$(hostnamectl chassis)

uid=$(id -u)
gid=$(id -g)

if systemd-detect-virt --container --quiet; then
  VIRT=containers
elif systemd-detect-virt --vm --quiet; then
  VIRT=virtual
else
  VIRT=physical
fi

if [ -s "$HOME"/.ssh/known_hosts ]; then
  mapfile ssh_known_hosts  < <(
    /usr/bin/awk '{print $1}' ~/.ssh/known_hosts |
      sort | uniq |
      grep -P -- '(?:10\x2e|172\x2e1[67]|192\x2e168(?!=\x2e122)).*|\x2eno\b' |
      xargs -r printf ' "%s",' | head -c -1
  )

  mapfile ssh_known_hosts_raw  < <(
    /usr/bin/awk '{print $1}' ~/.ssh/known_hosts |
      sort | uniq |
      grep -P -- '(?:10\x2e|172\x2e1[67]|192\x2e168(?!=\x2e122)).*|\x2eno\b'
  )
fi


print-ssh-keys() {
  /usr/bin/find ~/.ssh/ -maxdepth 1 -mindepth 1 -name 'id_*.pub' \
    -printf \" -exec sed -zE 's#[\n ]+##g' {} \; \
    -printf '",' |
    sed -zE 's#,$##'
}

case $VIRT in
  (virtual)
    mapfile JSON_VARS_VIRTUAL  <<'VIRTUAL_EOF'
"ansible_env": {
  "ANSIBLE_VAULT_PASSWORD_FILE": "vault-virtual-password"
},
VIRTUAL_EOF
    ;;
  (*)
    mapfile JSON_VARS_VIRTUAL  <<'DEFAULT_EOF'
"ansible_env": {
  "ANSIBLE_VAULT_PASSWORD_FILE": "vault-default-password"
},
DEFAULT_EOF
esac

mapfile JSON_VARS <<-JSON_VARS_EOF
${JSON_VARS_VIRTUAL:+${JSON_VARS_VIRTUAL[@]}}"ansible_user_id": "${USER}",
"ansible_user_dir": "${HOME}",
"ansible_connection": "local",
"pull_url": "${PULL_URL}",
"pull_branch": "${PULL_BRANCH}",
"install_packages": ["jq"],
"bootstrap_complete_tag_file": "/ANSIBLE_PULL_BOOTSTRAP_COMPLETE.TAG",
"ssh_keys":[ $(print-ssh-keys) ],
"galaxy": {
  "collections": [ ],
  "roles": [ ]
}
JSON_VARS_EOF


while [ -n "$*" ]; do
case "$1" in
  (--list)
    cat <<-LIST_LONGOPTION_EOF
{
 "all": {
    "children": [
      "local",
      "${VIRT}",
      "${DISTRO}",
      "${DISTRO}${DISTRO_VERSION}"
    ]
 },
 "local": {
    "hosts": [ "localhost" ],
    "vars": { ${JSON_VARS[*]} }
  },
LIST_LONGOPTION_EOF

    print_group() {
      local group
      group="$1"
      cat<<LOOP_LIST_LONGOPTION_EOF
  "${group}": {
    "hosts": [ "${HOSTNAME}" ],
    "vars": {
      ${JSON_VARS[*]}
    }
  },
LOOP_LIST_LONGOPTION_EOF
    }


    for exe in "${REQUIRE__EXECUTABLES[@]}"; do
    if which "$exe" &>/dev/null; then
      INSTALLED_EXECUTABLES+=("$exe")
    fi
    done

    ACCESS="user"
    case $(command /usr/bin/id  -u) in
      ( 0 )
      ACCESS="root"
      ;;

      ( * )
      if [ -n "${SUDO_USER:-}"  ]; then
        ACCESS="elevated"
      fi
    esac

    for group in \
      "${VIRT}" \
      "${ACCESS}-${VIRT}" \
      "${DISTRO}" \
      "${ACCESS}-${DISTRO}" \
      "${DISTRO}-${DISTRO_VERSION}" \
      "${ACCESS}-${DISTRO}-${DISTRO_VERSION}"\
      "${DISTRO}-${CHASSIS}" \
      "${ACCESS}-${DISTRO}-${CHASSIS}" \
      "${CHASSIS}-${DISTRO}-${DISTRO_VERSION}" \
      "${ACCESS}-${CHASSIS}-${DISTRO}-${DISTRO_VERSION}"
    do
      print_group "$group"
    done

    cat <<LIST_LONGOPTION_EOF
  "_meta": {
    "hostvars": {
      "${HOSTNAME}": { ${JSON_VARS[*]} },
      "localhost": { ${JSON_VARS[*]} }
    }
  }
}
LIST_LONGOPTION_EOF
    ;;

  (--host)
    cat <<HOST_LONGOPTION_EOF
{
  "_meta": {
    "hostvars": {
      "localhost": { ${JSON_VARS[*]}  },
      "${HOSTNAME}": { ${JSON_VARS[*]}  }
    }
  }
}
HOST_LONGOPTION_EOF
    ;;
  (--)
esac
break
done
