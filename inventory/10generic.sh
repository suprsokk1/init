#!/bin/bash
dir=/dev/shm/"$(date -I)"
mkdir -p "$dir" &>/dev/null
pushd "$dir" &>/dev/null || exit
exec 3<> /dev/tty
SCRIPT="${OLDPWD}"/"${0}"
BASH_XTRACEFD=3
PS4=$'\b${BASH_SOURCE[0]##*/}:${FUNCNAME:+${FUNCNAME[0]}:}rc=${?}:$(tput setaf 230)$(printf "%0*d" 3 ${LINENO})$(tput sgr0): '
export PS4
LC_ALL=C

if [ "${DEBUG:-0}" -eq 1 ]; then
  notify-send -- "${0##*/}" "$@"
  set -o xtrace
fi

if [ -n "$INSIDE_EMACS" -a -z "$@" ]; then
  set - --list
fi

set - $(getopt -n "${0##*/}" --options=h:,l  --longoptions=host:,list -- "$*") || exit

set -o allexport
source /etc/os-release
NO_COLOR=1
: ${UID:-$(id -u)}
: ${GID:-$(id -g)}
set +o allexport

trap 'TRAPEXIT $? $LINENO "$@"' EXIT

TRAPEXIT() {
  local rc line rest
  set - "${rest[@]}"
  if [ -n "$DEBUG" ]; then
    :
  fi >&3
}

__vars() {
  printf '"%s": "%s",' \
    'ansible_user_id' root \
    'pull_url' "${pull_url}" \
    'pull_branch' "${pull_branch}"
}

mapfile ssh_known_hosts  < <(
  awk '{print $1}' ~/.ssh/known_hosts |
    sort | uniq |
    grep -P -- '(?:10\x2e|172\x2e1[67]|192\x2e168(?!=\x2e122)).*|\x2eno\b' |
    xargs -r printf ' "%s",' | head -c -1
)

mapfile ssh_known_hosts_raw  < <(
  awk '{print $1}' ~/.ssh/known_hosts |
    sort | uniq |
    grep -P -- '(?:10\x2e|172\x2e1[67]|192\x2e168(?!=\x2e122)).*|\x2eno\b'
)

export HOSTNAME
export ssh_known_hosts
export ssh_known_hosts_raw
export pull_url="$(git -C $OLDPWD remote get-url origin)"
export pull_branch="$(git -C $OLDPWD rev-parse --abbrev-ref HEAD)"

mapfile JSON_VARS <<-JSON_VARS_EOF
"ansible_user_id": "${USER}",
"ansible_user_dir": "${HOME}",
"pull_url": "${pull_url}",
"pull_branch": "${pull_branch}",
"packages": ["jq"]
JSON_VARS_EOF

if systemd-detect-virt --container --quiet; then
  VIRT=containers
elif systemd-detect-virt --vm --quiet; then
  VIRT=vms
else
  VIRT=physical
fi

export VIRT
export JSON_VARS

_group() {
  local group
  group=$1
  shift

  printf '"%s": {\n"hosts": [\n' "$group"
  printf '"%s",' $* | head -c -1
  printf '\n],'

  printf '"vars": {\n'
  printf '"%s": "%s",' \
    'ansible_user_id' root \
    'pull_url' "${pull_url}" \
    'pull_branch' "${pull_branch}" | head -c -1
  printf '}\n'
  printf '}\n'

}

_group_v2() {
  local group
  local vars
  group=$1
  shift

  for arg; do
    case $arg in
      (--)
      ;;

      *)
    esac
    shift
  done

  printf '"%s": {"hosts": [' "$group"
  printf '"%s",' $* | head -c -1
  printf '],'

  printf '"vars": {'
  vars=( 'ansible_user_id' root
         'pull_url' "${pull_url}"
         'pull_branch' "${pull_branch}")
  local i
  i=0
  for var in ${vars[@]}; do
    if ((i++ % 2 == 0)); then
      :
    else
      :
    fi

  done


  printf '}'
  printf '}'

}

list() {
  : ${HOSTNAME:-$(< /etc/hostname)}

  echo -en '{\n'

  _group ssh ${ssh_known_hosts_raw[*]}
  echo -en ','
  _group ${VIRT} localhost
  echo -en ','

  env -- json="${JSON_VARS[*]}" envsubst <<-'JSON_EOF'
"local": {
  "hosts": [
    "localhost"
  ],
  "vars": {
    ${json}
  }
},
"${ID}": {
  "hosts": [
    "${HOSTNAME}"
  ],
  "vars": {
    ${json}
  }
},
"_meta": {
  "hostvars": {
    "${HOSTNAME}": {
      ${json}
    },
    "localhost": {
      ${json}
    }
  }
}
JSON_EOF

  echo -en '\n}\n'

}

while [ -n "$*" ]; do
  case "$1" in
    (--list)
      list
      ;;

    (--host)
      shift
      host "$1"
      ;;

    (--)
      break
  esac
  shift
done
