#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="00660"
REPO_NAME="sealed-release-feed"
REPO_BRANCH="main"
MANIFEST_NAME="update_manifest.json"
MANIFEST_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/raw/refs/heads/${REPO_BRANCH}/${MANIFEST_NAME}"
DEFAULT_INSTALL_DIR="/opt/sealed-release"
DEFAULT_LICENSE_API_URL="https://hme.leohome.site:28443,http://58.87.90.225:28081/hme-license,https://hme-license-signer-dev.pages.dev"
DEFAULT_GITHUB_PROXY="https://gh-proxy.org"
DEFAULT_GITHUB_PROXY_URLS="https://gh-proxy.org,https://hk.gh-proxy.org,https://cdn.gh-proxy.org"

INSTALL_DIR="${APP_INSTALL_DIR:-${DEFAULT_INSTALL_DIR}}"
LICENSE_API_URL="${APP_LICENSE_API_URL:-${DEFAULT_LICENSE_API_URL}}"
WEB_PANEL_BIND_PORT="${APP_WEB_PORT:-}"
AUX8787_BIND_PORT="${APP_AUX8787_PORT:-}"
AUX8788_BIND_PORT="${APP_AUX8788_PORT:-}"
AUX8789_BIND_PORT="${APP_AUX8789_PORT:-}"
SKIP_DOCKER_INSTALL="${APP_SKIP_DOCKER_INSTALL:-0}"
GITHUB_PROXY="${APP_GITHUB_PROXY:-${DEFAULT_GITHUB_PROXY}}"
GITHUB_PROXY_URLS="${APP_GITHUB_PROXY_URLS:-${DEFAULT_GITHUB_PROXY_URLS}}"
MIHOMO_GITHUB_PROXY="${APP_MIHOMO_GITHUB_PROXY:-${GITHUB_PROXY}}"
MIHOMO_GITHUB_PROXY_URLS="${APP_MIHOMO_GITHUB_PROXY_URLS:-${GITHUB_PROXY_URLS}}"

TMP_DIR=""
BACKUP_DIR=""
PACKAGE_VERSION=""
PACKAGE_URL=""
PACKAGE_SHA256=""
PACKAGE_ROOT=""
MANIFEST_SOURCE_URL=""

usage() {
  cat <<'EOF'
Usage:
  install.sh [options]

Options:
  --install-dir DIR          Install to DIR. Default: /opt/sealed-release
  --license-api-url URLS     Override activation API URLs, comma-separated
  --github-proxy URL         Prefer one GitHub acceleration prefix
  --github-proxy-urls URLS   GitHub acceleration prefixes, comma-separated
  --mihomo-github-proxy URL  Prefer one Mihomo GitHub acceleration prefix
  --mihomo-github-proxy-urls URLS
                             Mihomo GitHub acceleration prefixes, comma-separated
  --web-port PORT            Override panel port
  --aux8787-port PORT        Override aux 8787 port
  --aux8788-port PORT        Override aux 8788 port
  --aux8789-port PORT        Override aux 8789 port
  --skip-docker-install      Do not auto-install Docker
  -h, --help                 Show this help

Examples:
  curl -fsSL https://github.com/00660/sealed-release-feed/raw/refs/heads/main/install.sh | sudo bash -s --

  curl -fsSL https://github.com/00660/sealed-release-feed/raw/refs/heads/main/install.sh | \
    sudo bash -s -- --web-port 8790

Environment overrides:
  APP_INSTALL_DIR
  APP_LICENSE_API_URL
  APP_GITHUB_PROXY
  APP_GITHUB_PROXY_URLS
  APP_MIHOMO_GITHUB_PROXY
  APP_MIHOMO_GITHUB_PROXY_URLS
  APP_WEB_PORT
  APP_AUX8787_PORT
  APP_AUX8788_PORT
  APP_AUX8789_PORT
  APP_SKIP_DOCKER_INSTALL=1
EOF
}

log() {
  printf '[release-install] %s\n' "$*"
}

fail() {
  printf '[release-install] ERROR: %s\n' "$*" >&2
  exit 1
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "please run as root, for example: curl -fsSL ... | sudo bash -s --"
  fi
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

cleanup() {
  if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
    rm -rf "${TMP_DIR}"
  fi
  if [ -n "${BACKUP_DIR}" ] && [ -d "${BACKUP_DIR}" ]; then
    rm -rf "${BACKUP_DIR}"
  fi
}

trap cleanup EXIT

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --install-dir)
        [ "$#" -ge 2 ] || fail "missing value for --install-dir"
        INSTALL_DIR="$2"
        shift 2
        ;;
      --license-api-url)
        [ "$#" -ge 2 ] || fail "missing value for --license-api-url"
        LICENSE_API_URL="$2"
        shift 2
        ;;
      --github-proxy)
        [ "$#" -ge 2 ] || fail "missing value for --github-proxy"
        GITHUB_PROXY="$2"
        shift 2
        ;;
      --github-proxy-urls)
        [ "$#" -ge 2 ] || fail "missing value for --github-proxy-urls"
        GITHUB_PROXY_URLS="$2"
        shift 2
        ;;
      --mihomo-github-proxy)
        [ "$#" -ge 2 ] || fail "missing value for --mihomo-github-proxy"
        MIHOMO_GITHUB_PROXY="$2"
        shift 2
        ;;
      --mihomo-github-proxy-urls)
        [ "$#" -ge 2 ] || fail "missing value for --mihomo-github-proxy-urls"
        MIHOMO_GITHUB_PROXY_URLS="$2"
        shift 2
        ;;
      --web-port)
        [ "$#" -ge 2 ] || fail "missing value for --web-port"
        WEB_PANEL_BIND_PORT="$2"
        shift 2
        ;;
      --aux8787-port)
        [ "$#" -ge 2 ] || fail "missing value for --aux8787-port"
        AUX8787_BIND_PORT="$2"
        shift 2
        ;;
      --aux8788-port)
        [ "$#" -ge 2 ] || fail "missing value for --aux8788-port"
        AUX8788_BIND_PORT="$2"
        shift 2
        ;;
      --aux8789-port)
        [ "$#" -ge 2 ] || fail "missing value for --aux8789-port"
        AUX8789_BIND_PORT="$2"
        shift 2
        ;;
      --skip-docker-install)
        SKIP_DOCKER_INSTALL="1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done
}

build_github_candidate_urls() {
  python3 - "$1" "${2:-}" "${3:-}" <<'PY'
import sys
from urllib.parse import urlparse

raw_url = str(sys.argv[1] or "").strip()
primary = str(sys.argv[2] or "").strip()
extra_raw = str(sys.argv[3] or "").strip()


def split_values(*values: str) -> list[str]:
    items: list[str] = []
    seen: set[str] = set()
    for raw in values:
        for chunk in str(raw or "").replace("\n", ",").split(","):
            value = chunk.strip()
            if not value:
                continue
            if value not in seen:
                seen.add(value)
                items.append(value)
    return items


def normalize_prefix(value: str) -> str:
    prefix = str(value or "").strip()
    if not prefix:
        return ""
    if "://" not in prefix:
        prefix = "https://" + prefix
    return prefix.rstrip("/")


def canonical_github_url(value: str) -> str:
    parsed = urlparse(value)
    host = (parsed.netloc or "").lower()
    if host == "raw.githubusercontent.com":
        parts = [item for item in parsed.path.split("/") if item]
        if len(parts) >= 4:
            owner, repo, branch = parts[:3]
            rest = "/".join(parts[3:])
            return f"https://github.com/{owner}/{repo}/raw/refs/heads/{branch}/{rest}"
    return value


def is_github_related(value: str) -> bool:
    host = (urlparse(value).netloc or "").lower()
    return (
        host == "github.com"
        or host == "raw.githubusercontent.com"
        or host == "release-assets.githubusercontent.com"
        or host == "objects.githubusercontent.com"
        or host.endswith(".githubusercontent.com")
    )


def proxied(prefix: str, value: str) -> str:
    normalized = normalize_prefix(prefix)
    return f"{normalized}/{value}" if normalized else value


canonical = canonical_github_url(raw_url)
urls: list[str] = []
seen: set[str] = set()


def add(value: str) -> None:
    candidate = str(value or "").strip()
    if not candidate or candidate in seen:
        return
    seen.add(candidate)
    urls.append(candidate)


github_related = is_github_related(canonical)
normalized_primary = normalize_prefix(primary)
normalized_extra = [normalize_prefix(item) for item in split_values(extra_raw)]
if github_related and normalized_primary:
    add(proxied(normalized_primary, canonical))
add(canonical)
if github_related:
    for prefix in normalized_extra:
        if prefix == normalized_primary:
            continue
        add(proxied(prefix, canonical))

for item in urls:
    print(item)
PY
}

download_with_candidates() {
  local target_path="$1"
  local source_url="$2"
  local label="$3"
  local candidate=""
  while IFS= read -r candidate; do
    [ -n "${candidate}" ] || continue
    log "${label}: ${candidate}"
    if curl -fL --connect-timeout 10 --retry 2 --retry-delay 1 "${candidate}" -o "${target_path}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done < <(build_github_candidate_urls "${source_url}" "${GITHUB_PROXY}" "${GITHUB_PROXY_URLS}")
  fail "${label} failed: ${source_url}"
}

detect_pkg_manager() {
  if have_cmd apt-get; then
    printf 'apt-get'
    return 0
  fi
  if have_cmd dnf; then
    printf 'dnf'
    return 0
  fi
  if have_cmd yum; then
    printf 'yum'
    return 0
  fi
  return 1
}

install_packages() {
  local manager
  manager="$(detect_pkg_manager)" || fail "unsupported system: cannot auto-install packages"
  case "${manager}" in
    apt-get)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
  esac
}

ensure_base_tools() {
  local missing=()
  have_cmd python3 || missing+=("python3")
  have_cmd unzip || missing+=("unzip")
  if [ "${#missing[@]}" -gt 0 ]; then
    log "installing missing packages: ${missing[*]}"
    install_packages "${missing[@]}"
  fi
}

ensure_docker() {
  if have_cmd docker && docker compose version >/dev/null 2>&1; then
    return 0
  fi
  if [ "${SKIP_DOCKER_INSTALL}" = "1" ]; then
    fail "docker or docker compose is missing and auto-install is disabled"
  fi
  log "installing Docker"
  curl -fsSL https://get.docker.com | sh
  if have_cmd systemctl; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  fi
  have_cmd docker || fail "docker install failed"
  docker compose version >/dev/null 2>&1 || fail "docker compose plugin is missing after install"
}

prepare_dirs() {
    TMP_DIR="$(mktemp -d -t release-install-XXXXXX)"
    BACKUP_DIR="$(mktemp -d -t release-backup-XXXXXX)"
}

load_manifest() {
  log "downloading manifest: ${MANIFEST_URL}"
  MANIFEST_SOURCE_URL="$(download_with_candidates "${TMP_DIR}/manifest.json" "${MANIFEST_URL}" "download manifest")"
  mapfile -t manifest_lines < <(python3 - "${TMP_DIR}/manifest.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(str(payload.get("version") or "").strip())
print(str(payload.get("package_url") or "").strip())
print(str(payload.get("sha256") or "").strip())
PY
)
  PACKAGE_VERSION="${manifest_lines[0]:-}"
  PACKAGE_URL="${manifest_lines[1]:-}"
  PACKAGE_SHA256="${manifest_lines[2]:-}"
  [ -n "${PACKAGE_URL}" ] || fail "package_url is missing in manifest"
  [ -n "${PACKAGE_VERSION}" ] || fail "version is missing in manifest"
}

download_package() {
  log "downloading release ${PACKAGE_VERSION}"
  download_with_candidates "${TMP_DIR}/package.zip" "${PACKAGE_URL}" "download package" >/dev/null
  if [ -n "${PACKAGE_SHA256}" ]; then
    local actual_sha
    actual_sha="$(sha256sum "${TMP_DIR}/package.zip" | awk '{print $1}')"
    [ "${actual_sha}" = "${PACKAGE_SHA256}" ] || fail "sha256 mismatch: expected ${PACKAGE_SHA256}, got ${actual_sha}"
  fi
}

extract_package() {
  rm -rf "${TMP_DIR}/extract"
  mkdir -p "${TMP_DIR}/extract"
  python3 - "${TMP_DIR}/package.zip" "${TMP_DIR}/extract" <<'PY'
import sys
import zipfile
from pathlib import Path

zip_path = Path(sys.argv[1])
extract_dir = Path(sys.argv[2])

with zipfile.ZipFile(zip_path) as archive:
    archive.extractall(extract_dir)
PY
  PACKAGE_ROOT=""
  while IFS= read -r -d '' compose_file; do
    local candidate_root
    candidate_root="$(dirname "${compose_file}")"
    if [ -e "${candidate_root}/web_panel" ] && [ -f "${candidate_root}/Dockerfile" ]; then
      PACKAGE_ROOT="${candidate_root}"
      break
    fi
  done < <(find "${TMP_DIR}/extract" -type f -name 'docker-compose.yml' -print0 2>/dev/null)
  [ -n "${PACKAGE_ROOT}" ] || fail "unable to find extracted package root"
  [ -f "${PACKAGE_ROOT}/docker-compose.yml" ] || fail "docker-compose.yml not found in extracted package"
}

backup_existing_install() {
  if [ -d "${INSTALL_DIR}/runtime" ]; then
    mkdir -p "${BACKUP_DIR}/runtime"
    cp -a "${INSTALL_DIR}/runtime/." "${BACKUP_DIR}/runtime/"
  fi
  if [ -f "${INSTALL_DIR}/.env" ]; then
    cp -a "${INSTALL_DIR}/.env" "${BACKUP_DIR}/.env"
  fi
}

install_files() {
  rm -rf "${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}"
  cp -a "${PACKAGE_ROOT}/." "${INSTALL_DIR}/"
  if [ -d "${BACKUP_DIR}/runtime" ]; then
    mkdir -p "${INSTALL_DIR}/runtime"
    cp -a "${BACKUP_DIR}/runtime/." "${INSTALL_DIR}/runtime/"
  fi
  if [ -f "${BACKUP_DIR}/.env" ]; then
    cp -a "${BACKUP_DIR}/.env" "${INSTALL_DIR}/.env"
  fi
  mkdir -p "${INSTALL_DIR}/runtime/panel_runtime" "${INSTALL_DIR}/runtime/account" "${INSTALL_DIR}/runtime/icloud_sessions"
  [ -f "${INSTALL_DIR}/.env" ] || : > "${INSTALL_DIR}/.env"
}

upsert_env() {
  local key="$1"
  local value="$2"
  python3 - "${INSTALL_DIR}/.env" "${key}" "${value}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
prefix = key + "="
output = []
replaced = False
for line in lines:
    if line.startswith(prefix):
        output.append(prefix + value)
        replaced = True
    else:
        output.append(line)
if not replaced:
    output.append(prefix + value)
path.write_text("\n".join(output).rstrip() + "\n", encoding="utf-8")
PY
}

write_install_env() {
  local internal_license_key
  internal_license_key="$(python3 - <<'PY'
print("".join(chr(value) for value in (72, 77, 69, 95, 76, 73, 67, 69, 78, 83, 69, 95, 65, 80, 73, 95, 85, 82, 76)))
PY
)"
  if [ -n "${LICENSE_API_URL}" ]; then
    upsert_env "${internal_license_key}" "${LICENSE_API_URL}"
  fi
  if [ -n "${GITHUB_PROXY}" ]; then
    upsert_env "HME_GITHUB_PROXY" "${GITHUB_PROXY}"
  fi
  if [ -n "${GITHUB_PROXY_URLS}" ]; then
    upsert_env "HME_GITHUB_PROXY_URLS" "${GITHUB_PROXY_URLS}"
  fi
  if [ -n "${MIHOMO_GITHUB_PROXY}" ]; then
    upsert_env "HME_MIHOMO_GITHUB_PROXY" "${MIHOMO_GITHUB_PROXY}"
  fi
  if [ -n "${MIHOMO_GITHUB_PROXY_URLS}" ]; then
    upsert_env "HME_MIHOMO_GITHUB_PROXY_URLS" "${MIHOMO_GITHUB_PROXY_URLS}"
  fi
  if [ -n "${WEB_PANEL_BIND_PORT}" ]; then
    upsert_env "WEB_PANEL_BIND_PORT" "${WEB_PANEL_BIND_PORT}"
  fi
  if [ -n "${AUX8787_BIND_PORT}" ]; then
    upsert_env "AUX8787_BIND_PORT" "${AUX8787_BIND_PORT}"
  fi
  if [ -n "${AUX8788_BIND_PORT}" ]; then
    upsert_env "AUX8788_BIND_PORT" "${AUX8788_BIND_PORT}"
  fi
  if [ -n "${AUX8789_BIND_PORT}" ]; then
    upsert_env "AUX8789_BIND_PORT" "${AUX8789_BIND_PORT}"
  fi
}

read_effective_env() {
  local key="$1"
  local fallback="$2"
  python3 - "${INSTALL_DIR}/.env" "${key}" "${fallback}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
fallback = sys.argv[3]
value = fallback
if path.exists():
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith(key + "="):
            current = line.split("=", 1)[1].strip()
            value = current or fallback
            break
print(value)
PY
}

deploy_stack() {
  log "starting docker compose"
  (
    cd "${INSTALL_DIR}"
    docker compose up -d --build
  )
}

print_summary() {
  local host_ip web_port
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "${host_ip}" ] || host_ip="SERVER_IP"
  web_port="$(read_effective_env WEB_PANEL_BIND_PORT 8790)"
  log "install completed"
  log "version: ${PACKAGE_VERSION}"
  log "install dir: ${INSTALL_DIR}"
  if [ -n "${GITHUB_PROXY}" ]; then
    log "github proxy: ${GITHUB_PROXY}"
  elif [ -n "${GITHUB_PROXY_URLS}" ]; then
    log "github proxy fallbacks: ${GITHUB_PROXY_URLS}"
  fi
  log "panel url: http://${host_ip}:${web_port}/"
}

main() {
  parse_args "$@"
  need_root
  prepare_dirs
  ensure_base_tools
  ensure_docker
  load_manifest
  download_package
  extract_package
  backup_existing_install
  install_files
  write_install_env
  deploy_stack
  print_summary
}

main "$@"
