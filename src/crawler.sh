#!/usr/bin/env bash
# CSS.ch Web Crawler — crawl, hash, loop-detect, diff runs, interactive menu.
set -o pipefail

# --- Config ---
readonly START_URL="https://www.css.ch"
readonly DOMAIN="css.ch"
readonly OUT_DIR="./crawl_output"
readonly INDEX_FILE="${OUT_DIR}/index.json"
readonly VISITED_FILE="${OUT_DIR}/visited.txt"
readonly QUEUE_FILE="${OUT_DIR}/queue.txt"
readonly USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
readonly DEFAULT_SKIP="pdf,jpg,jpeg,png,gif,svg,css,js,ico,woff,woff2,ttf,zip,xml,json"
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m' CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'

# --- Logging ---
log()      { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# --- State ---
declare -A VISITED_SET=() QUEUE_SET=()
declare -A OLD_HASHES=() NEW_HASHES=()

# --- URL helpers ---
# Strip fragment and trailing slash (keep it on a bare domain).
normalize_url() {
    local url="${1%%#*}"
    [[ "$url" =~ ^https?://[^/]+/?$ ]] || url="${url%/}"
    echo "$url"
}

is_visited()  { [[ -n "${VISITED_SET[$1]+x}" ]]; }
mark_visited(){ VISITED_SET["$1"]=1; echo "$1" >> "$VISITED_FILE"; }

# Valid = unseen, http(s), on css.ch, not robots-disallowed.
is_valid_url() {
    local url="$1" host
    is_visited "$url" && return 1
    [[ "$url" =~ ^https?:// ]] || return 1
    host=$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1 | cut -d'?' -f1)
    [[ "$host" == "$DOMAIN" || "$host" == *".$DOMAIN" ]] || return 1
    case "$url" in
        */content/css/*|*.save_rating.json|*.css-search.json) return 1 ;;
    esac
    return 0
}

# Resolve a (possibly relative) link to an absolute URL, preserving the page
# scheme and collapsing ./ and ../ ; prints nothing for non-http(s) schemes.
_resolve_link() {
    local link="$1" scheme="$2" origin="$3" dir_base="$4" abs qs="" after
    [[ "$link" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*: && ! "$link" =~ ^https?:// ]] && return 0
    if   [[ "$link" =~ ^https?:// ]]; then abs="$link"
    elif [[ "$link" =~ ^//        ]]; then abs="${scheme}:${link}"
    elif [[ "$link" =~ ^/         ]]; then abs="${origin}${link}"
    else                                   abs="${dir_base}${link}"
    fi
    case "$abs" in *\?*) qs="?${abs#*\?}"; abs="${abs%%\?*}" ;; esac
    after="${abs#*://}"
    local scheme_part="${abs%%://*}" host_part="${after%%/*}" path=""
    [[ "$after" == *"/"* ]] && path="/${after#*/}"
    if [[ -n "$path" ]]; then
        local IFS='/' s; local -a seg=() out=()
        read -ra seg <<< "$path"
        for s in "${seg[@]}"; do
            case "$s" in
                ""|".") ;;
                "..") [[ ${#out[@]} -gt 0 ]] && unset 'out[${#out[@]}-1]' ;;
                *) out+=("$s") ;;
            esac
        done
        [[ ${#out[@]} -gt 0 ]] && path="/${out[*]}" || path="/"
    fi
    echo "${scheme_part}://${host_part}${path}${qs}"
}

# Extract absolute, on-scope links from HTML ($1 url, $2 html, $3 skip-types).
extract_links() {
    local url="$1" html="$2" skip_types="$3"
    [[ -z "$html" ]] && return 0

    local scheme host origin dir_base after path
    scheme=$(echo "$url" | grep -oE '^https?'); [[ -z "$scheme" ]] && scheme="https"
    host=$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1)
    origin="${scheme}://${host}"
    after="${url#*://}"; [[ "$after" == *"/"* ]] && path="${after#*/}" || path=""
    [[ "$path" == *"/"* ]] && dir_base="${origin}/${path%/*}/" || dir_base="${origin}/"

    local raw_links result="" link abs
    raw_links=$(printf '%s' "$html" | grep -oP '(?<=href=")[^"]+|(?<=href='"'"')[^'"'"']+' 2>/dev/null) || return 0
    while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        abs=$(_resolve_link "$link" "$scheme" "$origin" "$dir_base")
        [[ -n "$abs" ]] && result+="${abs}"$'\n'
    done <<< "$raw_links"

    echo "$result" | grep -E '^https?://' \
        | grep -vE "\.($(echo "$skip_types" | tr ',' '|'))(\?.*)?$" | sort -u || true
}

get_page_hash() { echo "$1" | sha256sum | awk '{print $1}'; }

# Unique snapshot name (second precision + counter) so runs never overwrite.
make_snapshot_path() {
    local ts n=1 candidate
    ts=$(date '+%Y%m%d_%H%M%S'); candidate="${OUT_DIR}/crawl_${ts}.json"
    while [[ -e "$candidate" ]]; do candidate="${OUT_DIR}/crawl_${ts}_${n}.json"; n=$((n+1)); done
    echo "$candidate"
}

# --- Crawl ---
do_crawl() {
    VISITED_SET=(); QUEUE_SET=()

    read -rp "Max. pages to crawl (Enter = unlimited): " num_of_pages
    num_of_pages="${num_of_pages:-999999999}"
    [[ "$num_of_pages" =~ ^[0-9]+$ ]] || { log_warn "Not a valid number — using unlimited."; num_of_pages=999999999; }

    echo ""; echo "File types to skip (comma-separated):"; echo "Default: $DEFAULT_SKIP"
    read -rp "Custom list (Enter = default): " skip_types
    skip_types="${skip_types:-$DEFAULT_SKIP}"

    mkdir -p "$OUT_DIR"
    # Newest existing crawl = previous run, used for the auto-diff at the end.
    local prev_snapshot
    prev_snapshot=$(ls -t "${OUT_DIR}"/crawl_*.json 2>/dev/null | head -1) || prev_snapshot=""

    : > "$VISITED_FILE"; : > "$QUEUE_FILE"; echo "[" > "$INDEX_FILE"
    echo "$START_URL" > "$QUEUE_FILE"; QUEUE_SET["$START_URL"]=1

    log "Starting crawl: $START_URL"
    log "Max. pages: $num_of_pages | Skip types: $skip_types"

    local page_count=0 queue_pos=0 first_entry=true
    while [[ $page_count -lt $num_of_pages ]]; do
        queue_pos=$((queue_pos+1))
        local current_url
        current_url=$(sed -n "${queue_pos}p" "$QUEUE_FILE" 2>/dev/null) || true
        [[ -z "$current_url" ]] && break                       # queue empty
        current_url=$(normalize_url "$current_url")
        is_valid_url "$current_url" || { log_warn "Skipped: $current_url"; continue; }

        mark_visited "$current_url"; page_count=$((page_count+1))
        log "[$page_count/$num_of_pages] Crawling: $current_url"

        local page_html page_hash timestamp
        page_html=$(curl -sL --max-time 20 --user-agent "$USER_AGENT" "$current_url" 2>/dev/null) || page_html=""
        page_hash=$(get_page_hash "$page_html")
        timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

        [[ "$first_entry" == true ]] && first_entry=false || printf ',\n' >> "$INDEX_FILE"
        printf '  {\n    "url": "%s",\n    "hash": "%s",\n    "crawled_at": "%s"\n  }' \
            "$current_url" "$page_hash" "$timestamp" >> "$INDEX_FILE"
        log_ok "Hash: ${page_hash:0:16}..."

        local new_links added=0 link
        new_links=$(extract_links "$current_url" "$page_html" "$skip_types") || new_links=""
        while IFS= read -r link; do
            [[ -z "$link" ]] && continue
            link=$(normalize_url "$link")
            if is_valid_url "$link" && [[ -z "${QUEUE_SET[$link]+x}" ]]; then
                QUEUE_SET["$link"]=1; echo "$link" >> "$QUEUE_FILE"; added=$((added+1))
            fi
        done <<< "$new_links"
        log "  → $added new links added to queue"
    done

    printf '\n]\n' >> "$INDEX_FILE"

    # Archive under a unique name so every crawl stays available to compare.
    local snapshot=""
    if [[ $page_count -gt 0 ]]; then snapshot=$(make_snapshot_path); cp "$INDEX_FILE" "$snapshot"; fi

    log "================================"
    log_ok "Crawl finished! Pages visited: $page_count"
    log_ok "Index: $INDEX_FILE"
    [[ -n "$snapshot" ]] && log_ok "Archived: $(basename "$snapshot")"
    log "================================"

    if [[ -n "$prev_snapshot" && -n "$snapshot" ]]; then
        echo ""; echo -e "${BLUE}Creating diff to previous crawl...${NC}"
        compare_crawl_files "$prev_snapshot" "$snapshot"
    fi
}

# --- Diff ---
_extract_urls() { grep -oP '"url":\s*"\K[^"]+' "$1" | sort; }

# Load url->hash pairs from $1 into the assoc array named $2 (parsed once).
_load_hashes() {
    local file="$1"; local -n _map="$2"; _map=(); local u h
    while IFS=$'\t' read -r u h; do [[ -n "$u" ]] && _map["$u"]="$h"; done < <(python3 -c '
import json, sys
try:
    for e in json.load(open(sys.argv[1])):
        print("{}\t{}".format(e.get("url",""), e.get("hash","")))
except Exception:
    pass
' "$file" 2>/dev/null)
}

_count() { [[ -z "$1" ]] && { echo 0; return; }; grep -c . <<< "$1"; }

# Print a NEW/REMOVED section: $1 color, $2 symbol, $3 title, $4 url list.
_print_section() {
    echo -e "${BOLD}$1$3${NC}"
    if [[ -n "$4" ]]; then
        local u; while IFS= read -r u; do echo -e "  $1$2${NC} $u"; done <<< "$4"
    else
        echo -e "  (none)"
    fi
    echo ""
}

compare_crawl_files() {
    local old_index="$1" new_index="$2"
    [[ -f "$old_index" ]] || { echo -e "${RED}Error: $old_index not found${NC}"; return; }
    [[ -f "$new_index" ]] || { echo -e "${RED}Error: $new_index not found${NC}"; return; }

    local tmp_old tmp_new; tmp_old=$(mktemp); tmp_new=$(mktemp)
    _extract_urls "$old_index" > "$tmp_old"; _extract_urls "$new_index" > "$tmp_new"

    local new_urls deleted_urls common_urls
    new_urls=$(comm -13 "$tmp_old" "$tmp_new")
    deleted_urls=$(comm -23 "$tmp_old" "$tmp_new")
    common_urls=$(comm -12 "$tmp_old" "$tmp_new")

    _load_hashes "$old_index" OLD_HASHES; _load_hashes "$new_index" NEW_HASHES

    echo ""
    echo -e "  ${BLUE}Old:${NC} $(basename "$old_index")"
    echo -e "  ${BLUE}New:${NC} $(basename "$new_index")"
    echo ""

    _print_section "$GREEN" "+" "▶ NEW Pages:"     "$new_urls"
    _print_section "$RED"   "-" "▶ REMOVED Pages:" "$deleted_urls"

    echo -e "${BOLD}${YELLOW}▶ CHANGED Pages:${NC}"
    local changed_count=0 unchanged_count=0 url
    if [[ -n "$common_urls" ]]; then
        while IFS= read -r url; do
            if [[ "${OLD_HASHES[$url]}" != "${NEW_HASHES[$url]}" ]]; then
                echo -e "  ${YELLOW}~${NC} $url"
                echo -e "      old: ${OLD_HASHES[$url]:0:16}..."
                echo -e "      new: ${NEW_HASHES[$url]:0:16}..."
                changed_count=$((changed_count+1))
            else
                unchanged_count=$((unchanged_count+1))
            fi
        done <<< "$common_urls"
    fi
    [[ $changed_count -eq 0 ]] && echo -e "  (none)"
    echo ""

    local total_old total_new
    total_old=$(wc -l < "$tmp_old"); total_new=$(wc -l < "$tmp_new")
    rm -f "$tmp_old" "$tmp_new"

    echo -e "${BOLD}${CYAN}Summary${NC}"
    echo -e "  Pages (old):      $total_old"
    echo -e "  Pages (new):      $total_new"
    echo -e "  ${GREEN}New:${NC}              $(_count "$new_urls")"
    echo -e "  ${RED}Removed:${NC}          $(_count "$deleted_urls")"
    echo -e "  ${YELLOW}Changed:${NC}          $changed_count"
    echo -e "  Unchanged:        $unchanged_count"
    echo ""
}

# crawl_YYYYmmdd_HHMMSS[_n] -> "DD.MM.YYYY HH:MM:SS" (raw name otherwise).
_format_crawl_label() {
    local body="${1#crawl_}"
    if [[ "$body" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2}) ]]; then
        echo "${BASH_REMATCH[3]}.${BASH_REMATCH[2]}.${BASH_REMATCH[1]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
    else echo "$1"; fi
}

# Prompt for a crawl number from $2 (the archive list); sets REPLY_FILE.
_pick_crawl() {
    local num; read -rp "$1" num
    [[ "$num" =~ ^[0-9]+$ ]] || { echo -e "${RED}Please enter a number.${NC}"; return 1; }
    REPLY_FILE=$(echo "$2" | sed -n "${num}p")
    [[ -n "$REPLY_FILE" && -f "$REPLY_FILE" ]] || { echo -e "${RED}Selected crawl does not exist.${NC}"; return 1; }
}

compare_crawl() {
    local archives; archives=$(ls -t "${OUT_DIR}"/crawl_*.json 2>/dev/null) || archives=""
    [[ -z "$archives" ]] && { echo -e "${YELLOW}No crawls found. Run a crawl first.${NC}"; return; }
    [[ $(_count "$archives") -lt 2 ]] && { echo -e "${YELLOW}Only one crawl available. Run at least two crawls to compare.${NC}"; return; }

    echo "Available crawls (newest first):"
    local i=1 f
    while IFS= read -r f; do echo "  $i) $(_format_crawl_label "$(basename "$f" .json)")"; i=$((i+1)); done <<< "$archives"

    local a_file b_file REPLY_FILE
    _pick_crawl "First crawl number: "  "$archives" || return; a_file="$REPLY_FILE"
    _pick_crawl "Second crawl number: " "$archives" || return; b_file="$REPLY_FILE"
    [[ "$a_file" == "$b_file" ]] && { echo -e "${YELLOW}Both selections are the same crawl — nothing to compare.${NC}"; return; }

    compare_crawl_files "$a_file" "$b_file"
}

# --- View ---
view_crawl() {
    [[ -f "$INDEX_FILE" ]] || { echo -e "${YELLOW}No crawl result found. Run a crawl first.${NC}"; return; }
    local n; n=$(grep -c '"url"' "$INDEX_FILE" 2>/dev/null) || n=0
    echo -e "${GREEN}Result has $n pages${NC}"; echo ""
    grep '"url"' "$INDEX_FILE" | sed 's/.*"url": "\(.*\)".*/  \1/'
}

# --- Menu ---
main() {
    while true; do
        echo ""; echo "CSS.ch Web Crawler"; echo "=================="; echo ""
        echo "  1) Start crawl"; echo "  2) Compare crawls"; echo "  3) Show crawl"; echo "  4) Exit"; echo ""
        read -rp "Choice: " choice
        case "$choice" in
            1) do_crawl ;;
            2) compare_crawl ;;
            3) view_crawl ;;
            4) echo "Goodbye!"; exit 0 ;;
            *) echo -e "${RED}Invalid input. Please choose 1-4.${NC}" ;;
        esac
    done
}

main