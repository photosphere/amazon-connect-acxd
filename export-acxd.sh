#!/usr/bin/env bash
#
# 交互式导出 Agentic CX Designer (ACXD) 应用到本地 JSON 文件。
#
# 只依赖 curl 和 jq，不需要 Node.js 或 SDK。ACXD SDK 本质是一套 REST API：
#   端点 : https://api.acxd.connect.<region>.amazonaws.com
#   认证 : x-api-key 请求头（Admin Hub 里为 programmatic user 生成的 API Key）
#   范围 : x-workspace-id 请求头
#   路径 : /sdk/...
# 文档: https://docs.aws.amazon.com/connect/latest/devguide/acxd-sdk.html
#
# 直接运行即可，脚本会依次询问 API Key 和控制台 URL：
#   ./export-acxd.sh
#
# 也可以用参数跳过部分提问（API Key 始终交互输入，不从文件或环境变量读取）：
#   ./export-acxd.sh --url "https://<host>/acxd/w/<workspaceId>/applications/<appId>/build"
#   ./export-acxd.sh --workspace <workspaceId> --all --with-shared --out ./export
#
set -uo pipefail

# ------------------------------------------------------------------- 默认配置

REGION="auto"          # auto = 自动探测区域
WORKSPACE_ID=""
APP_ID=""
SOURCE_URL=""
OUT_DIR=""
BUILD_DETAILS=5
WITH_SHARED=-1         # -1 = 交互询问，0 = 不导出，1 = 导出
LIST_ONLY=0
EXPORT_ALL=0
ENDPOINT=""
API_KEY=""

# --region auto 时依次探测的区域
PROBE_REGIONS="us-west-2 us-east-1 us-east-2 eu-west-2 eu-central-1 ap-southeast-1 ap-southeast-2 ap-northeast-1"

usage() {
  cat <<'EOF'
交互式导出 ACXD 应用（application、它用到的 flow、build、deployment）到本地 JSON。

运行时会提示输入：
  1. ACXD API Key（隐藏输入，不回显，也不从 .env / 环境变量读取）
  2. 控制台 URL 或 workspace ID

可选参数（提供了就不再询问对应内容）：
  --url <url>           控制台 URL，自动解析其中的 workspaceId 和 applicationId
  --workspace <uuid>    workspace ID
  --application <uuid>  application ID
  --all                 导出该 workspace 下所有 application
  --list                只列出 workspace 里的 application，然后退出
  --out <dir>           输出目录（默认 ./export-<应用名>）
  --region <region>     端点区域（默认 auto 自动探测）
  --endpoint <url>      直接指定完整端点
  --builds <n>          抓取最近 n 个 build 的详情（默认 5，0 表示不抓）
  --with-shared         同时导出共享资源（知识库、data request、slot type、guardrail 等）
  --no-shared           不导出共享资源
  -h, --help            显示本帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --url) SOURCE_URL="${2:?--url 需要一个值}"; shift 2 ;;
    --workspace|--workspace-id) WORKSPACE_ID="${2:?--workspace 需要一个值}"; shift 2 ;;
    --application|--application-id) APP_ID="${2:?--application 需要一个值}"; shift 2 ;;
    --all) EXPORT_ALL=1; shift ;;
    --list) LIST_ONLY=1; shift ;;
    --out) OUT_DIR="${2:?--out 需要一个值}"; shift 2 ;;
    --region) REGION="${2:?--region 需要一个值}"; shift 2 ;;
    --endpoint) ENDPOINT="${2:?--endpoint 需要一个值}"; shift 2 ;;
    --builds) BUILD_DETAILS="${2:?--builds 需要一个值}"; shift 2 ;;
    --with-shared) WITH_SHARED=1; shift ;;
    --no-shared) WITH_SHARED=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "缺少必需的命令: $tool" >&2; exit 1; }
done

# --------------------------------------------------------------------- 工具函数

ERRORS_FILE="$(mktemp -t acxd-errors)"
APPS_FILE="$(mktemp -t acxd-apps)"
trap 'rm -f "$ERRORS_FILE" "$APPS_FILE"' EXIT

record_error() { # 参数: 资源, HTTP 状态码, 消息
  jq -cn --arg r "$1" --arg s "$2" --arg m "$3" \
    '{resource:$r, statusCode:($s|tonumber? // $s), message:$m}' >> "$ERRORS_FILE"
  echo "  ! 失败 $1: HTTP $2 $3" >&2
}

urlenc() { jq -rn --arg v "$1" '$v|@uri'; }

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-120; }

api_base() { printf 'https://api.acxd.connect.%s.amazonaws.com' "$1"; }

# api <路径> -> 响应体输出到 stdout，失败返回非 0
api() {
  local path="$1" raw status body
  raw="$(curl -sS --max-time 60 -w $'\n%{http_code}' \
    -H "x-api-key: $API_KEY" \
    -H "x-workspace-id: $WORKSPACE_ID" \
    -H 'accept: application/json' \
    "${ENDPOINT}${path}" 2>/dev/null)" || { record_error "$path" 000 "网络错误"; return 1; }
  status="${raw##*$'\n'}"
  body="${raw%$'\n'*}"
  case "$status" in
    2*) printf '%s' "$body"; return 0 ;;
    *)
      record_error "$path" "$status" "$(printf '%s' "$body" | jq -r '.message // .__type // .' 2>/dev/null | head -1)"
      return 1
      ;;
  esac
}

# api_list <路径> [maxResults] -> 翻页取全部 items，输出 JSON 数组
# 知识库 documents 接口不接受 maxResults，第二个参数传 "" 即可跳过
api_list() {
  local path="$1" max="${2-100}" sep token page tmp q
  case "$path" in *\?*) sep='&' ;; *) sep='?' ;; esac
  tmp="$(mktemp -t acxd-page)"
  token=""
  while :; do
    q=""
    [ -n "$max" ] && q="${sep}maxResults=${max}"
    if [ -n "$token" ]; then
      if [ -n "$q" ]; then q="${q}&nextToken=$(urlenc "$token")"; else q="${sep}nextToken=$(urlenc "$token")"; fi
    fi
    page="$(api "${path}${q}")" || { rm -f "$tmp"; printf '[]'; return 1; }
    printf '%s\n' "$page" >> "$tmp"
    token="$(printf '%s' "$page" | jq -r '.nextToken // empty')"
    [ -n "$token" ] || break
  done
  jq -s '[.[] | (.items // .results // [])] | add // []' "$tmp"
  rm -f "$tmp"
}

save() { # 参数: 相对路径；JSON 从 stdin 读入
  local rel="$1" full="$OUT_DIR/$1"
  mkdir -p "$(dirname "$full")"
  jq '.' > "$full"
  echo "$rel"
}

get_and_save() { # 参数: API 路径, 输出相对路径
  local body
  body="$(api "$1")" || return 1
  printf '%s' "$body" | save "$2" >/dev/null
}

parse_url() { # 从控制台 URL 里解析 workspaceId / applicationId
  local url="$1" ws app
  ws="$(printf '%s' "$url" | sed -n 's|.*/acxd/w/\([0-9a-fA-F-]\{36\}\).*|\1|p')"
  app="$(printf '%s' "$url" | sed -n 's|.*/applications/\([0-9a-fA-F-]\{36\}\).*|\1|p')"
  [ -n "$ws" ] && WORKSPACE_ID="$ws"
  [ -n "$app" ] && [ -z "$APP_ID" ] && APP_ID="$app"
  [ -n "$ws" ]
}

# ------------------------------------------------------------------- 交互输入

if [ ! -t 0 ]; then
  echo "本脚本需要交互输入 API Key，请在终端里直接运行。" >&2
  exit 1
fi

echo "=============================================="
echo " ACXD 应用导出工具"
echo "=============================================="
echo ""

# 1) API Key：隐藏输入，不从 .env 或环境变量读取
attempt=0
while [ -z "$API_KEY" ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -gt 3 ]; then
    echo "未提供 API Key，已退出。" >&2
    exit 1
  fi
  printf '请输入 ACXD API Key（输入内容不会显示，回车确认）: '
  IFS= read -r -s API_KEY
  printf '\n'
  if [ -z "$API_KEY" ]; then
    echo "  API Key 不能为空。在 Admin Hub > Programmatic Users 里生成，格式为 acxd_live_<前缀>.<密钥>"
  fi
done
case "$API_KEY" in
  acxd_*) : ;;
  *) echo "  提示: Key 通常以 acxd_live_ 开头，请确认没有复制错。" ;;
esac
echo "  已接收 API Key（长度 ${#API_KEY}）"
echo ""

# 2) URL 或 workspace ID
if [ -n "$SOURCE_URL" ]; then
  parse_url "$SOURCE_URL" >/dev/null
fi
attempt=0
while [ -z "$WORKSPACE_ID" ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -gt 3 ]; then
    echo "未提供有效的 URL 或 workspace ID，已退出。" >&2
    exit 1
  fi
  echo "请粘贴 ACXD 控制台 URL（也可以直接输入 workspace ID）"
  echo "  例如: https://xxx.my.connect.aws/acxd/w/<workspaceId>/applications/<applicationId>/build"
  printf '> '
  IFS= read -r answer
  answer="$(printf '%s' "$answer" | tr -d '[:space:]')"
  case "$answer" in
    "")
      echo "  输入不能为空。"
      ;;
    http*)
      SOURCE_URL="$answer"
      if parse_url "$answer"; then
        echo "  workspace ID : $WORKSPACE_ID"
        [ -n "$APP_ID" ] && echo "  application  : $APP_ID"
      else
        echo "  这个 URL 里找不到 /acxd/w/<workspaceId>，请检查后重新粘贴。"
      fi
      ;;
    *)
      if printf '%s' "$answer" | grep -Eq '^[0-9a-fA-F-]{36}$'; then
        WORKSPACE_ID="$answer"
        echo "  workspace ID : $WORKSPACE_ID"
      else
        echo "  这看起来不是合法的 URL 或 36 位 UUID，请重新输入。"
      fi
      ;;
  esac
  echo ""
done

# ------------------------------------------------------------- 区域探测 / 连接

if [ -z "$ENDPOINT" ]; then
  if [ "$REGION" = "auto" ]; then
    echo "正在探测该 workspace 所在区域 ..."
    found=""
    for r in $PROBE_REGIONS; do
      code="$(curl -sS -o /dev/null --max-time 12 -w '%{http_code}' \
        -H "x-api-key: $API_KEY" -H "x-workspace-id: $WORKSPACE_ID" \
        "$(api_base "$r")/sdk/workspaces" 2>/dev/null)"
      if [ "$code" = "200" ]; then
        printf '  %-16s %s  <= 命中\n' "$r" "$code"
        found="$r"
        break
      fi
      printf '  %-16s %s\n' "$r" "$code"
    done
    if [ -z "$found" ]; then
      echo ""
      echo "所有区域都没有通过认证。常见原因：API Key 输入有误、Key 已被撤销，或该 programmatic user 没有这个 workspace 的权限。" >&2
      exit 1
    fi
    REGION="$found"
  fi
  ENDPOINT="$(api_base "$REGION")"
fi

echo ""
echo "workspace : $WORKSPACE_ID"
echo "端点      : $ENDPOINT"
echo ""

APPS_JSON="$(api_list /sdk/applications)"
APP_TOTAL="$(printf '%s' "$APPS_JSON" | jq 'length')"

if [ "$LIST_ONLY" -eq 1 ]; then
  echo "该 workspace 下共 $APP_TOTAL 个 application:"
  printf '%s' "$APPS_JSON" | jq -r '.[] | "  \(.applicationId)  \(.name)"'
  exit 0
fi

# --------------------------------------------------------------- 选择 application

TARGET_IDS=""
if [ "$EXPORT_ALL" -eq 1 ]; then
  TARGET_IDS="$(printf '%s' "$APPS_JSON" | jq -r '.[].applicationId // empty')"
elif [ -n "$APP_ID" ]; then
  TARGET_IDS="$APP_ID"
else
  if [ "$APP_TOTAL" -eq 0 ]; then
    echo "该 workspace 下没有 application。" >&2
    exit 1
  fi
  echo "该 workspace 下共 $APP_TOTAL 个 application，请选择要导出的一个:"
  printf '%s' "$APPS_JSON" | jq -r 'to_entries[] | "  [\(.key + 1)] \(.value.name)  (\(.value.applicationId))"'
  echo "  [a] 全部导出"
  attempt=0
  while [ -z "$TARGET_IDS" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 3 ]; then echo "未做出有效选择，已退出。" >&2; exit 1; fi
    printf '请输入序号（或 a 表示全部）: '
    IFS= read -r choice
    choice="$(printf '%s' "$choice" | tr -d '[:space:]')"
    case "$choice" in
      a|A|all)
        TARGET_IDS="$(printf '%s' "$APPS_JSON" | jq -r '.[].applicationId // empty')"
        ;;
      ''|*[!0-9]*)
        echo "  请输入数字序号，或输入 a 全部导出。"
        ;;
      *)
        if [ "$choice" -ge 1 ] && [ "$choice" -le "$APP_TOTAL" ]; then
          TARGET_IDS="$(printf '%s' "$APPS_JSON" | jq -r --argjson i "$((choice - 1))" '.[$i].applicationId // empty')"
        else
          echo "  序号超出范围（1-$APP_TOTAL）。"
        fi
        ;;
    esac
  done
  echo ""
fi

# ------------------------------------------------------- 是否导出共享资源 / 输出目录

if [ "$WITH_SHARED" -eq -1 ]; then
  printf '是否同时导出共享资源（知识库、data request、slot type、guardrail 等）? [y/N]: '
  IFS= read -r answer
  case "$answer" in
    y|Y|yes|YES) WITH_SHARED=1 ;;
    *) WITH_SHARED=0 ;;
  esac
  echo ""
fi

if [ -z "$OUT_DIR" ]; then
  first_id="$(printf '%s' "$TARGET_IDS" | head -1)"
  default_name="$(printf '%s' "$APPS_JSON" | jq -r --arg id "$first_id" '.[] | select(.applicationId==$id) | .name // empty' | head -1)"
  set -- $TARGET_IDS
  if [ $# -gt 1 ] || [ -z "$default_name" ]; then
    default_out="./export"
  else
    default_out="./export-$(sanitize "$default_name")"
  fi
  printf '输出目录 [%s]: ' "$default_out"
  IFS= read -r answer
  answer="$(printf '%s' "$answer" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -n "$answer" ]; then OUT_DIR="$answer"; else OUT_DIR="$default_out"; fi
  echo ""
fi
mkdir -p "$OUT_DIR"

# --------------------------------------------------------------- 导出单个应用

# 该 workspace 里所有 flow 的 ID，用于递归展开引用
ALL_FLOW_IDS="$(api_list /sdk/flows | jq -r '.[].flowId // empty')"

export_app() { # 参数: applicationId
  local app_id="$1" app_json app_name app_dir seeds
  local queue fetched fid flow_json cand flow_count
  local builds_json build_total build_detail bid
  local deployments_json deploy_total did

  app_json="$(api "/sdk/applications/$(urlenc "$app_id")")" || {
    echo "  读取 application $app_id 失败：ID 不对、区域不对，或该 Key 没有访问权限。" >&2
    return 1
  }
  app_name="$(printf '%s' "$app_json" | jq -r '.name // "app"')"
  app_dir="applications/$(sanitize "$app_name")-$app_id"
  printf '%s' "$app_json" | save "$app_dir/application.json" >/dev/null
  echo "  应用: $app_name ($app_id)"

  # flow：以 application 引用的 flow 为起点，再顺着 flow 定义里出现的其他 flowId
  # 递归展开（redirect / handoff 等），直到没有新增。
  # 下面这行故意写成单行且不含双引号：macOS 自带 bash 3.2 会错误解析
  # "$( ... '多行且含双引号的内容' ... )"。
  seeds="$(printf '%s' "$app_json" | jq -r '[(.flows//[])[].flowId, ((.settings.defaultFlows//{})|to_entries[].value.flowId), ((.settings.lifecycleHooks//{})|to_entries[].value)] | map(strings) | unique | .[]')"

  queue=""
  for fid in $seeds; do queue="$queue $fid"; done
  fetched=""
  flow_count=0
  while :; do
    set -- $queue
    [ $# -gt 0 ] || break
    fid="$1"; shift; queue="$*"
    case " $fetched " in *" $fid "*) continue ;; esac
    fetched="$fetched $fid"

    flow_json="$(api "/sdk/flows/$(urlenc "$fid")")" || continue
    printf '%s' "$flow_json" | save "$app_dir/flows/$(sanitize "$fid").json" >/dev/null
    flow_count=$((flow_count + 1))

    for cand in $ALL_FLOW_IDS; do
      case " $fetched $queue " in *" $cand "*) continue ;; esac
      case "$flow_json" in *"\"$cand\""*) queue="$queue $cand" ;; esac
    done
  done
  echo "    flow: $flow_count 个"

  builds_json="$(api_list "/sdk/applications/$(urlenc "$app_id")/builds")"
  printf '%s' "$builds_json" | save "$app_dir/builds.json" >/dev/null
  build_total="$(printf '%s' "$builds_json" | jq 'length')"
  build_detail=0
  if [ "${BUILD_DETAILS:-0}" -gt 0 ]; then
    for bid in $(printf '%s' "$builds_json" | jq -r --argjson n "$BUILD_DETAILS" '.[0:$n][].buildId // empty'); do
      if get_and_save "/sdk/applications/$(urlenc "$app_id")/builds/$(urlenc "$bid")" \
                      "$app_dir/builds/$(sanitize "$bid").json"; then
        build_detail=$((build_detail + 1))
      fi
    done
  fi
  echo "    build: $build_total 个（其中 $build_detail 个抓了详情）"

  deployments_json="$(api_list "/sdk/applications/$(urlenc "$app_id")/deployments")"
  printf '%s' "$deployments_json" | save "$app_dir/deployments.json" >/dev/null
  deploy_total="$(printf '%s' "$deployments_json" | jq 'length')"
  for did in $(printf '%s' "$deployments_json" | jq -r '.[].deploymentId // empty'); do
    get_and_save "/sdk/applications/$(urlenc "$app_id")/deployments/$(urlenc "$did")" \
                 "$app_dir/deployments/$(sanitize "$did").json" || true
  done
  echo "    deployment: $deploy_total 个"

  jq -cn --arg id "$app_id" --arg name "$app_name" --arg dir "$app_dir" \
    --argjson f "$flow_count" --argjson b "$build_total" --argjson d "$deploy_total" \
    '{applicationId:$id, name:$name, directory:$dir, flowCount:$f, buildCount:$b, deploymentCount:$d}' \
    >> "$APPS_FILE"
}

echo "开始导出到 $OUT_DIR"
printf '%s' "$APPS_JSON" | save "applications/_index.json" >/dev/null
for app_id in $TARGET_IDS; do
  export_app "$app_id" || true
done

# ----------------------------------------------------------------- 共享资源

shared_counts='{}'
if [ "$WITH_SHARED" -eq 1 ]; then
  echo "  共享资源:"
  api "/sdk/workspaces/$(urlenc "$WORKSPACE_ID")" | save "workspace.json" >/dev/null || true

  # 所有 flow 的完整定义（含未挂到任何 application 上的）
  flow_index="$(api_list /sdk/flows)"
  printf '%s' "$flow_index" | save "workspace/flows/_index.json" >/dev/null
  flow_ok=0
  for fid in $(printf '%s' "$flow_index" | jq -r '.[].flowId // empty'); do
    if get_and_save "/sdk/flows/$(urlenc "$fid")" "workspace/flows/$(sanitize "$fid").json"; then
      flow_ok=$((flow_ok + 1))
    fi
  done
  shared_counts="$(printf '%s' "$shared_counts" | jq --argjson v "$(printf '%s' "$flow_index" | jq 'length')" '.["flows"]=$v')"
  echo "    flows: $(printf '%s' "$flow_index" | jq 'length') 个（$flow_ok 个抓了完整定义）"

  # 只取列表的资源
  for pair in \
    "context-variables:context-variables.json" \
    "analytics-tags:analytics-tags.json" \
    "secrets:secrets.json"
  do
    res="${pair%%:*}"; file="${pair#*:}"
    items="$(api_list "/sdk/$res")"
    printf '%s' "$items" | save "workspace/$file" >/dev/null
    n="$(printf '%s' "$items" | jq 'length')"
    shared_counts="$(printf '%s' "$shared_counts" | jq --arg k "$res" --argjson v "$n" '.[$k]=$v')"
    echo "    $res: $n 个"
  done

  # 列表 + 逐个取详情的资源
  for pair in \
    "data-requests:dataRequestId" \
    "slot-types:slotTypeId" \
    "guardrails:guardrailId" \
    "modalities:modalityId" \
    "live-sync-scripts:liveSyncScriptId"
  do
    res="${pair%%:*}"; key="${pair#*:}"
    items="$(api_list "/sdk/$res")"
    printf '%s' "$items" | save "workspace/$res/_index.json" >/dev/null
    n="$(printf '%s' "$items" | jq 'length')"
    ok=0
    for id in $(printf '%s' "$items" | jq -r --arg k "$key" '.[][$k] // empty'); do
      if get_and_save "/sdk/$res/$(urlenc "$id")" "workspace/$res/$(sanitize "$id").json"; then
        ok=$((ok + 1))
      fi
    done
    shared_counts="$(printf '%s' "$shared_counts" | jq --arg k "$res" --argjson v "$n" '.[$k]=$v')"
    echo "    $res: $n 个（$ok 个抓了详情）"
  done

  # 知识库：定义 + article + document/publication 列表
  kbs="$(api_list /sdk/knowledge-bases)"
  printf '%s' "$kbs" | save "workspace/knowledge-bases/_index.json" >/dev/null
  kb_n="$(printf '%s' "$kbs" | jq 'length')"
  article_n=0
  for kb in $(printf '%s' "$kbs" | jq -r '.[].knowledgeBaseId // empty'); do
    kb_dir="workspace/knowledge-bases/$(sanitize "$kb")"
    get_and_save "/sdk/knowledge-bases/$(urlenc "$kb")" "$kb_dir/knowledge-base.json" || true

    articles="$(api_list "/sdk/knowledge-bases/$(urlenc "$kb")/articles")"
    printf '%s' "$articles" | save "$kb_dir/articles/_index.json" >/dev/null
    for aid in $(printf '%s' "$articles" | jq -r '.[].articleId // empty'); do
      if get_and_save "/sdk/knowledge-bases/$(urlenc "$kb")/articles/$(urlenc "$aid")" \
                      "$kb_dir/articles/$(sanitize "$aid").json"; then
        article_n=$((article_n + 1))
      fi
    done

    # 这个接口校验的是 size 参数，传 maxResults 会 400
    api_list "/sdk/knowledge-bases/$(urlenc "$kb")/documents" "" | save "$kb_dir/documents.json" >/dev/null
    api_list "/sdk/knowledge-bases/$(urlenc "$kb")/publications" | save "$kb_dir/publications.json" >/dev/null
  done
  shared_counts="$(printf '%s' "$shared_counts" \
    | jq --argjson kb "$kb_n" --argjson a "$article_n" '.["knowledge-bases"]=$kb | .["knowledge-base-articles"]=$a')"
  echo "    knowledge-bases: $kb_n 个（$article_n 篇 article）"
fi

# --------------------------------------------------------------------- 清单

apps_json="$(jq -cs '.' "$APPS_FILE" 2>/dev/null || echo '[]')"
error_json="$(jq -cs '.' "$ERRORS_FILE" 2>/dev/null || echo '[]')"
jq -n \
  --arg exportedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg sourceUrl "$SOURCE_URL" \
  --arg workspaceId "$WORKSPACE_ID" \
  --arg region "$REGION" \
  --arg endpoint "$ENDPOINT" \
  --argjson applications "$apps_json" \
  --argjson shared "$shared_counts" \
  --argjson errors "$error_json" \
  '{exportedAt:$exportedAt, sourceUrl:(if $sourceUrl=="" then null else $sourceUrl end),
    workspaceId:$workspaceId, region:$region, endpoint:$endpoint, tool:"export-acxd.sh",
    applications:$applications, sharedResourceCounts:$shared, errors:$errors}' \
  | save "manifest.json" >/dev/null

app_count="$(printf '%s' "$apps_json" | jq 'length')"
err_count="$(printf '%s' "$error_json" | jq 'length')"
file_count="$(find "$OUT_DIR" -type f | wc -l | tr -d ' ')"

echo ""
echo "=============================================="
echo "完成: 导出 $app_count 个 application，共 $file_count 个文件"
echo "位置: $OUT_DIR"
echo "清单: $OUT_DIR/manifest.json"
if [ "$err_count" -gt 0 ]; then
  echo "有 $err_count 个请求失败，详情见 manifest.json 的 errors 字段"
fi
echo "=============================================="
exit 0
