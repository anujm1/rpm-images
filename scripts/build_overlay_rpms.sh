#!/usr/bin/env bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# Build "overlay" RPMs: packages that come from CentOS Stream but carry a
# local diff against the CentOS spec file.
#
# For each overlay under $OVERLAY_DIR/<pkg>/ this script:
#   1. fetches the pristine CentOS source RPM (SRPM),
#   2. explodes it so the spec + all SourceN/PatchN files sit together,
#   3. applies the overlay's spec.patch (and drops in any extra sources/),
#   4. rebuilds the binary RPM in the qcom-rpm-utils rpm-builder container
#      via that project's scripts/build-rpm.sh, and
#   5. copies the resulting binary RPM(s) into $PACKAGES_DIR (default
#      packages/), where 'make image' already picks them up as a
#      priority-1 local repo.
#
# It is a clean no-op when $OVERLAY_DIR has no package directories, so it is
# safe to wire unconditionally into 'make image'.
#
# Usage: build_overlay_rpms.sh [--overlay-dir DIR] [--packages-dir DIR]
#                              [--work-dir DIR] [--builder-image REF]
#                              [--only PKG] [--keep-debuginfo]

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OVERLAY_DIR="${OVERLAY_DIR:-${REPO_ROOT}/overlay}"
PACKAGES_DIR="${PACKAGES_DIR:-${REPO_ROOT}/packages}"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/build/overlay}"
RPM_BUILDER_IMAGE="${RPM_BUILDER_IMAGE:-ghcr.io/qualcomm-linux/rpm-builder:centos10}"

# qcom-rpm-utils provides the rpm-builder container + build-rpm.sh wrapper.
RPM_UTILS_REPO="${RPM_UTILS_REPO:-https://github.com/qualcomm-linux/qcom-rpm-utils}"
RPM_UTILS_REF="${RPM_UTILS_REF:-main}"

ONLY_PKG=""
KEEP_DEBUGINFO=0

log_i() { echo "I: $*" >&2; }
log_w() { echo "W: $*" >&2; }
fatal() { echo "F: $*" >&2; exit 1; }

usage() {
  sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# ── Argument parsing ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --overlay-dir)     OVERLAY_DIR="$2"; shift 2 ;;
    --packages-dir)    PACKAGES_DIR="$2"; shift 2 ;;
    --work-dir)        WORK_DIR="$2"; shift 2 ;;
    --builder-image)   RPM_BUILDER_IMAGE="$2"; shift 2 ;;
    --only)            ONLY_PKG="$2"; shift 2 ;;
    --keep-debuginfo)  KEEP_DEBUGINFO=1; shift ;;
    -h|--help)         usage 0 ;;
    *) fatal "Unknown argument: $1 (see --help)" ;;
  esac
done

# ── Container runtime ─────────────────────────────────────────────────────
# build-rpm.sh itself shells out to `docker`, so we require docker in PATH.
CONTAINER_ENGINE="docker"
if ! command -v docker >/dev/null 2>&1; then
  if command -v podman >/dev/null 2>&1; then
    fatal "docker not found. qcom-rpm-utils build-rpm.sh requires docker; \
podman is installed but not supported by that wrapper. Install docker \
(or a docker-compatible shim) to build overlays."
  fi
  fatal "docker not found in PATH; required to build overlay RPMs."
fi

# ── Discover overlays ─────────────────────────────────────────────────────
if [[ ! -d "${OVERLAY_DIR}" ]]; then
  log_i "No overlay directory (${OVERLAY_DIR}); nothing to build."
  exit 0
fi

shopt -s nullglob
overlays=()
for d in "${OVERLAY_DIR}"/*/; do
  pkg="$(basename "${d}")"
  [[ -n "${ONLY_PKG}" && "${pkg}" != "${ONLY_PKG}" ]] && continue
  # A valid overlay dir has an overlay.conf.
  [[ -f "${d}/overlay.conf" ]] && overlays+=("${d%/}")
done
shopt -u nullglob

if [[ ${#overlays[@]} -eq 0 ]]; then
  log_i "No overlays found under ${OVERLAY_DIR}; nothing to build."
  exit 0
fi

mkdir -p "${PACKAGES_DIR}" "${WORK_DIR}"

# ── Fetch qcom-rpm-utils (build-rpm.sh + build-in-container.sh) ────────────
RPM_UTILS_DIR="${WORK_DIR}/qcom-rpm-utils"
if [[ -d "${RPM_UTILS_DIR}/.git" ]]; then
  log_i "Reusing qcom-rpm-utils checkout: ${RPM_UTILS_DIR}"
else
  log_i "Cloning qcom-rpm-utils (${RPM_UTILS_REF}) into ${RPM_UTILS_DIR}"
  git clone --depth=1 --branch "${RPM_UTILS_REF}" \
    "${RPM_UTILS_REPO}" "${RPM_UTILS_DIR}"
fi
BUILD_RPM_SH="${RPM_UTILS_DIR}/scripts/build-rpm.sh"
[[ -x "${BUILD_RPM_SH}" || -f "${BUILD_RPM_SH}" ]] \
  || fatal "build-rpm.sh not found in qcom-rpm-utils: ${BUILD_RPM_SH}"

# ── Fetch a pristine SRPM using the rpm-builder container ──────────────────
# The x86_64 dev host lacks CentOS source repos and the dnf download plugin;
# the rpm-builder container has dnf + the CentOS repos, so run the fetch there.
# Prints the path (inside dest_dir on the host) of the downloaded .src.rpm.
fetch_srpm() {
  local srpm_spec="$1" dest_dir="$2"
  mkdir -p "${dest_dir}"
  log_i "Fetching SRPM '${srpm_spec}' via ${RPM_BUILDER_IMAGE}"
  "${CONTAINER_ENGINE}" run --rm \
    -v "${dest_dir}:/srpmout" \
    -e SRPM_SPEC="${srpm_spec}" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    "${RPM_BUILDER_IMAGE}" \
    bash -c '
      set -euo pipefail
      dnf install -y dnf-command\(download\) dnf-plugins-core >/dev/null 2>&1 || true
      # Enable source repos where available (CentOS Stream ships *-source).
      dnf config-manager --set-enabled "*-source" >/dev/null 2>&1 || true
      cd /srpmout
      dnf download --source "${SRPM_SPEC}"
      [[ -n "${HOST_UID:-}" && -n "${HOST_GID:-}" ]] && \
        chown -R "${HOST_UID}:${HOST_GID}" /srpmout || true
    '
  local found
  found="$(find "${dest_dir}" -maxdepth 1 -name '*.src.rpm' | head -1)"
  [[ -n "${found}" ]] || fatal "SRPM download produced no .src.rpm for '${srpm_spec}'"
  echo "${found}"
}

# ── Build one overlay ─────────────────────────────────────────────────────
build_overlay() {
  local overlay_path="$1"
  local pkg; pkg="$(basename "${overlay_path}")"

  log_i "=============================================================="
  log_i "Overlay: ${pkg}"

  # Load overlay.conf (SRPM, SRPM_NVR, SRPM_URL, EXTRA_REPO, MACROS).
  local SRPM="" SRPM_NVR="" SRPM_URL="" EXTRA_REPO="" MACROS=""
  # shellcheck disable=SC1091
  source "${overlay_path}/overlay.conf"

  [[ -f "${overlay_path}/spec.patch" ]] \
    || fatal "${pkg}: missing spec.patch"

  local pkg_work="${WORK_DIR}/${pkg}"
  rm -rf "${pkg_work}"
  mkdir -p "${pkg_work}/srpm" "${pkg_work}/explode" "${pkg_work}/output"

  # 1. Obtain the pristine SRPM.
  local srpm_file
  if [[ -n "${SRPM_URL}" ]]; then
    log_i "${pkg}: downloading SRPM from ${SRPM_URL}"
    srpm_file="${pkg_work}/srpm/$(basename "${SRPM_URL}")"
    curl -fSL "${SRPM_URL}" -o "${srpm_file}"
  else
    local srpm_spec="${SRPM_NVR:-${SRPM}}"
    [[ -n "${srpm_spec}" ]] \
      || fatal "${pkg}: overlay.conf must set SRPM (or SRPM_NVR / SRPM_URL)"
    srpm_file="$(fetch_srpm "${srpm_spec}" "${pkg_work}/srpm")"
  fi
  log_i "${pkg}: SRPM = $(basename "${srpm_file}")"

  # 2. Explode the SRPM flat: spec + every SourceN/PatchN in one directory.
  #    build-rpm.sh sweeps every regular file next to the spec, so a flat
  #    layout is exactly what it expects.
  ( cd "${pkg_work}/explode" && rpm2cpio "${srpm_file}" | cpio -idmv ) \
    >/dev/null 2>&1 || fatal "${pkg}: failed to explode SRPM"

  local spec_file
  spec_file="$(find "${pkg_work}/explode" -maxdepth 1 -name '*.spec' | head -1)"
  [[ -n "${spec_file}" ]] || fatal "${pkg}: no .spec found in SRPM"

  # 3. Apply the overlay diff to the spec; drop in any extra sources.
  log_i "${pkg}: applying spec.patch to $(basename "${spec_file}")"
  if ! patch -p1 -d "${pkg_work}/explode" < "${overlay_path}/spec.patch"; then
    fatal "${pkg}: spec.patch did not apply cleanly. CentOS likely moved the \
package; refresh spec.patch against the current SRPM ($(basename "${srpm_file}"))."
  fi
  if [[ -d "${overlay_path}/sources" ]]; then
    log_i "${pkg}: adding extra sources from overlay sources/"
    cp -a "${overlay_path}/sources/." "${pkg_work}/explode/"
  fi

  # Re-resolve spec (patch may have bumped version/renamed sources).
  spec_file="$(find "${pkg_work}/explode" -maxdepth 1 -name '*.spec' | head -1)"

  # 4. Identify the primary Source0 tarball (build-rpm.sh needs --tarball).
  local tarball
  tarball="$(rpmspec -P "${spec_file}" 2>/dev/null \
    | awk '/^Source0?:/ {print $2; exit}')"
  tarball="$(basename "${tarball:-}")"
  local tarball_path=""
  if [[ -n "${tarball}" && -f "${pkg_work}/explode/${tarball}" ]]; then
    tarball_path="${pkg_work}/explode/${tarball}"
  else
    # Fall back to the first archive-looking Source in the explode dir.
    tarball_path="$(find "${pkg_work}/explode" -maxdepth 1 -type f \
      \( -name '*.tar.*' -o -name '*.tgz' -o -name '*.zip' \) | head -1)"
  fi
  [[ -n "${tarball_path}" && -f "${tarball_path}" ]] \
    || fatal "${pkg}: could not locate the primary source tarball for build-rpm.sh"
  log_i "${pkg}: primary tarball = $(basename "${tarball_path}")"

  # 5. Rebuild via qcom-rpm-utils build-rpm.sh (runs in the container).
  local -a build_args=(
    --tarball "${tarball_path}"
    --spec    "${spec_file}"
    --output  "${pkg_work}/output"
    --builder-image "${RPM_BUILDER_IMAGE}"
  )
  [[ -n "${EXTRA_REPO}" ]] && build_args+=(--extra-repo "${EXTRA_REPO}")
  [[ -n "${MACROS}" ]]     && build_args+=(--macros "${MACROS}")

  log_i "${pkg}: building via qcom-rpm-utils build-rpm.sh"
  bash "${BUILD_RPM_SH}" "${build_args[@]}"

  # 6. Stage the resulting binary RPM(s) into packages/.
  local staged=0
  while IFS= read -r rpm; do
    local base; base="$(basename "${rpm}")"
    case "${base}" in
      *.src.rpm) continue ;;
    esac
    if [[ "${KEEP_DEBUGINFO}" -ne 1 ]]; then
      case "${base}" in
        *-debuginfo-*|*-debugsource-*) continue ;;
      esac
    fi
    cp -f "${rpm}" "${PACKAGES_DIR}/"
    log_i "${pkg}: staged ${base} -> ${PACKAGES_DIR}/"
    staged=$((staged + 1))
  done < <(find "${pkg_work}/output" -type f -name '*.rpm')

  [[ "${staged}" -gt 0 ]] \
    || fatal "${pkg}: build produced no binary RPMs to stage"
}

# ── Main ──────────────────────────────────────────────────────────────────
log_i "Overlays to build: ${#overlays[@]}"
for overlay_path in "${overlays[@]}"; do
  build_overlay "${overlay_path}"
done
log_i "All overlays built and staged into ${PACKAGES_DIR}/"
