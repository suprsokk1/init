#!/bin/bash
getopt --name="${0##*/}" --longoptions=list,host: -- "$@" >/dev/null || exit

if false; then
  if command -v jq &>/dev/null; then
    if ! ((NEST)); then
      # env NEST=1 bash "$0" "$@" | command jq -M
      env NEST=1 bash "$0" "$@" | command python -m json.tool --indent=2
      exit
    fi
  fi
fi

declare -x GIT_WORK_TREE
read -r GIT_WORK_TREE < <(command git rev-parse --show-toplevel)

read -r WORKDIR < <(command date  '+/dev/shm/%Y/%m/%d/%H')
command mkdir -p -- "$WORKDIR" &>/dev/null
pushd "$WORKDIR" &>/dev/null || exit

TODO() { false; }

__command() {
  local TIMEOUT
  TIMEOUT=5
  /usr/bin/command timeout ${TIMEOUT}s "$@"
  case ${?} in
    ( 0 )

    ;;

    ( 12? )

    ;;
  esac
}

set -o allexport ${DEBUG:+-s xtrace}
declare -a FACT_PROXMOX_ROLES
declare -a FACT_PROXMOX_USERS
declare -A REQUIRE_EXECUTABLES
declare -a INSTALLED_EXECUTABLES
declare -a FACT_PROXMOX_VMLIST
declare FACT_PROXMOX
declare FACT_PULL_URL
declare FACT_PULL_BRANCH
declare FACT_PULL_USER
declare FACT_PULL_REPO
declare FACT_DISTRO_NAME
declare FACT_DISTRO_VERSION
declare FACT_DISTRO
declare FACT_CHASSIS
declare FACT_ACCESS
declare FACT_KERNEL
declare FACT_PUBLIC_IP
declare JSON_WHOAMI
declare FACT_BOOTSTRAP_COMPLETE
declare FACT_BOOTSTRAP_COMPLETE_TAG_FILE
declare FACT_IS_VIRTUAL
declare FACT_IS_CONTAINER
declare FACT_IS_PHYSICAL


FACT_BOOTSTRAP_COMPLETE_TAG_FILE="/BOOTSTRAP_COMPLETE.TAG"
FACT_BOOTSTRAP_COMPLETE=false
FACT_ACCESS="user"
FACT_IS_VIRTUAL=false
FACT_IS_CONTAINER=false
FACT_IS_PHYSICAL=false
FACT_PROXMOX=false

if TODO; then
  declare TEST
  declare HOST
  declare LIST
  declare HOSTOPTARG

  set - $(getopt --name="${0##*/}" --longoptions=list,host:,test --options=lth: -- "$@") || exit

  while true; do
    case "${1:-}" in
      ( -t | --test )  ((TEST++))  ;;

      ( -h | --host )  ((HOST++)); shift; HOSTOPTARG="$1" ;;

      ( -l | --list )  ((LIST++))  ;;

      ( -- )      break ;;

      ( * ) ;;
    esac
    shift
  done

  if ((TEST)); then
    if ((LIST)); then
      exec ansible-inventory --inventory "$0" --list
    elif ((HOST)); then
      if [ -n "$HOSTOPTARG" ]; then
        exec ansible-inventory --inventory "$0" --host "$HOSTOPTARG"
      else
        exit 1
      fi
      exec ansible-inventory --inventory "$0" --list
    else
      exit 1
    fi
  fi
fi

source /etc/os-release

# SCRIPT="${OLDPWD}"/"${0}"
PS4=$'\b${BASH_SOURCE[0]##*/}:${FUNCNAME:+${FUNCNAME[0]}:}rc=${?}:$(tput setaf 230)$(printf "%0*d" 3 ${LINENO})$(tput sgr0): '
LC_ALL=C
NO_COLOR=1

FACT_DISTRO_NAME="$ID"
FACT_DISTRO="${ID}${VERSION_ID//./_}"
FACT_DISTRO_VERSION="${VERSION_ID//./_}"

: ${HOSTNAME:-$(< /etc/hostname)}
REQUIRE_EXECUTABLES=(
  ["jq"]=/usr/bin/jq
  ["jo"]=/usr/bin/jo
  ["gron"]=/usr/bin/gron
  ["doctl"]=/snap/bin/doctl
)
read -r FACT_KERNEL < <(command uname)
read -r _ _ _ FACT_PULL_USER FACT_PULL_REPO _ < <(
  command git -C "$OLDPWD" remote get-url origin |
    command sed -E 's#[[:punct:]]+# #g'
)

read -r FACT_PULL_URL    < <(command git -C $OLDPWD remote get-url origin)
read -r FACT_PULL_BRANCH < <(command git -C $OLDPWD rev-parse --abbrev-ref HEAD)
read -r FACT_CHASSIS     < <(command hostnamectl chassis)

read -r FACT_UID < <(command id -u)
read -r FACT_GID < <(command id -g)

uid=$(id -u)
gid=$(id -g)

if ! [ -s JSON_WHOAMI ]; then
  command curl \
    --silent \
    -L 'https://ifconfig.net/json' \
    -H 'Accept: application/json' \
    -o JSON_WHOAMI
fi

if ! [ -s FACT_PUBLIC_IP ]; then
  command curl --retry 3 -sL ifconfig.net/ip -o FACT_PUBLIC_IP
fi

if ! [ -s FACT_FQDN ]; then
  command xargs -r -a FACT_PUBLIC_IP dig +short -x | command sed -E 's#\x2e$##' > FACT_FQDN &
fi

if command -v doctl &>/dev/null ; then
  if command doctl compute droplet list &>/dev/null; then
    if ! [ -s TXT_DO_API_TOKEN ]; then
      if [ -s "$HOME"/.config/doctl/config.yaml ]; then
        command sed -E '/access-token:./!d;s###' "$HOME"/.config/doctl/config.yaml | command xargs -r > TXT_DO_API_TOKEN
      fi
    fi

    if ! [ -s TXT_DO_DOMAIN_LIST ] ; then
      command doctl compute domain list --format Domain --no-header > TXT_DO_DOMAIN_LIST
    fi

    while read -r DOMAIN; do
      if ! [ -s "JSON_DO_DOMAIN_${DOMAIN}_RECORD_LIST" ] ; then
        command doctl compute domain list --output=json > "JSON_DO_DOMAIN_${DOMAIN}_RECORD_LIST" &
      fi
    done < <(command sed -E 'y/./_/;s#.*#\U&#' TXT_DO_DOMAIN_LIST)

    if ! [ -s JSON_DO_DROPLET_LIST ] ; then
      command doctl compute droplet list --output=json > JSON_DO_DROPLET_LIST &
    fi

    if ! [ -s JSON_DO_DOMAIN_LIST ] ; then
      command doctl compute domain list --output=json > JSON_DO_DOMAIN_LIST &
    fi

  fi
fi

wait

if command /usr/bin/env LC_ALL=C grep --perl-regexp --silent -- '\bProxmox\b' /etc/issue; then
  FACT_PROXMOX=true
  if [ -s /etc/pve/.vmlist ]; then
     mapfile FACT_PROXMOX_VMLIST < /etc/pve/.vmlist
  fi
   mapfile FACT_PROXMOX_ROLES < <(pveum role list --noborder | awk '{print $1}')
   mapfile FACT_PROXMOX_USERS < <(pveum user list --noborder | awk '{print $1}')
fi

if command systemd-detect-virt --container --quiet; then
  VIRT=containers
  FACT_IS_CONTAINER=true
elif command systemd-detect-virt --vm --quiet; then
  VIRT=virtual
  FACT_IS_VIRTUAL=true
else
  VIRT=physical
  FACT_IS_PHYSICAL=true
fi

if [ -s "$HOME"/.ssh/known_hosts ]; then
  mapfile ssh_known_hosts  < <(
    command /usr/bin/awk '{print $1}' ~/.ssh/known_hosts |
      command sort | command uniq |
      command grep -P -- '(?:10\x2e|172\x2e1[67]|192\x2e168(?!=\x2e122)).*|\x2eno\b' |
      command xargs -r printf ' "%s",' |
      command head -c -1
  )

  mapfile ssh_known_hosts_raw  < <(
    command /usr/bin/awk '{print $1}' ~/.ssh/known_hosts |
      command  | command uniq |
      command grep -P -- '(?:10\x2e|172\x2e1[67]|192\x2e168(?!=\x2e122)).*|\x2eno\b'
  )
fi


ip_address_group_names() {
  command ip a |
    command gawk  -vRS='[[:space:]]+' -vFS='\x2e' '/^([[:digit:]]+\x2e){3}([[:digit:]]+)(\/[[:digit:]]{1,2})?$/{gsub(/[:.\x2f]/,"_"); print "net_"$0}' |
    command xargs
}
export -f ip_address_group_names

print_ssh_keys() {
  command /usr/bin/find ~/.ssh/ -maxdepth 1 -mindepth 1 -name 'id_*.pub' \
    -printf \" -exec sed -zE 's#[\n ]+##g' {} \; \
    -printf '",' |
    command sed -zE 's#,$##'
}
export -f print_ssh_keys

wrap_object() {
  case $# in
    (1) printf '"%s":' "$1" ;;
    (0) ;;
    (*) exit 1
  esac

  /usr/bin/sed -Ez 's#.*#{&}#'
}
export -f wrap_object

print_json_mapping() {
    local count
    count=$#
    if ! ((count % 2 == 0)); then
        exit 1
    fi

    while true; do
        case x"$2" in
          ( x\[*\] ) printf '"%s": %s' "$1" "$2" ;;
          ( x\{*\} ) printf '"%s": %s' "$1" "$2" ;;
          ( x* )     printf '"%s": "%s"' "$1" "$2";;
        esac
        shift 2
        if [ -n "$*" ]; then
            echo -en ','
        else
            break
        fi
    done
}
export -f print_json_mapping

print_json_array() {
    local count
    count=$#
    if ! ((count % 2 == 0)); then
        exit 1
    fi
    echo -en '['
    while true; do
        case x"$1" in
          ( x\[*\] ) printf '%s'   "$1" ;;
          ( x\{*\} ) printf '%s'   "$1" ;;
          ( x* )     printf '"%s"' "$1" ;;
        esac
        shift 1
        if [ -n "$*" ]; then
            echo -en ','
        else
            break
        fi
    done
    echo -en ']'
}

export -f print_json_array

print_group() {
  set - ${1//#[\x22\x0a\x09]/}
  print_json_mapping \
    hosts "[\"${HOSTNAME}\"]" \
    vars  "{${JSON_VARS[*]}}" | wrap_object "$1"
}
export -f print_group

if TODO; then
  if command -v dig &>/dev/null; then
    read -r FACT_PUBLIC_IP < <(command /usr/bin/dig TXT +short o-o.myaddr.l.google.com @ns1.google.com | command /usr/bin/xargs)
  fi
fi

if [ -f "$FACT_BOOTSTRAP_COMPLETE_TAG_FILE" ]; then
  FACT_BOOTSTRAP_COMPLETE=true
fi

mapfile JSON_VARS < <(
  print_json_mapping \
    ansible_user_id              $USER \
    ansible_user_dir             $HOME \
    ansible_connection           local \
    pull_user                    $FACT_PULL_USER \
    pull_repo                    $FACT_PULL_REPO \
    pull_url                     $FACT_PULL_URL \
    pull_branch                  $FACT_PULL_BRANCH \
    bootstrap_complete_tag_file  $FACT_BOOTSTRAP_COMPLETE_TAG_FILE \
    install_packages             '["jq"]' \
    fqdn                         $(command xargs -a FACT_FQDN) \
    public_ip                    $(command xargs -a FACT_PUBLIC_IP)

  echo -en ','

  if ${FACT_PROXMOX:-false}; then
  {
    echo -en '"users":'
    print_json_array "${FACT_PROXMOX_USERS[@]}"
    echo -en ','
    echo -en '"roles":'
    print_json_array "${FACT_PROXMOX_ROLES[@]}"
  } | wrap_object proxmox
  echo -en ','
  fi


  # print_json_mapping

  cat <<JSON_EOF
$(printf '"%s": true,\n' $(ip_address_group_names))
"ifconfig.net": $(if test -s JSON_WHOAMI; then command cat JSON_WHOAMI; else echo '[]'; fi),
"ssh_keys":[ $(print_ssh_keys) ],
"galaxy": {
  "collections": [ ],
  "roles": [ ]
},
"is": {
   "virtual": ${FACT_IS_VIRTUAL},
   "physical": ${FACT_IS_PHYSICAL},
   "container": ${FACT_IS_CONTAINER}
}
JSON_EOF
)

mapfile JSON_VARS_ALT <<-JSON_VARS_EOF
"ansible_user_id": "${USER}",
"ansible_user_dir": "${HOME}",
"ansible_connection": "local",
"pull_user": "${FACT_PULL_USER}",
"pull_repo": "${FACT_PULL_REPO}",
"pull_url": "${FACT_PULL_URL}",
"pull_branch": "${FACT_PULL_BRANCH}",
$(printf '"%s": true,\n' $(ip_address_group_names))
$(if [ -s FACT_PUBLIC_IP ]; then printf '"%s": "%s",' public_ip $(command xargs -a FACT_PUBLIC_IP); fi)
$(if [ -s FACT_FQDN ]; then printf '"%s": "%s",' fqdn $(command xargs -a FACT_FQDN); fi)
"bootstrap_complete_tag_file": "${FACT_BOOTSTRAP_COMPLETE_TAG_FILE}",
"install_packages": ["jq"],
"ifconfig.net": $(if true; then command cat JSON_WHOAMI; else echo '[]'; fi),
"ssh_keys":[ $(print_ssh_keys) ],
"galaxy": {
  "collections": [ ],
  "roles": [ ]
},
"is": {
   "virtual": ${FACT_IS_VIRTUAL},
   "physical": ${FACT_IS_PHYSICAL},
   "container": ${FACT_IS_CONTAINER}
}
JSON_VARS_EOF

join() {
  local IFS
  IFS="$1"
  shift
  set - "$*"
  echo "$*"
}

quote() {
  if [ -t 0 ]; then
     printf '"%s" ' "$@"
  else
    command xargs -r printf '"%s" '
  fi
}

export -f join
export -f quote


case $(command /usr/bin/id  -u) in
  ( 0 )
  FACT_ACCESS="root"
  ;;

  ( * )
  if [ -n "${SUDO_USER:-}"  ]; then
  FACT_ACCESS="elevated"
  fi
esac

mapfile GROUP_NAMES <<EOF
local
${FACT_KERNEL}
${FACT_KERNEL,,}
${FACT_ACCESS}
${VIRT}
${FACT_CHASSIS}
$FACT_DISTRO_NAME
${FACT_DISTRO_NAME}_${FACT_DISTRO_VERSION}
${FACT_DISTRO}
${FACT_ACCESS}_${VIRT}_${FACT_CHASSIS}_${FACT_DISTRO_NAME}_${FACT_DISTRO_VERSION}
${FACT_ACCESS}_${VIRT}_${FACT_CHASSIS}_${FACT_DISTRO}
${FACT_CHASSIS}_${FACT_DISTRO}_${VIRT}_${FACT_ACCESS}
${FACT_DISTRO}_${VIRT}_${FACT_ACCESS}
${FACT_DISTRO}_${FACT_CHASSIS}_${FACT_ACCESS}
EOF

if ! ${FACT_BOOTSTRAP_COMPLETE:-false}; then
  GROUP_NAMES+=("new")
fi

if ${FACT_PROXMOX:-false}; then
  GROUP_NAMES+=("proxmox")
fi

while [ -n "$*" ]; do
case "$1" in
  (--list)

    cat <<-LIST_LONGOPTION_EOF
{
 "all": {
    "children": [$(join , $(quote ${GROUP_NAMES[*]}))]
 },
 "local": {
    "hosts": [ "localhost" ],
    "vars": { ${JSON_VARS[*]} }
  },
LIST_LONGOPTION_EOF

    for exe in "${REQUIRE__EXECUTABLES[@]}"; do
      if command -v "$exe" &>/dev/null; then
        INSTALLED_EXECUTABLES+=("$exe")
      fi
    done

    if ! $FACT_BOOTSTRAP_COMPLETE; then
      print_group "new"
      echo -en ','
    fi

    for group in "${GROUP_NAMES[@]}"
    do
      print_group "$group"
      echo -en ','
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
