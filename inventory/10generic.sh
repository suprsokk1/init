#!/bin/bash
getopt --name="${0##*/}" --longoptions=list,host: -- "$@" >/dev/null || exit

if true; then
  if command -v jq &>/dev/null; then
    if ! ((NEST)); then
      env NEST=1 bash "$0" "$@" | command jq -M
      exit
    fi
  fi
fi

read -r GIT_WORK_TREE < <(command git rev-parse --show-toplevel)

read -r WORKDIR < <(command date  '+/dev/shm/%Y/%m/%d/%H')
command mkdir -p -- "$WORKDIR" &>/dev/null
pushd "$WORKDIR" &>/dev/null || exit

TODO() { false; }

set -o allexport ${DEBUG:+-s xtrace}

declare -A REQUIRE_EXECUTABLES
declare -a INSTALLED_EXECUTABLES
declare FACT_PULL_URL
declare FACT_PULL_BRANCH
declare FACT_PULL_USER
declare FACT_PULL_REPO
declare FACT_DISTRO
declare FACT_DISTRO_VERSION
declare FACT_CHASSIS
declare FACT_ACCESS
declare FACT_PUBLIC_IP
declare JSON_WHOAMI
declare FACT_BOOTSTRAP_COMPLETE
declare FACT_BOOTSTRAP_COMPLETE_TAG_FILE

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

FACT_DISTRO="$ID"
FACT_DISTRO_VERSION="${VERSION_ID//./-}"

: ${HOSTNAME:-$(< /etc/hostname)}
REQUIRE_EXECUTABLES=(
  ["jq"]=/usr/bin/jq
  ["jo"]=/usr/bin/jo
  ["gron"]=/usr/bin/gron
  ["doctl"]=/snap/bin/doctl
)
read -r _ _ _ FACT_PULL_USER FACT_PULL_REPO _ < <(
  command git -C "$OLDPWD" remote get-url origin |
    command sed -E 's#[[:punct:]]+# #g'
)

read -r FACT_PULL_URL < <(command git -C $OLDPWD remote get-url origin)
read -r FACT_PULL_BRANCH < <(command git -C $OLDPWD rev-parse --abbrev-ref HEAD)
read -r FACT_CHASSIS < <(command hostnamectl chassis)
FACT_BOOTSTRAP_COMPLETE_TAG_FILE="/ANSIBLE_FACT_PULL_FACT_BOOTSTRAP_COMPLETE.TAG"
FACT_BOOTSTRAP_COMPLETE=false

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

if command -v doctl &>/dev/null ; then
  if command doctl compute droplet list &>/dev/null; then
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

if command systemd-detect-virt --container --quiet; then
  VIRT=containers
elif command systemd-detect-virt --vm --quiet; then
  VIRT=virtual
else
  VIRT=physical
fi

if [ -s "$HOME"/.ssh/known_hosts ]; then
  mapfile ssh_known_hosts  < <(
    command /usr/bin/awk '{print $1}' ~/.ssh/known_hosts |
      command  | command uniq |
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

print_ssh_keys() {
  command /usr/bin/find ~/.ssh/ -maxdepth 1 -mindepth 1 -name 'id_*.pub' \
    -printf \" -exec sed -zE 's#[\n ]+##g' {} \; \
    -printf '",' |
    command sed -zE 's#,$##'
}

print_group() {
  local group
  group="$1"
  cat <<LOOP_LIST_LONGOPTION_EOF
  "${group}": {
    "hosts": [ "${HOSTNAME}" ],
    "vars": {
      ${JSON_VARS[*]}
    }
  },
LOOP_LIST_LONGOPTION_EOF
}


print_json_mapping() {
  local fact
  local i
  i=0

  # count=${#FACTS[@]}
  count=$#
  # for fact in "${FACTS[@]}"; do
  for var in "$@"; do
    if ! [ -n "${!var}" ]; then
      continue
    fi

    printf '"%s": "%s"' "${var,,}" "${!var}"
    if ((++i < count)) || true; then
      echo -en ,
    fi
    echo
  done
}

case "$VIRT" in                 # FIXME
  ( virtual )
    mapfile JSON_VARS_VIRTUAL  <<'VIRTUAL_EOF'
"ansible_env": {
  "ANSIBLE_VAULT_PASSWORD_FILE": "vault-virtual-password"
},
VIRTUAL_EOF
    ;;

  ( * )
    mapfile JSON_VARS_VIRTUAL  <<'DEFAULT_EOF'
"ansible_env": {
  "ANSIBLE_VAULT_PASSWORD_FILE": "vault-default-password"
},
DEFAULT_EOF
esac

if TODO; then
  if command -v dig &>/dev/null; then
    read -r FACT_PUBLIC_IP < <(command /usr/bin/dig TXT +short o-o.myaddr.l.google.com @ns1.google.com | command /usr/bin/xargs)
  fi
fi

if [ -s "$FACT_BOOTSTRAP_COMPLETE_TAG_FILE" ]; then
  FACT_BOOTSTRAP_COMPLETE=true
fi

# | command sed -e 's#[^_]+##'
mapfile FACTS < <(compgen -A 'variable' -X '!FACT_*')

# $(print_json_mapping "${FACTS[@]}") # FIXME

mapfile JSON_VARS <<-JSON_VARS_EOF
${JSON_VARS_VIRTUAL:+${JSON_VARS_VIRTUAL[@]}}"ansible_user_id": "${USER}",
"ansible_user_dir": "${HOME}",
"ansible_connection": "local",
"pull_user": "${FACT_PULL_USER}",
"pull_repo": "${FACT_PULL_REPO}",
"pull_url": "${FACT_PULL_URL}",
"pull_branch": "${FACT_PULL_BRANCH}",
"bootstrap_complete_tag_file": "${FACT_BOOTSTRAP_COMPLETE_TAG_FILE}",
"install_packages": ["jq"],
"ifconfig.net": $(if true;then command cat JSON_WHOAMI; else echo '[]'; fi),
"ssh_keys":[ $(print_ssh_keys) ],
"galaxy": {
  "collections": [ ],
  "roles": [ ]
}
JSON_VARS_EOF

while [ -n "$*" ]; do
case "$1" in
  (--list)
    FACT_ACCESS="user"               # DEFAULT
    case $(command /usr/bin/id  -u) in
      ( 0 )
      FACT_ACCESS="root"
      ;;

      ( * )
      if [ -n "${SUDO_USER:-}"  ]; then
        FACT_ACCESS="elevated"
      fi
    esac

    cat <<-LIST_LONGOPTION_EOF
{
 "all": {
    "children": [
      "local",
      $(if ! $FACT_BOOTSTRAP_COMPLETE; then echo -en '"new",'; fi)
      "${FACT_ACCESS}",
      "${VIRT}",
      "${FACT_CHASSIS}",
      "${FACT_DISTRO}",
      "${FACT_DISTRO}-${FACT_DISTRO_VERSION}",
      "${FACT_DISTRO}${FACT_DISTRO_VERSION}",
      "${FACT_DISTRO^}${FACT_DISTRO_VERSION}",
      "${FACT_ACCESS}-${VIRT}-${FACT_CHASSIS}-${FACT_DISTRO}-${FACT_DISTRO_VERSION}"
    ]
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
    fi

    for group in \
      "$FACT_ACCESS" \
      "$VIRT" \
      "$FACT_CHASSIS" \
      "$FACT_DISTRO" \
      "${FACT_DISTRO}-${FACT_DISTRO_VERSION}" \
      "${FACT_DISTRO}${FACT_DISTRO_VERSION}" \
      "${FACT_DISTRO^}${FACT_DISTRO_VERSION}" \
      "${FACT_ACCESS}-${VIRT}-${FACT_CHASSIS}-${FACT_DISTRO}-${FACT_DISTRO_VERSION}"
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
