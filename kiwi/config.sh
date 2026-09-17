#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# Kiwi post-install configuration script.
# Runs inside the image chroot after all packages are installed.
# Equivalent to mkosi's Hostname=, RootPassword=, Timezone=, Locale= settings.

set -euo pipefail

# ── Hostname ──────────────────────────────────────────────────────────────────
echo "centos" > /etc/hostname

# ── Timezone ──────────────────────────────────────────────────────────────────
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "UTC" > /etc/timezone

# ── Locale ────────────────────────────────────────────────────────────────────
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# ── Default user ──────────────────────────────────────────────────────────────
groups=wheel,audio,video,render,users
getent group fastrpc > /dev/null && groups="${groups},fastrpc"
useradd --create-home --shell /bin/bash --user-group \
    --groups "$groups" qcom
echo "qcom:qcom" | chpasswd

# Force password change on first login
chage --lastday 0 qcom

mkdir -p /etc/sudoers.d
echo "qcom ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-qcom
chmod 440 /etc/sudoers.d/90-qcom

# The kiwi overlay tree (kiwi/root/) is copied into the image with the perms it
# had in the checkout. git does not track directory modes, so directories are
# created at clone time using the operator's umask: a restrictive umask (e.g.
# 027) yields these as drwxr-x---, breaking directory traversal for unprivileged
# daemons.
for d in /usr /usr/lib /usr/lib/repart.d; do
    [ -d "$d" ] && chmod 0755 "$d"
done

# ── Services ──────────────────────────────────────────────────────────────────
systemctl enable sshd.service        || true
systemctl enable NetworkManager.service || true
