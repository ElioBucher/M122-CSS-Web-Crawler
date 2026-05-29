#!/usr/bin/env bash
set -uo pipefail

# ========== KONFIGURATION ==========
URL="https://www.css.ch"
OUTPUT_DIR="./crawl_output"
INDEX_FILE="$OUTPUT_DIR/index.json"
VISITED_FILE="$OUTPUT_DIR/visited.txt"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
SKIP_EXT="pdf,jpg,jpeg,png,gif,svg,css,js,ico,woff,woff2,ttf,zip,xml,json"

# ========== FARBEN ==========
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; NC='\033[0m'

# ========== HILFSFUNKTIONEN (wie im Original) ==========
normalize_url() {
    local url="${1%%#*}"
    [[ "$url" =~ ^https?://[^/]+/?$ ]] || url="${url%/}"
    echo "$url"
}

is_visited() {
    grep -qFx "$1" "$VISITED_FILE" 2>/dev/null
}

mark_visited() {
    echo "$1" >> "$VISITED_FILE"
}

is_allowed() {
    [[ "$1" =~ ^https?:// ]] || return 1
    # Erlaube ALLE URLs, die irgendwo "css.ch" enthalten
    [[ "$1" =~ css\.ch ]] || return 1
    # Blocke spezifische Pfade
    [[ "$1" =~ (content/css/|save_rating\.json|css-search\.json) ]] && return 1
    return 0
}

get_hash() {
    printf '%s' "$1" | sha256sum | awk '{print $1}'
}

# ========== LINK-EXTRAKTION (ORIGINAL-LOGIK) ==========
extract_links() {
    local url="$1"
    local html="$2"

    [[ -z "$html" ]] && return

    local host base
    host=$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1)
    base="https://${host}"

    # HTML in temporäre Datei
    local tmp_html=$(mktemp)
    printf '%s' "$html" > "$tmp_html"

    # Alle href-Attribute extrahieren (portabel, ohne grep -P)
    local raw_links
    raw_links=$(grep -o 'href="[^"]*"' "$tmp_html" 2>/dev/null | sed 's/href="//;s/"$//')
    raw_links+=$'\n'$(grep -o "href='[^']*'" "$tmp_html" 2>/dev/null | sed "s/href='//;s/'\(.*\)'/'\1/")
    raw_links+=$'\n'$(grep -o 'href=[^ "'\''>]*[^ "'\''> ]' "$tmp_html" 2>/dev/null | sed 's/href=//')
    rm -f "$tmp_html"
    [[ -z "$raw_links" ]] && return

    # Links in absolute URLs umwandeln
    local result=""
    while IFS= read -r link; do
        [[ -z "$link" ]] && continue

        local abs_link=""
        if [[ "$link" =~ ^https?:// ]]; then
            abs_link="$link"
        elif [[ "$link" =~ ^// ]]; then
            abs_link="https:${link}"
        elif [[ "$link" =~ ^/ ]]; then
            abs_link="${base}${link}"
        fi

        [[ -n "$abs_link" ]] && result="${result}"$'\n'"${abs_link}"
    done <<< "$raw_links"

    # Filter und Sortierung (wie im Original)
    echo "$result" | grep -E '^https?://' | grep -vE "\.($(echo "$SKIP_EXT" | tr ',' '|'))(\?.*)?$" | sort -u || true
}

# ========== CRAWLER ==========
do_crawl() {
    read -rp "Max. Seiten (Enter=unbegrenzt): " max_pages
    max_pages=${max_pages:-999999999}

    mkdir -p "$OUTPUT_DIR"
    : > "$VISITED_FILE"

    if [[ -f "$INDEX_FILE" ]]; then
        cp "$INDEX_FILE" "$OUTPUT_DIR/index_$(date +%Y-%m-%d_%H-%M-%S).json"
    fi
    echo '[' > "$INDEX_FILE"

    local queue=("$URL") first=1 count=0

    while [[ ${#queue[@]} -gt 0 && $count -lt $max_pages ]]; do
        local url="${queue[0]}"
        queue=("${queue[@]:1}")
        url=$(normalize_url "$url")

        [[ -z "$url" ]] && continue
        if is_visited "$url"; then continue; fi
        if ! is_allowed "$url"; then continue; fi

        mark_visited "$url"
        ((count++))

        local html
        html=$(curl -sL --max-time 30 -A "$USER_AGENT" "$url" 2>/dev/null) || html=""
        local hash=$(get_hash "$html")
        local ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

        [[ $first -eq 1 ]] && first=0 || printf ',\n' >> "$INDEX_FILE"
        printf '  {"url": "%s", "hash": "%s", "crawled_at": "%s"}' "$url" "$hash" "$ts" >> "$INDEX_FILE"

        # ALLE Links in Queue
        while IFS= read -r link; do
            [[ -z "$link" ]] && continue
            link=$(normalize_url "$link")
            if is_allowed "$link"; then
                queue+=("$link")
            fi
        done < <(extract_links "$url" "$html")
    done

    printf '\n]\n' >> "$INDEX_FILE"
}

# ========== INDEX ANZEIGEN ==========
do_show_index() {
    [[ ! -f "$INDEX_FILE" ]] && { echo "Kein Index. Zuerst crawlen!"; return; }
    local cnt=$(grep -c '"url"' "$INDEX_FILE" 2>/dev/null || echo 0)
    echo "Aktueller Index ($cnt Seiten):"
    grep '"url"' "$INDEX_FILE" | sed 's/.*"url": "\(.*\)".*/  \1/'
}

# ========== DIFF ==========
do_diff() {
    local old_file="$1" new_file="$2"
    [[ ! -f "$old_file" ]] && { echo "Fehler: $old_file nicht gefunden"; return; }
    [[ ! -f "$new_file" ]] && { echo "Fehler: $new_file nicht gefunden"; return; }
    echo -e "\n  Vergleich: $(basename "$old_file") vs $(basename "$new_file")\n"
    local tmp_old=$(mktemp) tmp_new=$(mktemp)
    grep -o '"url": "[^"]*"' "$old_file" | sed 's/.*"url": "\([^"]*\)".*/\1/' | sort > "$tmp_old"
    grep -o '"url": "[^"]*"' "$new_file" | sed 's/.*"url": "\([^"]*\)".*/\1/' | sort > "$tmp_new"
    echo -e "${G}NEU:${NC}"
    comm -13 "$tmp_old" "$tmp_new" | sed 's/^/  + /' || echo "  (keine)"
    echo -e "\n${R}GELÖSCHT:${NC}"
    comm -23 "$tmp_old" "$tmp_new" | sed 's/^/  - /' || echo "  (keine)"
    echo -e "\n${Y}GEÄNDERT:${NC}"
    comm -12 "$tmp_old" "$tmp_new" | while read -r url; do
        local old_hash new_hash
        old_hash=$(grep -A1 "\"url\": \"$url\"" "$old_file" | grep '"hash"' | cut -d'"' -f4)
        new_hash=$(grep -A1 "\"url\": \"$url\"" "$new_file" | grep '"hash"' | cut -d'"' -f4)
        [[ "$old_hash" != "$new_hash" ]] && echo "  ~ $url (alt: ${old_hash:0:16}... neu: ${new_hash:0:16}...)"
    done || echo "  (keine)"
    rm -f "$tmp_old" "$tmp_new"
}

do_diff_menu() {
    local files=("$OUTPUT_DIR"/index_*.json)
    [[ ! -f "${files[0]}" ]] && { echo "Keine alten Indexe gefunden!"; return; }
    echo "Verfuegbare Indexe:"
    for i in "${!files[@]}"; do
        echo "  $((i+1))) $(basename "${files[i]}")"
    done
    read -rp "Alter Index (Nr): " a
    read -rp "Neuer Index (Nr, Enter=aktuell): " b
    do_diff "${files[a-1]}" "${b:-$INDEX_FILE}"
}

# ========== MENÜ ==========
show_menu() {
    echo -e "\nCSS.ch Web Crawler\n==================\n  1) Crawl\n  2) Diff\n  3) Index anzeigen\n  4) Beenden\n"
}

main() {
    while true; do
        show_menu
        read -rp "Wahl: " choice
        case "$choice" in
            1) do_crawl ;;
            2) do_diff_menu ;;
            3) do_show_index ;;
            4) exit 0 ;;
            *) echo -e "${R}Ungueltig! 1-4 waehlen.${NC}" ;;
        esac
    done
}

main
