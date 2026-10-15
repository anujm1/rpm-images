#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# KIWI repository customize hook.
# Adds the repository metadata signing key to repositories using repo_gpgcheck.

set -euo pipefail

repo_file="$1"

# Skip repositories that do not require metadata signature verification.
grep -q '^repo_gpgcheck *= *1' "$repo_file" || exit 0

# Preserve an existing gpgkey configuration.
grep -q '^gpgkey=' "$repo_file" && exit 0

if [[ "$repo_file" == */etc/yum.repos.d/*.repo ]]; then
    # Runtime repository uses the key installed in the image.
    gpgkey="file:///etc/pki/rpm-gpg/qsc-rpm-public-key"
else
    # Build-time repositories require the key in KIWI's shared DNF cache.
    script_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
    key_src="$script_dir/root/etc/pki/rpm-gpg/qsc-rpm-public-key"
    key_dst="$(dirname "$(dirname "$repo_file")")/qsc-rpm-public-key"

    cp -f "$key_src" "$key_dst"
    gpgkey="file://$key_dst"
fi

printf 'gpgkey=%s\n' "$gpgkey" >> "$repo_file"
