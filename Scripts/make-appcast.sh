#!/bin/bash
# 生成/更新 docs/appcast.json —— 桌面更新的静态 feed。
#
# 为什么存在：桌面更新检查与安装原本要问 api.github.com，而未认证 API 每小时
# 只给 60 次、按出口 IP 共享，配额耗尽时更新直接失败（GitHub #225）。这个 feed
# 走 raw.githubusercontent.com 的 CDN，不占配额，一个请求就带齐版本号与下载直链。
#
# 用法：
#   Scripts/make-appcast.sh --tag v0.1.0-alpha.N --zip-name NAME --zip-url URL \
#       --sha256 HEX [--notes-url URL] [--published-at ISO8601] [--file docs/appcast.json]
#
# 版本号由 tag 去掉前缀 v 得到（与 docs/releasing.md 的 tag 规则一致：tag 必须是
# v<MARKETING_VERSION>），因此不接受单独的版本参数——多一个输入就多一处不一致。
#
# 只保留最近 --keep 条（默认 10）：feed 是“有哪些可装版本”的索引，不是发布历史。

set -euo pipefail

cd "$(dirname "$0")/.."

tag=""
zip_name=""
zip_url=""
sha256=""
notes_url=""
published_at=""
file="docs/appcast.json"
keep=10

die() { echo "make-appcast: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) tag="${2:-}"; shift 2 ;;
    --zip-name) zip_name="${2:-}"; shift 2 ;;
    --zip-url) zip_url="${2:-}"; shift 2 ;;
    --sha256) sha256="${2:-}"; shift 2 ;;
    --notes-url) notes_url="${2:-}"; shift 2 ;;
    --published-at) published_at="${2:-}"; shift 2 ;;
    --file) file="${2:-}"; shift 2 ;;
    --keep) keep="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"

# tag 是唯一的版本来源：v<版本>，且版本必须能被语义化版本解析。
case "$tag" in
  v*) ;;
  *) die "tag must look like v<version>, got '${tag}'" ;;
esac
version="${tag#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] \
  || die "tag '${tag}' does not carry a semantic version"
[ -n "$zip_name" ] || die "--zip-name is required"
[ -n "$zip_url" ] || die "--zip-url is required"
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || die "--sha256 must be 64 lowercase hex characters"
# 下载地址必须钉在发布资产路径上：feed 的内容不能把更新引到别处。
[[ "$zip_url" == "https://github.com/"*"/releases/download/"*"/${zip_name}" ]] \
  || die "--zip-url must be https://github.com/<owner>/<repo>/releases/download/<tag>/<zip>"
[ -n "$published_at" ] || published_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

existing='{"schema":1,"releases":[]}'
if [ -f "$file" ]; then
  existing="$(cat "$file")"
  jq -e '.schema == 1 and (.releases | type == "array")' <<<"$existing" >/dev/null \
    || die "${file} is not a schema 1 feed"
fi

entry="$(jq -n \
  --arg tag "$tag" \
  --arg version "$version" \
  --arg name "$zip_name" \
  --arg url "$zip_url" \
  --arg sha256 "$sha256" \
  --arg notes "$notes_url" \
  --arg publishedAt "$published_at" \
  '{
    tag: $tag,
    version: $version,
    publishedAt: $publishedAt,
    zip: { name: $name, url: $url, sha256: $sha256 }
  } + (if $notes == "" then {} else { notes: $notes } end)')"

mkdir -p "$(dirname "$file")"
jq -n --argjson old "$existing" --argjson new "$entry" --argjson keep "$keep" \
  '{schema: 1, releases: (([$new] + ($old.releases | map(select(.tag != $new.tag))))[:$keep])}' \
  > "${file}.tmp"
mv "${file}.tmp" "$file"

echo "make-appcast: wrote ${file} (${tag})"
