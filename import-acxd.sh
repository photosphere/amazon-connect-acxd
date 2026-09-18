#!/usr/bin/env bash
#
# 交互式把 export-acxd.sh 导出的 ACXD 应用导入到指定的 workspace。
#
# 只依赖 curl 和 jq。走的是 ACXD SDK 的 REST 接口：
#   端点 : https://api.acxd.connect.<region>.amazonaws.com
#   认证 : x-api-key 请求头
#   范围 : x-workspace-id 请求头
# 用到的操作（文档: https://docs.aws.amazon.com/connect/latest/devguide/acxd-api-reference.html）:
#   CreateFlow                POST  /sdk/flows
#   UpdateFlow                PUT   /sdk/flows/<flowId>
#   CreateApplication         POST  /sdk/applications
#   UpdateApplication         PUT   /sdk/applications/<applicationId>
#   CreateApplicationBuild    POST  /sdk/applications/<applicationId>/builds
#   CreateApplicationDeployment POST /sdk/applications/<applicationId>/deployments
#   CreateContextVariable     POST  /sdk/context-variables
#
# 导入顺序固定为：flow -> application -> build -> deployment。
# 因为 application 通过 flowId 引用 flow，flow 必须先存在。
#
# 直接运行，脚本会依次询问 API Key、目标 workspace、源目录等：
#   ./import-acxd.sh
#
# 先看一遍将要提交的请求体而不真正写入（不需要 API Key，不发任何请求）：
#   ./import-acxd.sh --dir ./export-acme0911 --all --dry-run
#
set -uo pipefail

# ------------------------------------------------------------------- 默认配置

REGION="auto"
WORKSPACE_ID=""
TARGET_URL=""
SRC_DIR=""
APP_FILTER=""
NEW_NAME=""
EXPORT_ALL=0
ON_CONFLICT=""         # 空 = 交互询问；skip | update | rename
DO_BUILD=-1            # -1 交互询问，0 不做，1 做
DO_DEPLOY=-1
ENVIRONMENT=""
CREATE_CTX_VARS=-1
DRY_RUN=0
SIMULATE_CONFLICT=0
ENDPOINT=""
API_KEY=""

PROBE_REGIONS="us-west-2 us-east-1 us-east-2 eu-west-2 eu-central-1 ap-southeast-1 ap-southeast-2 ap-northeast-1"
BUILD_WAIT_SECONDS=180
DEPLOY_WAIT_SECONDS=120

usage() {
  cat <<'EOF'
交互式把 export-acxd.sh 的导出目录导入到指定 ACXD workspace（flow、application，可选 build 和 deployment）。

运行时会提示输入：
  1. ACXD API Key（隐藏输入，不回显，也不从 .env / 环境变量读取；--dry-run 时不需要）
  2. 目标 workspace 的控制台 URL 或 workspace ID
  3. 导入源目录、要导入的 application、重名时怎么处理

可选参数（提供了就不再询问对应内容）：
  --dir <dir>             导入源目录（export-acxd.sh 的输出目录）
  --url <url>             目标控制台 URL，自动解析其中的 workspaceId
  --workspace <uuid>      目标 workspace ID
  --application <name>    只导入源目录里这个名字的 application
  --all                   导入源目录里所有 application
  --name <新名称>          导入后使用的应用名称（只在导入单个应用时有效）
  --on-conflict <策略>     目标里已存在同名资源时: skip | update | rename
  --build / --no-build    导入后是否创建 build
  --deploy / --no-deploy  build 成功后是否创建 deployment（会对线上生效，默认不做）
  --environment <env>     deployment 的目标环境: development | qa | staging | production
  --create-context-vars   自动创建 flow 用到但目标 workspace 里缺失的 context variable
  --region <region>       端点区域（默认 auto 自动探测）
  --endpoint <url>        直接指定完整端点
  --dry-run               只打印将要提交的请求体，不发任何写请求（也不需要 API Key）
  --simulate-conflict     仅 dry-run 有效: 假设目标里已存在源里所有同名资源，用来演练重名策略
  -h, --help              显示本帮助

重名策略说明：
  skip    目标已有同名 flow / application 就跳过，不动目标里的东西
  update  用源文件覆盖目标里的同名 flow / application（会改动目标现有配置）
  rename  给导入的资源换个新名字，目标原有资源保持不变
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir|--source) SRC_DIR="${2:?--dir 需要一个值}"; shift 2 ;;
    --url) TARGET_URL="${2:?--url 需要一个值}"; shift 2 ;;
    --workspace|--workspace-id) WORKSPACE_ID="${2:?--workspace 需要一个值}"; shift 2 ;;
    --application) APP_FILTER="${2:?--application 需要一个值}"; shift 2 ;;
    --name) NEW_NAME="${2:?--name 需要一个值}"; shift 2 ;;
    --all) EXPORT_ALL=1; shift ;;
    --on-conflict)
      ON_CONFLICT="${2:?--on-conflict 需要一个值}"
      case "$ON_CONFLICT" in
        skip|update|rename) : ;;
        *) echo "--on-conflict 只能是 skip / update / rename" >&2; exit 2 ;;
      esac
      shift 2 ;;
    --build) DO_BUILD=1; shift ;;
    --no-build) DO_BUILD=0; shift ;;
    --deploy) DO_DEPLOY=1; shift ;;
    --no-deploy) DO_DEPLOY=0; shift ;;
    --environment|--env) ENVIRONMENT="${2:?--environment 需要一个值}"; shift 2 ;;
    --create-context-vars) CREATE_CTX_VARS=1; shift ;;
    --no-create-context-vars) CREATE_CTX_VARS=0; shift ;;
    --region) REGION="${2:?--region 需要一个值}"; shift 2 ;;
    --endpoint) ENDPOINT="${2:?--endpoint 需要一个值}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --simulate-conflict) SIMULATE_CONFLICT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "缺少必需的命令: $tool" >&2; exit 1; }
done

# --------------------------------------------------------------------- 工具函数

TS="$(date -u +%Y%m%d-%H%M%S)"
ERRORS_FILE="$(mktemp -t acxd-imp-err)"
RESULT_FILE="$(mktemp -t acxd-imp-res)"
FLOW_MAP_FILE="$(mktemp -t acxd-imp-map)"       # 当前应用的重命名映射，每行 "旧flowId<TAB>新flowId"
FLOW_MAP_ALL_FILE="$(mktemp -t acxd-imp-mapall)" # 所有应用累计的重命名映射，只用于最后的报告
PAYLOAD_DIR=""
if [ "$DRY_RUN" -eq 1 ]; then
  PAYLOAD_DIR="./import-dryrun-$TS"
  mkdir -p "$PAYLOAD_DIR"
fi
trap 'rm -f "$ERRORS_FILE" "$RESULT_FILE" "$FLOW_MAP_FILE" "$FLOW_MAP_ALL_FILE" "${APPS_JSON_FILE:-}"' EXIT

record_error() { # 参数: 资源, HTTP 状态码, 消息
  jq -cn --arg r "$1" --arg s "$2" --arg m "$3" \
    '{resource:$r, statusCode:($s|tonumber? // $s), message:$m}' >> "$ERRORS_FILE"
  echo "    ! 失败 $1: HTTP $2 $3" >&2
}

record_result() { # 参数: 类型, 名称, 动作, 详情
  jq -cn --arg t "$1" --arg n "$2" --arg a "$3" --arg d "$4" \
    '{type:$t, name:$n, action:$a, detail:$d}' >> "$RESULT_FILE"
}

urlenc() { jq -rn --arg v "$1" '$v|@uri'; }

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-120; }

api_base() { printf 'https://api.acxd.connect.%s.amazonaws.com' "$1"; }

LAST_STATUS=""
LAST_BODY=""

# request <METHOD> <路径> [请求体文件]
# 成功时 LAST_BODY 为响应体、返回 0；失败时 LAST_STATUS 为状态码、返回 1（不自动记录错误）
request() {
  local method="$1" path="$2" body_file="${3-}" raw
  if [ -n "$body_file" ]; then
    raw="$(curl -sS --max-time 120 -w $'\n%{http_code}' -X "$method" \
      -H "x-api-key: $API_KEY" \
      -H "x-workspace-id: $WORKSPACE_ID" \
      -H 'content-type: application/json' \
      -H 'accept: application/json' \
      --data-binary "@$body_file" \
      "${ENDPOINT}${path}" 2>/dev/null)"
  else
    raw="$(curl -sS --max-time 120 -w $'\n%{http_code}' -X "$method" \
      -H "x-api-key: $API_KEY" \
      -H "x-workspace-id: $WORKSPACE_ID" \
      -H 'accept: application/json' \
      "${ENDPOINT}${path}" 2>/dev/null)"
  fi
  if [ $? -ne 0 ]; then
    LAST_STATUS="000"; LAST_BODY=""; return 1
  fi
  LAST_STATUS="${raw##*$'\n'}"
  LAST_BODY="${raw%$'\n'*}"
  case "$LAST_STATUS" in
    2*) return 0 ;;
    *) return 1 ;;
  esac
}

err_message() { printf '%s' "$LAST_BODY" | jq -r '.message // .__type // .' 2>/dev/null | head -1; }

# api_list <路径> -> 翻页取全部 items，输出 JSON 数组；失败输出 []
api_list() {
  local path="$1" sep token page tmp q
  case "$path" in *\?*) sep='&' ;; *) sep='?' ;; esac
  tmp="$(mktemp -t acxd-imp-page)"
  token=""
  while :; do
    q="${sep}maxResults=100"
    [ -n "$token" ] && q="${q}&nextToken=$(urlenc "$token")"
    if ! request GET "${path}${q}"; then
      record_error "GET $path" "$LAST_STATUS" "$(err_message)"
      rm -f "$tmp"; printf '[]'; return 1
    fi
    printf '%s\n' "$LAST_BODY" >> "$tmp"
    token="$(printf '%s' "$LAST_BODY" | jq -r '.nextToken // empty')"
    [ -n "$token" ] || break
  done
  jq -s '[.[] | (.items // .results // [])] | add // []' "$tmp"
  rm -f "$tmp"
}

# write_request <METHOD> <路径> <请求体> <dry-run 时保存的文件名>
# dry-run 下只把请求体写到 PAYLOAD_DIR 并返回一个占位响应
write_request() {
  local method="$1" path="$2" payload="$3" label="$4" tmp
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s' "$payload" | jq '.' > "$PAYLOAD_DIR/$label"
    echo "    [dry-run] $method $path  ->  $PAYLOAD_DIR/$label ($(printf '%s' "$payload" | wc -c | tr -d ' ') 字节)"
    LAST_STATUS="200"
    LAST_BODY="$(jq -cn --arg m "$method" --arg p "$path" \
      '{applicationId:"dry-run-application-id", buildId:"dry-run-build-id", deploymentId:"dry-run-deployment-id", status:"BUILT", deploymentStatus:"deployed", _dryRun:{method:$m, path:$p}}')"
    return 0
  fi
  tmp="$(mktemp -t acxd-imp-body)"
  printf '%s' "$payload" > "$tmp"
  request "$method" "$path" "$tmp"
  local rc=$?
  rm -f "$tmp"
  return $rc
}

parse_url() { # 从控制台 URL 里解析 workspaceId
  local url="$1" ws
  ws="$(printf '%s' "$url" | sed -n 's|.*/acxd/w/\([0-9a-fA-F-]\{36\}\).*|\1|p')"
  [ -n "$ws" ] && WORKSPACE_ID="$ws"
  [ -n "$ws" ]
}

ask() { # 参数: 提示语；答案输出到 stdout
  local prompt="$1" answer
  printf '%s' "$prompt" >&2
  IFS= read -r answer
  printf '%s' "$answer"
}

# 只保留 CreateFlow / UpdateFlow 接受的字段，丢掉 saveId、createdAt 这类只读字段
flow_payload() {
  jq '{flowId, description, nodes, aiDescription, untrained, mainLanguageCode, languageCode, languageCodes, slotTypes, contextVariables, mcp, metadata}
      | with_entries(select(.value != null))' "$1"
}

# 只保留 CreateApplication / UpdateApplication 接受的字段
app_payload() {
  jq '{name, description, flows, settings, metadata, deploymentSettings}
      | with_entries(select(.value != null))' "$1"
}

# 按 FLOW_MAP_FILE 里的重命名映射改写 JSON 里出现的 flowId 字符串
rewrite_flow_ids() { # stdin JSON -> stdout JSON
  local map
  if [ ! -s "$FLOW_MAP_FILE" ]; then cat; return; fi
  map="$(awk -F'\t' 'BEGIN{printf "["} {if(NR>1) printf ","; printf "{\"old\":\"%s\",\"new\":\"%s\"}", $1, $2} END{printf "]"}' "$FLOW_MAP_FILE")"
  jq -c --argjson m "$map" \
    'tojson | reduce $m[] as $p (.; gsub("\"" + $p.old + "\""; "\"" + $p.new + "\"")) | fromjson'
}

# ------------------------------------------------------------------- 交互输入

if [ ! -t 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  echo "本脚本需要交互输入 API Key，请在终端里直接运行（只想看请求体可以加 --dry-run）。" >&2
  exit 1
fi

echo "=============================================="
echo " ACXD 应用导入工具"
if [ "$DRY_RUN" -eq 1 ]; then
  echo " 模式: dry-run（不发任何写请求）"
fi
echo "=============================================="
echo ""

# 1) 源目录
if [ -z "$SRC_DIR" ]; then
  echo "请选择导入源目录（export-acxd.sh 的输出目录）"
  cand_list="$(find . -maxdepth 2 -name manifest.json -not -path '*/.git/*' 2>/dev/null | sed 's|/manifest.json$||' | sed 's|^\./||' | sort)"
  if [ -n "$cand_list" ]; then
    echo "  当前目录下找到这些候选:"
    i=0
    for c in $cand_list; do i=$((i + 1)); printf '    [%d] %s\n' "$i" "$c"; done
    echo "  也可以直接输入其它路径"
  fi
  attempt=0
  while [ -z "$SRC_DIR" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 3 ]; then echo "未提供有效的源目录，已退出。" >&2; exit 1; fi
    answer="$(ask '> ')"
    answer="$(printf '%s' "$answer" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$answer" in
      "") echo "  输入不能为空。" ;;
      ''|*[!0-9]*)
        if [ -d "$answer" ]; then SRC_DIR="$answer"; else echo "  找不到目录: $answer"; fi
        ;;
      *)
        picked="$(printf '%s\n' $cand_list | sed -n "${answer}p")"
        if [ -n "$picked" ]; then SRC_DIR="$picked"; else echo "  序号超出范围。"; fi
        ;;
    esac
  done
  echo ""
fi
SRC_DIR="${SRC_DIR%/}"
[ -d "$SRC_DIR" ] || { echo "源目录不存在: $SRC_DIR" >&2; exit 1; }
[ -d "$SRC_DIR/applications" ] || { echo "$SRC_DIR 下没有 applications/ 子目录，看起来不是导出目录。" >&2; exit 1; }

# 源目录里的 application 目录（每个目录下应有 application.json）
APP_DIRS="$(find "$SRC_DIR/applications" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)"
[ -n "$APP_DIRS" ] || { echo "$SRC_DIR/applications 下没有任何应用目录。" >&2; exit 1; }

echo "源目录 : $SRC_DIR"
if [ -f "$SRC_DIR/manifest.json" ]; then
  echo "导出于 : $(jq -r '.exportedAt // "未知"' "$SRC_DIR/manifest.json")（源 workspace $(jq -r '.workspaceId // "未知"' "$SRC_DIR/manifest.json")）"
fi
echo ""

# 2) API Key
if [ "$DRY_RUN" -eq 0 ]; then
  attempt=0
  while [ -z "$API_KEY" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 3 ]; then echo "未提供 API Key，已退出。" >&2; exit 1; fi
    printf '请输入目标 workspace 的 ACXD API Key（输入内容不会显示，回车确认）: '
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
  echo "  注意: 这个 Key 必须有写权限，导入会在目标 workspace 里创建资源。"
  echo ""
fi

# 3) 目标 workspace
if [ -n "$TARGET_URL" ]; then parse_url "$TARGET_URL" >/dev/null; fi
if [ -z "$WORKSPACE_ID" ] && [ "$DRY_RUN" -eq 1 ]; then
  WORKSPACE_ID="dry-run-workspace"
fi
attempt=0
while [ -z "$WORKSPACE_ID" ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -gt 3 ]; then echo "未提供有效的 URL 或 workspace ID，已退出。" >&2; exit 1; fi
  echo "请粘贴目标 ACXD 控制台 URL（也可以直接输入 workspace ID）"
  echo "  例如: https://xxx.my.connect.aws/acxd/w/<workspaceId>/applications"
  answer="$(ask '> ')"
  answer="$(printf '%s' "$answer" | tr -d '[:space:]')"
  case "$answer" in
    "") echo "  输入不能为空。" ;;
    http*)
      if parse_url "$answer"; then
        TARGET_URL="$answer"
        echo "  目标 workspace : $WORKSPACE_ID"
      else
        echo "  这个 URL 里找不到 /acxd/w/<workspaceId>，请检查后重新粘贴。"
      fi
      ;;
    *)
      if printf '%s' "$answer" | grep -Eq '^[0-9a-fA-F-]{36}$'; then
        WORKSPACE_ID="$answer"
        echo "  目标 workspace : $WORKSPACE_ID"
      else
        echo "  这看起来不是合法的 URL 或 36 位 UUID，请重新输入。"
      fi
      ;;
  esac
  echo ""
done

if [ -f "$SRC_DIR/manifest.json" ]; then
  src_ws="$(jq -r '.workspaceId // empty' "$SRC_DIR/manifest.json")"
  if [ -n "$src_ws" ] && [ "$src_ws" = "$WORKSPACE_ID" ]; then
    echo "注意: 目标 workspace 和导出时的源 workspace 是同一个。"
    echo "      同名 flow / application 会触发重名处理，请确认这是你想要的。"
    echo ""
  fi
fi

# ------------------------------------------------------------- 区域探测 / 连接

if [ -z "$ENDPOINT" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    [ "$REGION" = "auto" ] && REGION="us-west-2"
    ENDPOINT="$(api_base "$REGION")"
  elif [ "$REGION" = "auto" ]; then
    echo "正在探测目标 workspace 所在区域 ..."
    found=""
    for r in $PROBE_REGIONS; do
      code="$(curl -sS -o /dev/null --max-time 12 -w '%{http_code}' \
        -H "x-api-key: $API_KEY" -H "x-workspace-id: $WORKSPACE_ID" \
        "$(api_base "$r")/sdk/workspaces" 2>/dev/null)"
      if [ "$code" = "200" ]; then
        printf '  %-16s %s  <= 命中\n' "$r" "$code"
        found="$r"; break
      fi
      printf '  %-16s %s\n' "$r" "$code"
    done
    if [ -z "$found" ]; then
      echo ""
      echo "所有区域都没有通过认证。常见原因：API Key 输入有误、Key 已被撤销，或该 programmatic user 没有这个 workspace 的权限。" >&2
      exit 1
    fi
    REGION="$found"
    ENDPOINT="$(api_base "$REGION")"
  else
    ENDPOINT="$(api_base "$REGION")"
  fi
fi

echo ""
echo "目标 workspace : $WORKSPACE_ID"
echo "端点           : $ENDPOINT"
echo ""

# --------------------------------------------------------------- 选择 application

APP_TOTAL=0
for d in $APP_DIRS; do
  [ -f "$d/application.json" ] && APP_TOTAL=$((APP_TOTAL + 1))
done
[ "$APP_TOTAL" -gt 0 ] || { echo "源目录里没有可用的 application.json。" >&2; exit 1; }

TARGET_DIRS=""
if [ "$EXPORT_ALL" -eq 1 ]; then
  TARGET_DIRS="$APP_DIRS"
elif [ -n "$APP_FILTER" ]; then
  for d in $APP_DIRS; do
    [ -f "$d/application.json" ] || continue
    if [ "$(jq -r '.name // empty' "$d/application.json")" = "$APP_FILTER" ]; then
      TARGET_DIRS="$d"
    fi
  done
  [ -n "$TARGET_DIRS" ] || { echo "源目录里找不到名为 $APP_FILTER 的 application。" >&2; exit 1; }
elif [ "$APP_TOTAL" -eq 1 ]; then
  TARGET_DIRS="$APP_DIRS"
  echo "源目录里只有一个 application，直接使用: $(jq -r '.name' "$(printf '%s' "$TARGET_DIRS")/application.json")"
  echo ""
else
  echo "源目录里共 $APP_TOTAL 个 application，请选择要导入的一个:"
  i=0
  for d in $APP_DIRS; do
    [ -f "$d/application.json" ] || continue
    i=$((i + 1))
    printf '  [%d] %s  (flow %s 个)\n' "$i" \
      "$(jq -r '.name // "?"' "$d/application.json")" \
      "$(ls "$d/flows" 2>/dev/null | wc -l | tr -d ' ')"
  done
  echo "  [a] 全部导入"
  attempt=0
  while [ -z "$TARGET_DIRS" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 3 ]; then echo "未做出有效选择，已退出。" >&2; exit 1; fi
    choice="$(ask '请输入序号（或 a 表示全部）: ')"
    choice="$(printf '%s' "$choice" | tr -d '[:space:]')"
    case "$choice" in
      a|A|all) TARGET_DIRS="$APP_DIRS" ;;
      ''|*[!0-9]*) echo "  请输入数字序号，或输入 a 全部导入。" ;;
      *)
        picked="$(printf '%s\n' $APP_DIRS | sed -n "${choice}p")"
        if [ -n "$picked" ]; then TARGET_DIRS="$picked"; else echo "  序号超出范围（1-${APP_TOTAL}）。"; fi
        ;;
    esac
  done
  echo ""
fi

set -- $TARGET_DIRS
TARGET_COUNT=$#
if [ -n "$NEW_NAME" ] && [ "$TARGET_COUNT" -gt 1 ]; then
  echo "--name 只在导入单个应用时有效，已忽略。"
  NEW_NAME=""
fi

# --------------------------------------------------------------- 目标现有资源

EXISTING_FLOWS=""
EXISTING_APPS=""
EXISTING_CTX_VARS=""
APPS_JSON_FILE="$(mktemp -t acxd-imp-apps)"
printf '[]' > "$APPS_JSON_FILE"
if [ "$DRY_RUN" -eq 0 ]; then
  echo "正在读取目标 workspace 现有资源 ..."
  EXISTING_FLOWS="$(api_list /sdk/flows | jq -r '.[].flowId // empty')"
  api_list /sdk/applications > "$APPS_JSON_FILE"
  EXISTING_APPS="$(jq -r '.[].name // empty' "$APPS_JSON_FILE")"
  EXISTING_CTX_VARS="$(api_list /sdk/context-variables | jq -r '.[].name // empty')"
  echo "  已有 flow $(printf '%s\n' ${EXISTING_FLOWS} | grep -c . || true) 个，application $(printf '%s\n' ${EXISTING_APPS} | grep -c . || true) 个"
  echo ""
elif [ "$SIMULATE_CONFLICT" -eq 1 ]; then
  # dry-run 演练：把源里的资源都当成目标里已经有了
  for d in $TARGET_DIRS; do
    [ -f "$d/application.json" ] || continue
    EXISTING_APPS="$EXISTING_APPS
$(jq -r '.name // empty' "$d/application.json")"
    for f in "$d"/flows/*.json; do
      [ -f "$f" ] || continue
      EXISTING_FLOWS="$EXISTING_FLOWS $(jq -r '.flowId // empty' "$f")"
    done
  done
  echo "已启用 --simulate-conflict：把源里的 flow / application 都当作目标里已存在"
  echo ""
fi

flow_exists() { case " $EXISTING_FLOWS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
ctx_var_exists() { case " $EXISTING_CTX_VARS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
app_name_exists() { printf '%s\n' "$EXISTING_APPS" | grep -Fxq "$1"; }
app_id_by_name() {
  if [ "$DRY_RUN" -eq 1 ]; then printf 'dry-run-existing-application-id'; return 0; fi
  jq -r --arg n "$1" '.[] | select(.name==$n) | .applicationId // empty' "$APPS_JSON_FILE" | head -1
}

# ------------------------------------------------------------------- 冲突策略

# 先看看有没有真的冲突，没有就不啰嗦
CONFLICTS=""
for d in $TARGET_DIRS; do
  [ -f "$d/application.json" ] || continue
  app_name="$(jq -r '.name // "app"' "$d/application.json")"
  if app_name_exists "$app_name"; then CONFLICTS="$CONFLICTS application:$app_name"; fi
  if [ -d "$d/flows" ]; then
    for f in "$d"/flows/*.json; do
      [ -f "$f" ] || continue
      fid="$(jq -r '.flowId // empty' "$f")"
      [ -n "$fid" ] || continue
      if flow_exists "$fid"; then CONFLICTS="$CONFLICTS flow:$fid"; fi
    done
  fi
done

if [ -n "$CONFLICTS" ]; then
  echo "目标 workspace 里已存在同名资源:"
  for c in $CONFLICTS; do echo "  - ${c%%:*} ${c#*:}"; done
  echo ""
  if [ -z "$ON_CONFLICT" ]; then
    echo "要怎么处理?"
    echo "  [1] 跳过     已存在的就不导入，目标现有配置不动"
    echo "  [2] 覆盖     用源文件更新目标里的同名资源（会改动目标现有配置）"
    echo "  [3] 重命名   导入成新名字，目标现有资源保持不变"
    attempt=0
    while [ -z "$ON_CONFLICT" ]; do
      attempt=$((attempt + 1))
      if [ "$attempt" -gt 3 ]; then echo "未做出有效选择，已退出。" >&2; exit 1; fi
      choice="$(ask '请选择 [1/2/3]: ')"
      case "$(printf '%s' "$choice" | tr -d '[:space:]')" in
        1) ON_CONFLICT="skip" ;;
        2) ON_CONFLICT="update" ;;
        3) ON_CONFLICT="rename" ;;
        *) echo "  请输入 1、2 或 3。" ;;
      esac
    done
    echo ""
  fi
  echo "重名策略: $ON_CONFLICT"
  echo ""
fi
[ -n "$ON_CONFLICT" ] || ON_CONFLICT="skip"

# ------------------------------------------------------- 应用名称 / build / deploy

if [ "$TARGET_COUNT" -eq 1 ] && [ -z "$NEW_NAME" ] && [ "$ON_CONFLICT" = "rename" ]; then
  only_dir="$(printf '%s' "$TARGET_DIRS")"
  src_name="$(jq -r '.name // "app"' "$only_dir/application.json")"
  if app_name_exists "$src_name"; then
    suggest="${src_name}Imported"
    answer="$(ask "导入后的应用名称 [$suggest]: ")"
    answer="$(printf '%s' "$answer" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ -n "$answer" ]; then NEW_NAME="$answer"; else NEW_NAME="$suggest"; fi
    echo ""
  fi
fi

if [ "$DO_BUILD" -eq -1 ]; then
  answer="$(ask '导入后是否创建 build（编译成可部署的包，不影响线上）? [Y/n]: ')"
  case "$answer" in
    n|N|no|NO) DO_BUILD=0 ;;
    *) DO_BUILD=1 ;;
  esac
  echo ""
fi

if [ "$DO_BUILD" -eq 1 ] && [ "$DO_DEPLOY" -eq -1 ]; then
  echo "是否在 build 成功后创建 deployment?"
  echo "  警告: deployment 会让这个 build 对终端用户生效，并使该应用上一个 deployment 失效。"
  echo "        不确定就选 n，之后在控制台里手动部署。"
  answer="$(ask '创建 deployment? [y/N]: ')"
  case "$answer" in
    y|Y|yes|YES) DO_DEPLOY=1 ;;
    *) DO_DEPLOY=0 ;;
  esac
  echo ""
fi
[ "$DO_BUILD" -eq 1 ] || DO_DEPLOY=0
[ "$DO_DEPLOY" -eq -1 ] && DO_DEPLOY=0

# --------------------------------------------------------------------- 导入实现

create_or_update_flow() { # 参数: flow 文件；输出动作到 stdout
  local file="$1" src_id target_id payload action
  src_id="$(jq -r '.flowId // empty' "$file")"
  [ -n "$src_id" ] || { echo "    跳过 $file: 里面没有 flowId" >&2; return 1; }

  target_id="$src_id"
  action="create"
  if flow_exists "$src_id"; then
    case "$ON_CONFLICT" in
      skip)
        # 提示信息走 stderr，stdout 只放给调用方解析的计划行
        echo "    flow $src_id: 目标已存在，跳过" >&2
        record_result flow "$src_id" skip "目标 workspace 已存在同名 flow"
        return 0
        ;;
      update) action="update" ;;
      rename)
        # flowId 只允许字母数字，3-64 位，所以后缀也得是字母数字
        target_id="$(printf '%s%s' "$src_id" "Imported" | cut -c1-64)"
        n=2
        while flow_exists "$target_id"; do
          target_id="$(printf '%s%s%d' "$src_id" "Imported" "$n" | cut -c1-64)"
          n=$((n + 1))
          [ "$n" -gt 50 ] && break
        done
        printf '%s\t%s\n' "$src_id" "$target_id" >> "$FLOW_MAP_FILE"
        printf '%s\t%s\n' "$src_id" "$target_id" >> "$FLOW_MAP_ALL_FILE"
        echo "    flow $src_id -> 重命名为 $target_id" >&2
        ;;
    esac
  fi
  printf '%s\t%s\t%s\n' "$target_id" "$action" "$file"
}

import_flows() { # 参数: 应用目录；成功返回 0
  local app_dir="$1" plan_file f line target_id action file payload ok=0 fail=0
  [ -d "$app_dir/flows" ] || { echo "    该应用目录下没有 flows/，跳过 flow 导入"; return 0; }

  plan_file="$(mktemp -t acxd-imp-plan)"
  : > "$FLOW_MAP_FILE"
  for f in "$app_dir"/flows/*.json; do
    [ -f "$f" ] || continue
    create_or_update_flow "$f" >> "$plan_file"
  done

  # 计划文件每行是 "目标flowId<TAB>动作<TAB>源文件"，跳过的 flow 不会写进来
  while IFS="$(printf '\t')" read -r target_id action file; do
    [ -n "${file:-}" ] || continue
    payload="$(flow_payload "$file" | rewrite_flow_ids | jq -c --arg id "$target_id" '.flowId=$id')"
    if [ "$action" = "update" ]; then
      if write_request PUT "/sdk/flows/$(urlenc "$target_id")" \
           "$(printf '%s' "$payload" | jq -c 'del(.flowId)')" "flow-$(sanitize "$target_id")-update.json"; then
        echo "    flow $target_id: 已覆盖更新"
        record_result flow "$target_id" update ""
        ok=$((ok + 1))
      elif [ "$LAST_STATUS" = "405" ] || [ "$LAST_STATUS" = "404" ]; then
        # 有些网关只接 PATCH
        if write_request PATCH "/sdk/flows/$(urlenc "$target_id")" \
             "$(printf '%s' "$payload" | jq -c 'del(.flowId)')" "flow-$(sanitize "$target_id")-patch.json"; then
          echo "    flow $target_id: 已覆盖更新（PATCH）"
          record_result flow "$target_id" update "PATCH"
          ok=$((ok + 1))
        else
          record_error "PUT /sdk/flows/$target_id" "$LAST_STATUS" "$(err_message)"
          record_result flow "$target_id" failed "$(err_message)"
          fail=$((fail + 1))
        fi
      else
        record_error "PUT /sdk/flows/$target_id" "$LAST_STATUS" "$(err_message)"
        record_result flow "$target_id" failed "$(err_message)"
        fail=$((fail + 1))
      fi
    else
      if write_request POST "/sdk/flows" "$payload" "flow-$(sanitize "$target_id")-create.json"; then
        echo "    flow $target_id: 已创建"
        record_result flow "$target_id" create ""
        EXISTING_FLOWS="$EXISTING_FLOWS $target_id"
        ok=$((ok + 1))
      else
        record_error "POST /sdk/flows ($target_id)" "$LAST_STATUS" "$(err_message)"
        record_result flow "$target_id" failed "$(err_message)"
        fail=$((fail + 1))
      fi
    fi
  done < "$plan_file"
  rm -f "$plan_file"

  echo "    flow: 成功 ${ok}，失败 $fail"
  [ "$fail" -eq 0 ]
}

check_context_variables() { # 参数: 应用目录
  local app_dir="$1" names n missing=""
  [ -d "$app_dir/flows" ] || return 0
  names="$(jq -r '[.nodes[]? | .metadata?.stateModifications[]? | select(.type=="context") | .name] | .[]?' \
    "$app_dir"/flows/*.json 2>/dev/null | sort -u)"
  [ -n "$names" ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    flow 用到的 workspace context variable: $(printf '%s' "$names" | tr '\n' ' ')"
    echo "    （真实导入时会检查目标 workspace 是否有这些变量，缺失会导致 build 校验失败）"
    return 0
  fi
  for n in $names; do
    ctx_var_exists "$n" || missing="$missing $n"
  done
  [ -n "$missing" ] || return 0

  echo "    flow 里用到但目标 workspace 缺失的 context variable:$missing"
  if [ "$CREATE_CTX_VARS" -eq -1 ]; then
    answer="$(ask '    要现在创建这些 context variable 吗（缺失会导致 build 校验失败）? [Y/n]: ')"
    case "$answer" in
      n|N|no|NO) CREATE_CTX_VARS=0 ;;
      *) CREATE_CTX_VARS=1 ;;
    esac
  fi
  if [ "$CREATE_CTX_VARS" -ne 1 ]; then
    echo "    已跳过创建，build 可能因此失败。"
    return 0
  fi
  for n in $missing; do
    payload="$(jq -cn --arg name "$n" '{name:$name, schema:{type:"string", isSensitive:false}}')"
    if write_request POST "/sdk/context-variables" "$payload" "context-variable-$(sanitize "$n").json"; then
      echo "    context variable $n: 已创建"
      record_result context-variable "$n" create ""
      EXISTING_CTX_VARS="$EXISTING_CTX_VARS $n"
    else
      record_error "POST /sdk/context-variables ($n)" "$LAST_STATUS" "$(err_message)"
      record_result context-variable "$n" failed "$(err_message)"
    fi
  done
}

import_application() { # 参数: 应用目录；成功时把新的 applicationId 写到 NEW_APP_ID
  local app_dir="$1" src_name target_name payload base_payload
  NEW_APP_ID=""
  src_name="$(jq -r '.name // "app"' "$app_dir/application.json")"
  target_name="$src_name"

  if app_name_exists "$src_name"; then
    case "$ON_CONFLICT" in
      skip)
        echo "    application $src_name: 目标已存在同名应用，跳过"
        record_result application "$src_name" skip "目标 workspace 已存在同名 application"
        return 0
        ;;
      rename)
        if [ -n "$NEW_NAME" ]; then
          target_name="$NEW_NAME"
        else
          target_name="${src_name}Imported"
          n=2
          while app_name_exists "$target_name"; do
            target_name="${src_name}Imported$n"; n=$((n + 1))
            [ "$n" -gt 50 ] && break
          done
        fi
        echo "    application $src_name -> 重命名为 $target_name"
        ;;
      update)
        # 应用是按 applicationId 更新的，源目录里的 ID 属于源 workspace，在目标里没有意义，
        # 所以按名字在目标现有应用列表里找 ID
        local existing_id
        existing_id="$(app_id_by_name "$src_name")"
        if [ -n "$existing_id" ]; then
          payload="$(app_payload "$app_dir/application.json" | rewrite_flow_ids | jq -c --arg n "$target_name" '.name=$n')"
          if write_request PUT "/sdk/applications/$(urlenc "$existing_id")" "$payload" \
               "application-$(sanitize "$target_name")-update.json"; then
            NEW_APP_ID="$(printf '%s' "$LAST_BODY" | jq -r '.applicationId // empty')"
            [ -n "$NEW_APP_ID" ] || NEW_APP_ID="$existing_id"
            echo "    application $target_name: 已覆盖更新（${NEW_APP_ID}）"
            record_result application "$target_name" update "$NEW_APP_ID"
            return 0
          fi
          record_error "PUT /sdk/applications/$existing_id" "$LAST_STATUS" "$(err_message)"
          record_result application "$target_name" failed "$(err_message)"
          return 1
        fi
        echo "    application $src_name: 目标里没找到同名应用的 ID，改为新建"
        ;;
    esac
  elif [ -n "$NEW_NAME" ]; then
    target_name="$NEW_NAME"
  fi

  base_payload="$(app_payload "$app_dir/application.json" | rewrite_flow_ids | jq -c --arg n "$target_name" '.name=$n')"

  if write_request POST "/sdk/applications" "$base_payload" "application-$(sanitize "$target_name")-create.json"; then
    NEW_APP_ID="$(printf '%s' "$LAST_BODY" | jq -r '.applicationId // empty')"
    echo "    application $target_name: 已创建（${NEW_APP_ID}）"
    record_result application "$target_name" create "$NEW_APP_ID"
    return 0
  fi

  # 整包提交被拒时退一步：先建最小应用，再用 update 补齐 flows / settings
  echo "    application $target_name: 整包创建被拒（HTTP $LAST_STATUS $(err_message)），改为先建后补"
  local minimal
  minimal="$(printf '%s' "$base_payload" | jq -c '{name, settings: (.settings // {})}')"
  if ! write_request POST "/sdk/applications" "$minimal" "application-$(sanitize "$target_name")-create-minimal.json"; then
    record_error "POST /sdk/applications ($target_name)" "$LAST_STATUS" "$(err_message)"
    record_result application "$target_name" failed "$(err_message)"
    return 1
  fi
  NEW_APP_ID="$(printf '%s' "$LAST_BODY" | jq -r '.applicationId // empty')"
  if write_request PUT "/sdk/applications/$(urlenc "$NEW_APP_ID")" \
       "$(printf '%s' "$base_payload" | jq -c 'del(.name)')" \
       "application-$(sanitize "$target_name")-fill.json"; then
    echo "    application $target_name: 已创建并补齐配置（${NEW_APP_ID}）"
    record_result application "$target_name" create "$NEW_APP_ID (两步)"
    return 0
  fi
  record_error "PUT /sdk/applications/$NEW_APP_ID" "$LAST_STATUS" "$(err_message)"
  record_result application "$target_name" partial "已创建 ${NEW_APP_ID}，但补齐 flows/settings 失败"
  return 1
}

build_application() { # 参数: applicationId, 应用名；成功时把 buildId 写到 NEW_BUILD_ID
  local app_id="$1" app_name="$2" payload waited status
  NEW_BUILD_ID=""
  payload="$(jq -cn --arg d "由 import-acxd.sh 导入于 $TS" '{description:$d}')"
  if ! write_request POST "/sdk/applications/$(urlenc "$app_id")/builds" "$payload" \
        "build-$(sanitize "$app_name").json"; then
    record_error "POST /sdk/applications/$app_id/builds" "$LAST_STATUS" "$(err_message)"
    record_result build "$app_name" failed "$(err_message)"
    return 1
  fi
  NEW_BUILD_ID="$(printf '%s' "$LAST_BODY" | jq -r '.buildId // empty')"
  status="$(printf '%s' "$LAST_BODY" | jq -r '.status // "PENDING"')"
  echo "    build $NEW_BUILD_ID: 已提交（${status}）"

  if [ "$DRY_RUN" -eq 1 ]; then
    record_result build "$app_name" create "dry-run"
    return 0
  fi

  waited=0
  while [ "$status" = "PENDING" ] && [ "$waited" -lt "$BUILD_WAIT_SECONDS" ]; do
    sleep 5; waited=$((waited + 5))
    if request GET "/sdk/applications/$(urlenc "$app_id")/builds/$(urlenc "$NEW_BUILD_ID")"; then
      status="$(printf '%s' "$LAST_BODY" | jq -r '.status // "PENDING"')"
    fi
    printf '\r    等待 build 完成 ... %ss（当前 %s）' "$waited" "$status"
  done
  printf '\n'

  case "$status" in
    BUILT)
      echo "    build $NEW_BUILD_ID: BUILT"
      record_result build "$app_name" create "$NEW_BUILD_ID"
      return 0
      ;;
    *)
      echo "    build $NEW_BUILD_ID: 状态 ${status}，不继续部署"
      printf '%s' "$LAST_BODY" | jq -r '.validation // .errors // .message // empty' 2>/dev/null | head -20
      record_result build "$app_name" failed "状态 $status"
      return 1
      ;;
  esac
}

deploy_application() { # 参数: applicationId, buildId, 应用名, 源 application.json
  local app_id="$1" build_id="$2" app_name="$3" app_file="$4" env langs payload
  env="$ENVIRONMENT"
  [ -n "$env" ] || env="$(jq -r '.deploymentSettings.environment // "development"' "$app_file")"
  langs="$(jq -c '.settings.languageCodes // ["en-US"]' "$app_file")"

  payload="$(jq -cn --arg b "$build_id" --arg e "$env" --arg d "由 import-acxd.sh 导入于 $TS" --argjson l "$langs" \
    '{buildIdentifier:$b, environment:$e, description:$d, languageCodes:$l}')"
  if write_request POST "/sdk/applications/$(urlenc "$app_id")/deployments" "$payload" \
       "deployment-$(sanitize "$app_name").json"; then
    echo "    deployment: 已提交到 ${env}（$(printf '%s' "$LAST_BODY" | jq -r '.deploymentId // "?"')）"
    record_result deployment "$app_name" create "$(printf '%s' "$LAST_BODY" | jq -r '.deploymentId // empty') -> $env"
    return 0
  fi

  # buildIdentifier 被拒时试一下 buildId 这种字段名
  if [ "$LAST_STATUS" = "400" ]; then
    payload="$(jq -cn --arg b "$build_id" --arg e "$env" --arg d "由 import-acxd.sh 导入于 $TS" --argjson l "$langs" \
      '{buildId:$b, environment:$e, description:$d, languageCodes:$l}')"
    if write_request POST "/sdk/applications/$(urlenc "$app_id")/deployments" "$payload" \
         "deployment-$(sanitize "$app_name")-alt.json"; then
      echo "    deployment: 已提交到 ${env}（$(printf '%s' "$LAST_BODY" | jq -r '.deploymentId // "?"')）"
      record_result deployment "$app_name" create "$(printf '%s' "$LAST_BODY" | jq -r '.deploymentId // empty') -> $env"
      return 0
    fi
  fi
  record_error "POST /sdk/applications/$app_id/deployments" "$LAST_STATUS" "$(err_message)"
  record_result deployment "$app_name" failed "$(err_message)"
  return 1
}

# ------------------------------------------------------------------- 执行导入

echo "开始导入"
echo ""
for d in $TARGET_DIRS; do
  [ -f "$d/application.json" ] || continue
  app_name="$(jq -r '.name // "app"' "$d/application.json")"
  echo "  应用: $app_name  (来源 $d)"

  import_flows "$d" || echo "    有 flow 导入失败，application 可能因为引用缺失而建不起来"
  check_context_variables "$d"

  if import_application "$d"; then
    if [ -n "${NEW_APP_ID:-}" ] && [ "$DO_BUILD" -eq 1 ]; then
      if build_application "$NEW_APP_ID" "$app_name"; then
        if [ "$DO_DEPLOY" -eq 1 ]; then
          deploy_application "$NEW_APP_ID" "$NEW_BUILD_ID" "$app_name" "$d/application.json" || true
        fi
      fi
    fi
  fi
  echo ""
done

# --------------------------------------------------------------------- 汇总

results_json="$(jq -cs '.' "$RESULT_FILE" 2>/dev/null || echo '[]')"
errors_json="$(jq -cs '.' "$ERRORS_FILE" 2>/dev/null || echo '[]')"
flow_map_json="$(awk -F'\t' 'BEGIN{printf "["} {if(NR>1) printf ","; printf "{\"from\":\"%s\",\"to\":\"%s\"}", $1, $2} END{printf "]"}' "$FLOW_MAP_ALL_FILE")"
REPORT="./import-report-$TS.json"

jq -n \
  --arg importedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg sourceDir "$SRC_DIR" \
  --arg workspaceId "$WORKSPACE_ID" \
  --arg region "$REGION" \
  --arg endpoint "$ENDPOINT" \
  --arg onConflict "$ON_CONFLICT" \
  --argjson dryRun "$DRY_RUN" \
  --argjson results "$results_json" \
  --argjson renamedFlows "$flow_map_json" \
  --argjson errors "$errors_json" \
  '{importedAt:$importedAt, tool:"import-acxd.sh", dryRun:($dryRun==1), sourceDir:$sourceDir,
    workspaceId:$workspaceId, region:$region, endpoint:$endpoint, onConflict:$onConflict,
    results:$results, renamedFlows:$renamedFlows, errors:$errors}' > "$REPORT"

created="$(printf '%s' "$results_json" | jq '[.[] | select(.action=="create")] | length')"
updated="$(printf '%s' "$results_json" | jq '[.[] | select(.action=="update")] | length')"
skipped="$(printf '%s' "$results_json" | jq '[.[] | select(.action=="skip")] | length')"
failed="$(printf '%s' "$results_json" | jq '[.[] | select(.action=="failed" or .action=="partial")] | length')"
err_count="$(printf '%s' "$errors_json" | jq 'length')"

echo "=============================================="
if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry-run 完成: 没有发出任何写请求"
  echo "请求体已写入: $PAYLOAD_DIR"
else
  echo "完成: 新建 ${created}，更新 ${updated}，跳过 ${skipped}，失败 $failed"
fi
echo "报告: $REPORT"
if [ "$err_count" -gt 0 ]; then
  echo "有 $err_count 个请求失败，详情见报告的 errors 字段"
fi
echo "=============================================="

[ "$failed" -eq 0 ] || exit 1
exit 0
