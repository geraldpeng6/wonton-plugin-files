# Files：Bot 的只读文件搜索服务。sso=none 且清单没有 webui（网页和身份两项 N/A）；MCP 有 4 个只读工具。
# shellcheck shell=bash disable=SC2034
# 镜像没发布时在本机构建（README 的做法）。
# 数据：服务 read_only、六个共享文件夹全只读挂载（docker-compose.yml），自己不存用户数据。
export DATA_NA=1
export SMOKE_NOTE="只读文件搜索 MCP：共享文件夹只读挂载、根文件系统只读，服务没有可写读回的用户数据"

# 本机没有清单里那个摘要时按 README 构建，再把清单里的引用换成构建出来的（只改冒烟的副本）。
before_install() {
  local ref dig proxy="${https_proxy:-${HTTPS_PROXY:-}}" args=()
  ref="$(awk '/^ *image: /{print $2}' "$SMOKE_DIR/docker-compose.yml" | grep 'wonton-files:' | head -1)"
  [[ -n "$ref" ]] || { echo "清单里没有 wonton-files 镜像"; return 1; }
  if [[ -z "${SMOKE_BUILD:-}" ]] && docker manifest inspect "$ref" >/dev/null 2>&1; then
    # 镜像已发布（ghcr）：交给 install 直接拉。只查本地 image inspect 会在干净 runner 上
    # 误判成「没发布」，本地构建出来的 dev 摘要 install 又拉不到（2026-11-08 CI 实测）。
    echo "清单镜像已在发布仓：$ref，不本地构建"
    return 0
  fi
  [[ -n "$proxy" ]] && args=(--build-arg "https_proxy=$proxy")
  (cd "$SMOKE_DIR" && nice -n 19 env CARGO_BUILD_JOBS=8 timeout 1800 docker build --network host \
    "${args[@]}" -f images/mcp/Dockerfile -t wonton-files:dev .) || return 1
  dig="$(docker image inspect wonton-files:dev --format '{{.Id}}')" || return 1
  sed -i -E "s#image: [^ ]*wonton-files:[^ ]*#image: wonton-files:dev@$dig#" "$SMOKE_DIR/docker-compose.yml"
  grep -qF "wonton-files:dev@$dig" "$SMOKE_DIR/docker-compose.yml" || { echo "清单摘要没换成功"; return 1; }
}

mcp_check() { # tools/list 必须有全部工具且都标只读；search_files 真搜到预先放进 documents 的文件
  local tools="$SMOKE_TOOLS" t out n_mine shares
  shares="$SMOKE_DIR/.wonton/data/shares/documents"   # 核心按 share_var 渲染到数据目录下的 shares
  mkdir -p "$shares"
  printf 'wonton-smoke-content\n' >"$shares/e2e-smoke-probe.txt" || { echo "放测试文件失败：$shares"; return 1; }
  n_mine="$(jq --arg s "$SMOKE_SLUG" '[.[] | select(.name | startswith($s + "__"))] | length' "$tools")"
  [[ "$n_mine" -eq 4 ]] || { echo "tools/list 里本插件工具 $n_mine 个，应有 4 个"; return 1; }
  for t in search_files search_content list_directory read_text_file; do
    jq -e --arg n "$SMOKE_SLUG"__"$t" 'any(.[]; .name == $n and .annotations.readOnlyHint == true)' "$tools" >/dev/null ||
      { echo "$t 不在 tools/list 或没标只读"; return 1; }
  done
  out="$(mcp call "$SMOKE_SLUG"__search_files '{"query":"e2e-smoke-probe","share":"documents"}')" ||
    { echo "search_files 调用失败：$out"; return 1; }
  grep -q 'e2e-smoke-probe.txt' <<<"$out" || { echo "没搜到测试文件：$out"; return 1; }
  out="$(mcp call "$SMOKE_SLUG"__read_text_file '{"share":"documents","path":"e2e-smoke-probe.txt"}')" ||
    { echo "read_text_file 调用失败：$out"; return 1; }
  grep -q 'wonton-smoke-content' <<<"$out" || { echo "读回的内容不对：$out"; return 1; }
}
