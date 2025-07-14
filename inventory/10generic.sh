#!/bin/bash
set -o allexport ${DEBUG:+-s xtrace}
source /etc/os-release

dir=/dev/shm/"$(date -I)"
mkdir -p "$dir" &>/dev/null

pushd "$dir" &>/dev/null || exit
exec 3<> /dev/tty
SCRIPT="${OLDPWD}"/"${0}"
BASH_XTRACEFD=3
PS4=$'\b${BASH_SOURCE[0]##*/}:${FUNCNAME:+${FUNCNAME[0]}:}rc=${?}:$(tput setaf 230)$(printf "%0*d" 3 ${LINENO})$(tput sgr0): '
LC_ALL=C
NO_COLOR=1

if [ -n "$INSIDE_EMACS" -a -z "$@" ]; then
  set - --list
  #TRACE=true
fi

: ${HOSTNAME:-$(< /etc/hostname)}
PULL_URL="$(git -C $OLDPWD remote get-url origin)"
PULL_BRANCH="$(git -C $OLDPWD rev-parse --abbrev-ref HEAD)"
DISTRO="$ID"
DISTRO_VERSION="$VERSION_ID"
uid=$(id -u)
gid==$(id -g)}

if systemd-detect-virt --container --quiet; then
  VIRT=containers
elif systemd-detect-virt --vm --quiet; then
  VIRT=vms
else
  VIRT=physical
fi

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

mapfile ssh_pubkeys  < <(
  cat "$HOME"/.ssh/id_*.pub
)


print-ssh-keys() {
  cat ~/.ssh/*.pub |
    xargs --no-run-if-empty -d \\n printf '"%s",' |
    head -c -1 |
    sed -Ez 's#.*#[&]#' |
    sed -Ez 's# "#"#g'
}

mapfile JSON_VARS <<-JSON_VARS_EOF
"ansible_user_id": "${USER}",
"ansible_user_dir": "${HOME}",
"pull_url": "${PULL_URL}",
"pull_branch": "${PULL_BRANCH}",
"install_packages": ["jq"],
"ssh_keys": $(print-ssh-keys)
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
  "${DISTRO}${DISTRO_VERSION}": {
    "hosts": [ "${HOSTNAME}" ],
    "vars": { ${JSON_VARS[*]}  }
  },
  "${DISTRO}": {
    "hosts": [ "${HOSTNAME}" ],
    "vars": { ${JSON_VARS[*]}  }
  },
  "${VIRT}": {
    "hosts": [ "${HOSTNAME}" ],
    "vars": { ${JSON_VARS[*]}  }
  },
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
cat<<HOST_LONGOPTION_EOF
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
