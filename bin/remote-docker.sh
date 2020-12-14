#!/usr/bin/env bash
set -e
BASEDIR=$(dirname "$0")
cd "$BASEDIR/.." || exit 1

ENV_NAME=${1}
JUMPHOST=${2}
TARGET_SERVER=${3}

if [ -z "$ENV_NAME" ]; then
  echo "Usage: $0 <ENV_NAME> [JUMPHOST] <TARGET_SERVER>"
  exit 0
fi
if [ -z "$TARGET_SERVER" ]; then
  TARGET_SERVER=$JUMPHOST
  JUMPHOST=""
  shift 2
else
  shift 3
fi

# common shared ssh options
SSH_OPTIONS="-o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -A"

# create a tmp dir to put our sockets in
TMP_DIR=$(mktemp -d -t remote-docker-XXXXXXXXXX)

SHARED_CONNECTION_SOCK="${TMP_DIR}/$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1).sock"
LOCAL_DOCKER_SOCK="${TMP_DIR}/$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1).sock"
REMOTE_DOCKER_SOCK=${REMOTE_DOCKER_SOCK:-"/var/run/docker.sock"}

# trap the exit of this script to perform some cleanup
function cleanup {
  echo "Closing tunnel to remote host & cleaning up docker socket"
  # close shared connection
  ssh -S "${SHARED_CONNECTION_SOCK}" -q -o LogLevel=ERROR -O exit "${TARGET_HOST}" > /dev/null
  # delete old sockets
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [ -z "$SKIP_DOCKER_CMD_PROTECTION" ]; then
  # create a function for our docker alias which we later inject into the new bash's .bashrc file
  # ensure to create visibility that docker commands are not run locally in case its overlooked
  read -r -d '' PROTECT_UNEXPECTED_DOCKER_COMMANDS << EOF || true
function request_confirmation {
  RED=\$(tput setaf 1)
  BLUE=\$(tput setaf 4)
  BOLD=\$(tput bold)
  RESET=\$(tput sgr0)
  echo -e "\${RED}\${BOLD}ATTENTION!\${RESET}"
  echo -n -e "you are about to run the following command in \${BOLD}\${RED}\"$ENV_NAME\"\${RESET}: "\${BOLD}\${BLUE}\$*\${RESET}"? [N/y] "
  read -N 1 REPLY
  echo
  if test "\$REPLY" = "y" -o "\$REPLY" = "Y"; then
      "\$@"
  else
      echo "Cancelled by user"
  fi
}
alias docker="request_confirmation docker"
EOF
fi

# in case of a jumphost we need to properly define the proxycommand
if [ -n "$JUMPHOST" ]; then
  echo "Creating connection to docker host on: \"$TARGET_SERVER\" through jumphost: \"$JUMPHOST\""
  JUMPHOST_PROXY='ssh -A '${SSH_OPTIONS}' '$JUMPHOST' -W %h:%p'
  # shellcheck disable=SC2086
  ssh ${SSH_OPTIONS} -o ProxyCommand="${JUMPHOST_PROXY}" -f -N -M -S "${SHARED_CONNECTION_SOCK}" -L "${LOCAL_DOCKER_SOCK}:${REMOTE_DOCKER_SOCK}" ${TARGET_SERVER}
else
  echo "Creating connection to docker host on: \"$TARGET_SERVER\""
  # shellcheck disable=SC2086
  ssh ${SSH_OPTIONS} -f -N -M -S "${SHARED_CONNECTION_SOCK}" -L "${LOCAL_DOCKER_SOCK}:${REMOTE_DOCKER_SOCK}" ${TARGET_SERVER}
fi

export DOCKER_HOST="unix://$LOCAL_DOCKER_SOCK"
echo "Using docker host ${DOCKER_HOST}"
CMD=$*

if [ -z "$CMD" ]; then
  export ENV_NAME
  LOCAL_PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]\[$(tput bold)\]\[\033[38;5;1m\]['"$ENV_NAME"']\[$(tput sgr0)\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

  bash --rcfile <(cat ~/.bashrc; echo "PS1=\"$LOCAL_PS1\""; echo "${PROTECT_UNEXPECTED_DOCKER_COMMANDS}")
else
  # shellcheck disable=SC2068
  bash --rcfile <(cat ~/.bashrc; echo "PS1=\"$LOCAL_PS1\"") -c "$CMD"
fi
