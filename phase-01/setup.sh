#!/bin/bash

# Stop execution if script fails since bash continues executing even if a command fails by default.
# -e exits immediately if a command exits with a non-zero status.
# -u treats unset variables as an error and exits immediately.
# -o pipefail causes a pipeline to return the exit status of the first command that fails.
set -euo pipefail

# If the effective user ID (EUID) is not 0 (root), exit.
if [[ $EUID -ne 0 ]]; then
  echo "[CMPS4232 Project] [ERROR] $0 must be run as root or via sudo." >&2
  exit 1
fi

DIR=/srv
SHELL=/bin/bash

# Create secondary groups.
groupadd sysadmins
groupadd developers
groupadd auditors

# Provision user accounts and assign primary and secondary groups.
# --gid or -g specifies the primary group for the user.
# --groups or -G specifies the secondary groups for the user.
useradd --create-home --shell $SHELL --gid sysadmins --groups developers,auditors matt
useradd --create-home --shell $SHELL --gid developers alice
useradd --create-home --shell $SHELL --gid auditors --groups developers ben

# Create shared directories for each group.
mkdir --parents $DIR/sysadmins
mkdir --parents $DIR/developers
mkdir --parents $DIR/auditors

# Apply directory ownership and file permission bits.
# 760 maps to rwx-rw----, giving group members read and write access.
# Unauthorized users are completed restricted.
chown root:sysadmins $DIR/sysadmins
chmod 760 $DIR/sysadmins
chown root:developers $DIR/developers
chmod 760 $DIR/developers
chown root:auditors $DIR/auditors
chmod 760 $DIR/auditors
