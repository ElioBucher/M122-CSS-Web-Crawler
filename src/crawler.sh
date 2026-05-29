#!/usr/bin/env bash
# ============================================================
# CSS.ch Web Crawler
# Crawlt css.ch, erkennt Schleifen, speichert Hashes,
# vergleicht Runs (Diff) und bietet ein interaktives Menü.
# ============================================================

set -euo pipefail

# ============================================================
# KONFIGURATION
# ============================================================

readonly FIXED_URL="https://www.css.ch"
readonly DOMAIN_FILTER="css.ch"
readonly OUTPUT_DIR="./crawl_output"
readonly INDEX_FILE="${OUTPUT_DIR}/index.json"
readonly VISITED_FILE="${OUTPUT_DIR}/visited.txt"
readonly QUEUE_FILE="${OUTPUT_DIR}/queue.txt"
readonly LOG_FILE="${OUTPUT_DIR}/crawl.log"
readonly USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
readonly DEFAULT_SKIP="pdf,jpg,jpeg,png,gif,svg,css,js,ico,woff,woff2,ttf,zip,xml,json

"

# ============================================================
# FARBEN
# ============================================================

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ============================================================
# LOGGING
# ============================================================

log()      { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# ============================================================
# IN-MEMORY DATENSTRUKTUREN
# ============================================================

declare -A VISITED_SET
declare -A QUEUE_SET

# ============================================================
# HILFSFUNKTIONEN
# ============================================================

# Normalisiert URL: entfernt Fragment (#...) und trailing slash
normalize_url() {
    local url="${1%%#*}"
    [[ "$url" =~ ^https?://[^/]+/?$ ]] || url="${url%/}"
    echo "$url"
}

# Prüft ob URL bereits besucht wurde
is_visited() {
    [[ -n "${VISITED_SET[$1]+x}" ]]
}

# Markiert URL als besucht (Array + Datei für Persistenz)
mark_visited() {
    VISITED_SET["$1"]=1
    echo "$1" >> "$VISITED_FILE"
}

# Prüft ob URL zur erlaubten Domain gehört
is_allowed_domain() {
    local url="$1"
    [[ "$url" =~ ^https?:// ]] || return 1

    local host
    host=$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1 | cut -d'?' -f1)

    # Domain-Check
    [[ "$host" == "css.ch" || "$host" == *".css.ch" ]] || return 1

    # robots.txt Disallow-Regeln
    [[ "$url" == */content/css/* ]] && return 1
    [[ "$url" == *.save_rating.json ]] && return 1
    [[ "$url" == *.css-search.json ]] && return 1

    return 0
}

# Extrahiert alle absoluten Links aus HTML
# $1: aktuelle URL (für Basis-URL)
# $2: HTML-Inhalt
# $3: zu überspringende Dateitypen (kommagetrennt)
extract_links() {
    local url="$1"
    local html="$2"
    local skip_types="$3"

    [[ -z "$html" ]] && return 0

    local host base
    host=$(echo "$url" | sed 's|^https\?://||' | cut -d'/' -f1)
    base="https://${host}"

    # HTML in temporäre Datei schreiben (verhindert "Argument list too long")
    local tmp_html
    tmp_html=$(mktemp)
    printf '%s' "$html" > "$tmp_html"
    trap 'rm -f "$tmp_html"' RETURN

    # Alle href-Attribute extrahieren
    local raw_links
    raw_links=$(grep -oP '(?<=href=")[^"]+|(?<=href="'\'')[^'\'']+' "$tmp_html" 2>/dev/null) || raw_links=""
    [[ -z "$raw_links" ]] && return 0

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

    # Filter und Sortierung
    echo "$result" \
        | grep -E '^https?://' \
        | grep -vE "\.($(echo "$skip_types" | tr ',' '|'))(\?.*)?$" \
        | sort -u \
        || true
}

# Berechnet SHA256-Hash aus HTML-Inhalt
get_page_hash() {
    echo "$1" | sha256sum | awk '{print $1}'
}

# ============================================================
# CRAWLER
# ============================================================

do_crawl() {
    # Benutzereingaben
    read -rp "Max. Seiten (Enter = unbegrenzt): " max_pages
    max_pages="${max_pages:-999999999}"

    echo ""
    echo "Dateitypen die NICHT gecrawlt werden (kommagetrennt):"
    echo "Standard: $DEFAULT_SKIP"
    read -rp "Eigene Liste (Enter = Standard): " skip_types
    skip_types="${skip_types:-$DEFAULT_SKIP}"

    # Vorbereitung
    mkdir -p "$OUTPUT_DIR"

    # Vorherigen Index sichern
    local prev_index=""
    if [[ -f "$INDEX_FILE" ]]; then
        local ts
        ts=$(date '+%Y-%m-%d_%H-%M-%S')
        prev_index="${OUTPUT_DIR}/index_${ts}.json"
        cp "$INDEX_FILE" "$prev_index"
        echo -e "${BLUE}Vorheriger Index gesichert: index_${ts}.json${NC}"
    fi

    # Dateien initialisieren
    : > "$VISITED_FILE"
    : > "$QUEUE_FILE"
    : > "$LOG_FILE"

    echo "[" > "$INDEX_FILE"
    echo "$FIXED_URL" > "$QUEUE_FILE"
    QUEUE_SET["$FIXED_URL"]=1

    log "Starte Crawl: $FIXED_URL"
    log "Max. Seiten: $max_pages"
    log "Übersprungene Typen: $skip_types"

    local page_count=0
    local queue_pos=0
    local first_entry=true

    # Haupt-Crawl-Schleife
    while [[ $page_count -lt $max_pages ]]; do
        queue_pos=$((queue_pos + 1))
        local current_url
        current_url=$(sed -n "${queue_pos}p" "$QUEUE_FILE" 2>/dev/null) || current_url=""
        [[ -z "$current_url" ]] && break

        current_url=$(normalize_url "$current_url")

        # Schleifen Erkennung
        if is_visited "$current_url"; then
            log_warn "Loop verhindert: $current_url"
            continue
        fi

        # Domain-Filter
        if ! is_allowed_domain "$current_url"; then
            log_warn "Übersprungen (Domain): $current_url"
            continue
        fi

        # Als besucht markieren
        mark_visited "$current_url"
        page_count=$((page_count + 1))

        log "[$page_count/$max_pages] Crawle: $current_url"

        # Seite herunterladen
        local page_html
        page_html=$(curl -sL --max-time 20 --user-agent "$USER_AGENT" "$current_url" 2>/dev/null) || page_html=""

        # Hash und Timestamp
        local page_hash timestamp
        page_hash=$(get_page_hash "$page_html")
        timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

        # JSON-Eintrag schreiben
        if [[ "$first_entry" == true ]]; then
            first_entry=false
        else
            printf ',\n' >> "$INDEX_FILE"
        fi

        printf '  {\n    "url": "%s",\n    "hash": "%s",\n    "crawled_at": "%s"\n  }' \
            "$current_url" "$page_hash" "$timestamp" >> "$INDEX_FILE"

        log_ok "Hash: ${page_hash:0:16}..."

        # Links extrahieren und zur Queue hinzufügen
        local new_links added=0
        new_links=$(extract_links "$current_url" "$page_html" "$skip_types")

        if [[ -n "$new_links" ]]; then
            while IFS= read -r link; do
                [[ -z "$link" ]] && continue
                link=$(normalize_url "$link")

                if ! is_visited "$link" && is_allowed_domain "$link"; then
                    if [[ -z "${QUEUE_SET[$link]+x}" ]]; then
                        QUEUE_SET["$link"]=1
                        echo "$link" >> "$QUEUE_FILE"
                        added=$((added + 1))
                    fi
                fi
            done <<< "$new_links"
        fi

        log "  → $added neue Links zur Queue"
    done

    # JSON abschließen
    printf '\n]\n' >> "$INDEX_FILE"

    log "================================"
    log_ok "Crawl abgeschlossen!"
    log_ok "Seiten gecrawlt: $page_count"
    log_ok "Index: $INDEX_FILE"
    log "================================"

    # Automatischer Diff wenn Vorindex vorhanden
    if [[ -n "$prev_index" ]]; then
        echo ""
        echo -e "${BLUE}Erstelle Diff zum vorherigen Crawl...${NC}"
        do_diff_files "$prev_index" "$INDEX_FILE"
    fi
}

# ============================================================
# DIFF-FUNKTIONEN
# ============================================================

# Extrahiert alle URLs aus einem JSON-Index
_extract_urls() {
    grep -oP '"url":\s*"\K[^"]+' "$1" | sort
}

# Extrahiert Hash für eine bestimmte URL aus Index
_get_hash() {
    python3 -c "
import json, sys
with open('$1') as f:
    data = json.load(f)
for entry in data:
    if entry.get('url') == '$2':
        print(entry.get('hash', ''))
        sys.exit(0)
print('')
" 2>/dev/null || echo ""
}

do_diff_files() {
    local old_index="$1"
    local new_index="$2"

    # Dateien prüfen
    [[ ! -f "$old_index" ]] && { echo -e "${RED}Fehler: $old_index nicht gefunden${NC}"; return; }
    [[ ! -f "$new_index" ]] && { echo -e "${RED}Fehler: $new_index nicht gefunden${NC}"; return; }

    # URLs extrahieren
    local tmp_old tmp_new
    tmp_old=$(mktemp)
    tmp_new=$(mktemp)
    trap 'rm -f "$tmp_old" "$tmp_new"' RETURN

    _extract_urls "$old_index" > "$tmp_old"
    _extract_urls "$new_index" > "$tmp_new"

    # Unterschiede berechnen
    local new_urls deleted_urls common_urls
    new_urls=$(comm -13 "$tmp_old" "$tmp_new")
    deleted_urls=$(comm -23 "$tmp_old" "$tmp_new")
    common_urls=$(comm -12 "$tmp_old" "$tmp_new")

    # Header
    echo ""
    echo -e "  ${BLUE}Alt:${NC} $(basename "$old_index")"
    echo -e "  ${BLUE}Neu:${NC} $(basename "$new_index")"
    echo ""

    # Neue Seiten
    echo -e "${BOLD}${GREEN}▶ NEUE Seiten:${NC}"
    local new_count=0
    if [[ -n "$new_urls" ]]; then
        while IFS= read -r url; do
            echo -e "  ${GREEN}+${NC} $url"
            new_count=$((new_count + 1))
        done <<< "$new_urls"
    else
        echo -e "  (keine)"
    fi

    echo ""

    # Gelöschte Seiten
    echo -e "${BOLD}${RED}▶ GELÖSCHTE Seiten:${NC}"
    local deleted_count=0
    if [[ -n "$deleted_urls" ]]; then
        while IFS= read -r url; do
            echo -e "  ${RED}-${NC} $url"
            deleted_count=$((deleted_count + 1))
        done <<< "$deleted_urls"
    else
        echo -e "  (keine)"
    fi

    echo ""

    # Geänderte Seiten
    echo -e "${BOLD}${YELLOW}▶ GEÄNDERTE Seiten:${NC}"
    local changed_count=0 unchanged_count=0
    if [[ -n "$common_urls" ]]; then
        while IFS= read -r url; do
            local old_hash new_hash
            old_hash=$(_get_hash "$old_index" "$url")
            new_hash=$(_get_hash "$new_index" "$url")

            if [[ "$old_hash" != "$new_hash" ]]; then
                echo -e "  ${YELLOW}~${NC} $url"
                echo -e "      alt: ${old_hash:0:16}..."
                echo -e "      neu: ${new_hash:0:16}..."
                changed_count=$((changed_count + 1))
            else
                unchanged_count=$((unchanged_count + 1))
            fi
        done <<< "$common_urls"
    fi
    [[ $changed_count -eq 0 ]] && echo -e "  (keine)"

    echo ""

    # Zusammenfassung
    local total_old total_new
    total_old=$(wc -l < "$tmp_old")
    total_new=$(wc -l < "$tmp_new")

    echo -e "${BOLD}${CYAN}Zusammenfassung${NC}"
    echo -e "  Seiten alt:       $total_old"
    echo -e "  Seiten neu:       $total_new"
    echo -e "  ${GREEN}Neu:${NC}              $new_count"
    echo -e "  ${RED}Gelöscht:${NC}         $deleted_count"
    echo -e "  ${YELLOW}Geändert:${NC}         $changed_count"
    echo -e "  Unverändert:      $unchanged_count"
    echo ""
}

do_diff_menu() {
    local archives
    archives=$(ls -t "${OUTPUT_DIR}"/index_*.json 2>/dev/null) || archives=""

    if [[ -z "$archives" ]]; then
        echo -e "${YELLOW}Keine archivierten Indexe gefunden. Zuerst zwei Crawls durchführen.${NC}"
        return
    fi

    # verfügbare Indexe anzeigen
    echo "Verfügbare Indexe:"
    local i=1
    while IFS= read -r f; do
        echo "  $i) $(basename "$f")"
        i=$((i + 1))
    done <<< "$archives"

    # Benutzereingaben
    read -rp "Alter Index (Nummer): " a_num
    read -rp "Neuer Index (Nummer oder Enter = aktueller Index): " b_num

    local a_file b_file
    a_file=$(echo "$archives" | sed -n "${a_num}p")
    b_file="${INDEX_FILE}"
    [[ -n "$b_num" ]] && b_file=$(echo "$archives" | sed -n "${b_num}p")

    do_diff_files "$a_file" "$b_file"
}

# ============================================================
# INDEX ANZEIGEN
# ============================================================

do_show_index() {
    if [[ ! -f "$INDEX_FILE" ]]; then
        echo -e "${YELLOW}Noch kein Index vorhanden. Zuerst einen Crawl starten.${NC}"
        return
    fi

    local count
    count=$(grep -c '"url"' "$INDEX_FILE" 2>/dev/null) || count=0

    echo -e "${GREEN}Aktueller Index: $count Seiten${NC}"
    echo ""
    grep '"url"' "$INDEX_FILE" | sed 's/.*"url": "\(.*\)".*/  \1/'
}

# ============================================================
# HAUPTMENÜ
# ============================================================

show_menu() {
    echo ""
    echo "CSS.ch Web Crawler"
    echo "=================="
    echo ""
    echo "  1) Crawl starten"
    echo "  2) Diff zwischen zwei Runs anzeigen"
    echo "  3) Letzten Index anzeigen"
    echo "  4) Beenden"
    echo ""
}

main() {
    while true; do
        show_menu
        read -rp "Wahl: " choice

        case "$choice" in
            1) do_crawl ;;
            2) do_diff_menu ;;
            3) do_show_index ;;
            4) echo "Tschüss!"; exit 0 ;;
            *) echo -e "${RED}Ungültige Eingabe. Bitte wählen Sie 1-4.${NC}" ;;
        esac
    done
}

main
