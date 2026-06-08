#!/usr/bin/env bash

# CSS.ch Web Crawler
# Crawls css.ch, detects loops, stores hashes,
# compares runs (diff) and provides an interactive menu.

set -o pipefail

# CONFIGURATION

readonly START_URL="https://www.css.ch"
readonly DOMAIN="css.ch"
readonly OUT_DIR="./crawl_output"
readonly INDEX_FILE="${OUT_DIR}/index.json"
readonly VISITED_FILE="${OUT_DIR}/visited.txt"
readonly QUEUE_FILE="${OUT_DIR}/queue.txt"
readonly USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
readonly DEFAULT_SKIP="pdf,jpg,jpeg,png,gif,svg,css,js,ico,woff,woff2,ttf,zip,xml,json"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# LOGGING

log()      { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# IN-MEMORY DATA STRUCTURES

declare -A VISITED_SET=()
declare -A QUEUE_SET=()

# HELPER FUNCTIONS

# Normalize URL: remove fragment (#...) and trailing slash
normalize_url() {
    local url="${1%%#*}"
    [[ "$url" =~ ^https?://[^/]+/?$ ]] || url="${url%/}"
    echo "$url"
}

# Check if URL has already been visited
is_visited() {
    [[ -n "${VISITED_SET[$1]+x}" ]]
}

# Mark URL as visited (array + file for persistence)
mark_visited() {
    VISITED_SET["$1"]=1
    echo "$1" >> "$VISITED_FILE"
}

# Validate URL: check domain and robots.txt disallow rules
is_valid_url() {
    local url="$1"

    # URL already visited?
    is_visited "$url" && return 1

    # Must be http(s)
    [[ "$url" =~ ^https?:// ]] || return 1

    local host
    host=$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1 | cut -d'?' -f1)

    # Must be css.ch domain
    [[ "$host" == "$DOMAIN" || "$host" == *".$DOMAIN" ]] || return 1

    # robots.txt disallow rules
    [[ "$url" == */content/css/* ]]    && return 1
    [[ "$url" == *.save_rating.json ]] && return 1
    [[ "$url" == *.css-search.json ]]  && return 1

    return 0
}

# Extract all absolute links from HTML
# $1: current URL (for base URL)
# $2: HTML content
# $3: file types to skip (comma-separated)
extract_links() {
    local url="$1"
    local html="$2"
    local skip_types="$3"

    [[ -z "$html" ]] && return 0

    local host base
    host=$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1)
    base="https://${host}"

    # Write HTML to temp file (avoids "Argument list too long")
    local tmp_html
    tmp_html=$(mktemp)
    printf '%s' "$html" > "$tmp_html"

    # Extract all href attributes
    local raw_links
    raw_links=$(grep -oP '(?<=href=")[^"]+|(?<=href='"'"')[^'"'"']+' "$tmp_html" 2>/dev/null) || raw_links=""
    rm -f "$tmp_html"

    [[ -z "$raw_links" ]] && return 0

    # Convert links to absolute URLs
    local result=""
    while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        local abs_link=""
        if   [[ "$link" =~ ^https?:// ]]; then abs_link="$link"
        elif [[ "$link" =~ ^//        ]]; then abs_link="https:${link}"
        elif [[ "$link" =~ ^/         ]]; then abs_link="${base}${link}"
        fi
        [[ -n "$abs_link" ]] && result="${result}"$'\n'"${abs_link}"
    done <<< "$raw_links"

    # Filter and sort
    echo "$result" \
        | grep -E '^https?://' \
        | grep -vE "\.($(echo "$skip_types" | tr ',' '|'))(\?.*)?$" \
        | sort -u \
        || true
}

# Calculate SHA256 hash from HTML content
get_page_hash() {
    echo "$1" | sha256sum | awk '{print $1}'
}

# DO_CRAWL

do_crawl() {
    # Reset in-memory sets for fresh crawl
    VISITED_SET=()
    QUEUE_SET=()

    # User input: max pages
    read -rp "Max. pages to crawl (Enter = unlimited): " num_of_pages
    num_of_pages="${num_of_pages:-999999999}"

    echo ""
    echo "File types to skip (comma-separated):"
    echo "Default: $DEFAULT_SKIP"
    read -rp "Custom list (Enter = default): " skip_types
    skip_types="${skip_types:-$DEFAULT_SKIP}"

    # Setup
    mkdir -p "$OUT_DIR"

    # Back up previous index
    local prev_index=""
    if [[ -f "$INDEX_FILE" ]]; then
        local ts
        ts=$(date '+%M_%H_%d_%m_%Y')
        prev_index="${OUT_DIR}/crawl_${ts}.json"
        cp "$INDEX_FILE" "$prev_index"
        echo -e "${BLUE}Previous index saved: crawl_${ts}.json${NC}"
    fi

    # Initialize files
    : > "$VISITED_FILE"
    : > "$QUEUE_FILE"
    echo "[" > "$INDEX_FILE"

    # Add start URL to queue
    echo "$START_URL" > "$QUEUE_FILE"
    QUEUE_SET["$START_URL"]=1

    log "Starting crawl: $START_URL"
    log "Max. pages: $num_of_pages | Skip types: $skip_types"

    local page_count=0
    local queue_pos=0
    local first_entry=true

    # Main crawl loop
    while [[ $page_count -lt $num_of_pages ]]; do

        # Next URL from queue
        queue_pos=$((queue_pos + 1))
        local current_url
        current_url=$(sed -n "${queue_pos}p" "$QUEUE_FILE" 2>/dev/null) || true
        [[ -z "$current_url" ]] && break   # Queue empty → finalize

        # Normalize URL
        current_url=$(normalize_url "$current_url")

        # Validate URL (loop detection + domain check)
        if ! is_valid_url "$current_url"; then
            log_warn "Skipped: $current_url"
            continue
        fi

        # Mark as visited
        mark_visited "$current_url"
        page_count=$((page_count + 1))
        log "[$page_count/$num_of_pages] Crawling: $current_url"

        # Download HTML
        local page_html
        page_html=$(curl -sL --max-time 20 --user-agent "$USER_AGENT" "$current_url" 2>/dev/null) || page_html=""

        # Get hash and timestamp
        local page_hash timestamp
        page_hash=$(get_page_hash "$page_html")
        timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

        # Write entry to index
        if [[ "$first_entry" == true ]]; then
            first_entry=false
        else
            printf ',\n' >> "$INDEX_FILE"
        fi
        printf '  {\n    "url": "%s",\n    "hash": "%s",\n    "crawled_at": "%s"\n  }' \
            "$current_url" "$page_hash" "$timestamp" >> "$INDEX_FILE"

        log_ok "Hash: ${page_hash:0:16}..."

        # Extract links and add to queue
        local new_links added=0
        new_links=$(extract_links "$current_url" "$page_html" "$skip_types") || new_links=""

        if [[ -n "$new_links" ]]; then
            while IFS= read -r link; do
                [[ -z "$link" ]] && continue
                link=$(normalize_url "$link")
                if is_valid_url "$link" && [[ -z "${QUEUE_SET[$link]+x}" ]]; then
                    QUEUE_SET["$link"]=1
                    echo "$link" >> "$QUEUE_FILE"
                    added=$((added + 1))
                fi
            done <<< "$new_links"
        fi
        log "  → $added new links added to queue"
    done

    # Finalize index file
    printf '\n]\n' >> "$INDEX_FILE"

    log "================================"
    log_ok "Crawl finished!"
    log_ok "Pages visited: $page_count"
    log_ok "Index: $INDEX_FILE"
    log "================================"

    # Auto-diff if previous index exists
    if [[ -n "$prev_index" ]]; then
        echo ""
        echo -e "${BLUE}Creating diff to previous crawl...${NC}"
        compare_crawl_files "$prev_index" "$INDEX_FILE"
    fi
}

# COMPARE_CRAWL (DIFF)

_extract_urls() {
    grep -oP '"url":\s*"\K[^"]+' "$1" | sort
}

_get_hash() {
    local index_file="$1"
    local target_url="$2"
    python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for entry in data:
        if entry.get('url') == sys.argv[2]:
            print(entry.get('hash', ''))
            sys.exit(0)
except:
    pass
print('')
" "$index_file" "$target_url" 2>/dev/null || echo ""
}

compare_crawl_files() {
    local old_index="$1"
    local new_index="$2"

    [[ ! -f "$old_index" ]] && { echo -e "${RED}Error: $old_index not found${NC}"; return; }
    [[ ! -f "$new_index" ]] && { echo -e "${RED}Error: $new_index not found${NC}"; return; }

    local tmp_old tmp_new
    tmp_old=$(mktemp)
    tmp_new=$(mktemp)

    # Read all URLs from both indexes
    _extract_urls "$old_index" > "$tmp_old"
    _extract_urls "$new_index" > "$tmp_new"

    # Find new, removed and common URLs
    local new_urls deleted_urls common_urls
    new_urls=$(comm -13 "$tmp_old" "$tmp_new")   || new_urls=""
    deleted_urls=$(comm -23 "$tmp_old" "$tmp_new") || deleted_urls=""
    common_urls=$(comm -12 "$tmp_old" "$tmp_new")  || common_urls=""

    echo ""
    echo -e "  ${BLUE}Old:${NC} $(basename "$old_index")"
    echo -e "  ${BLUE}New:${NC} $(basename "$new_index")"
    echo ""

    # New pages
    echo -e "${BOLD}${GREEN}▶ NEW Pages:${NC}"
    local new_count=0
    if [[ -n "$new_urls" ]]; then
        while IFS= read -r url; do
            echo -e "  ${GREEN}+${NC} $url"
            new_count=$((new_count + 1))
        done <<< "$new_urls"
    else
        echo -e "  (none)"
    fi
    echo ""

    # Removed pages
    echo -e "${BOLD}${RED}▶ REMOVED Pages:${NC}"
    local deleted_count=0
    if [[ -n "$deleted_urls" ]]; then
        while IFS= read -r url; do
            echo -e "  ${RED}-${NC} $url"
            deleted_count=$((deleted_count + 1))
        done <<< "$deleted_urls"
    else
        echo -e "  (none)"
    fi
    echo ""

    # Changed pages
    echo -e "${BOLD}${YELLOW}▶ CHANGED Pages:${NC}"
    local changed_count=0 unchanged_count=0
    if [[ -n "$common_urls" ]]; then
        while IFS= read -r url; do
            local old_hash new_hash
            old_hash=$(_get_hash "$old_index" "$url")
            new_hash=$(_get_hash "$new_index" "$url")
            if [[ "$old_hash" != "$new_hash" ]]; then
                echo -e "  ${YELLOW}~${NC} $url"
                echo -e "      old: ${old_hash:0:16}..."
                echo -e "      new: ${new_hash:0:16}..."
                changed_count=$((changed_count + 1))
            else
                unchanged_count=$((unchanged_count + 1))
            fi
        done <<< "$common_urls"
    fi
    [[ $changed_count -eq 0 ]] && echo -e "  (none)"
    echo ""

    # Summary
    local total_old total_new
    total_old=$(wc -l < "$tmp_old")
    total_new=$(wc -l < "$tmp_new")

    rm -f "$tmp_old" "$tmp_new"

    echo -e "${BOLD}${CYAN}Summary${NC}"
    echo -e "  Pages (old):      $total_old"
    echo -e "  Pages (new):      $total_new"
    echo -e "  ${GREEN}New:${NC}              $new_count"
    echo -e "  ${RED}Removed:${NC}          $deleted_count"
    echo -e "  ${YELLOW}Changed:${NC}          $changed_count"
    echo -e "  Unchanged:        $unchanged_count"
    echo ""
}

compare_crawl() {
    local archives
    archives=$(ls -t "${OUT_DIR}"/crawl_*.json 2>/dev/null) || archives=""

    if [[ -z "$archives" ]]; then
        echo -e "${YELLOW}No archived indexes found. Run at least two crawls first.${NC}"
        return
    fi

    # List available indexes
    echo "Available crawls:"
    local i=1
    while IFS= read -r f; do
        local name
        name=$(basename "$f" .json)
        # Parse: crawl_MM_HH_DD_MM_YYYY
        local min hour day month year
        min=$(echo "$name"   | cut -d'_' -f2)
        hour=$(echo "$name"  | cut -d'_' -f3)
        day=$(echo "$name"   | cut -d'_' -f4)
        month=$(echo "$name" | cut -d'_' -f5)
        year=$(echo "$name"  | cut -d'_' -f6)
        echo "  $i) ${day}.${month}.${year} ${hour}:${min}"
        i=$((i + 1))
    done <<< "$archives"

    # Select first index
    read -rp "First (older) crawl number: " a_num
    local a_file
    a_file=$(echo "$archives" | sed -n "${a_num}p") || a_file=""
    if [[ -z "$a_file" || ! -f "$a_file" ]]; then
        echo -e "${RED}Selected crawl does not exist.${NC}"
        return
    fi

    # Select second index
    read -rp "Second crawl number (Enter = current index): " b_num
    local b_file="$INDEX_FILE"
    if [[ -n "$b_num" ]]; then
        b_file=$(echo "$archives" | sed -n "${b_num}p") || b_file=""
        if [[ -z "$b_file" || ! -f "$b_file" ]]; then
            echo -e "${RED}Selected crawl does not exist.${NC}"
            return
        fi
    fi

    compare_crawl_files "$a_file" "$b_file"
}

# VIEW_CRAWL

view_crawl() {
    if [[ ! -f "$INDEX_FILE" ]]; then
        echo -e "${YELLOW}No crawl result found. Run a crawl first.${NC}"
        return
    fi

    local urls_count
    urls_count=$(grep -c '"url"' "$INDEX_FILE" 2>/dev/null) || urls_count=0

    echo -e "${GREEN}Result has $urls_count pages${NC}"
    echo ""
    grep '"url"' "$INDEX_FILE" | sed 's/.*"url": "\(.*\)".*/  \1/'
}

# PRINT_MENU / MAIN

print_menu() {
    echo ""
    echo "CSS.ch Web Crawler"
    echo "=================="
    echo ""
    echo "  1) Start crawl"
    echo "  2) Compare crawls"
    echo "  3) Show crawl"
    echo "  4) Exit"
    echo ""
}

main() {
    while true; do
        print_menu
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