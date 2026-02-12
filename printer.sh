#!/bin/bash
set -euo pipefail

# ========== FARBY ==========
BOLD="\e[1m"
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
BLUE="\e[34m"
RESET="\e[0m"

# ========== PARAMETRE ==========
FORCE_MODE=false
if [[ "${1:-}" == "--force" ]]; then
    FORCE_MODE=true
    shift
fi

# ========== FUNKCIE ==========
cleanup() {
    echo -e "\n${BLUE}🧹 Čistenie po sebe...${RESET}"
    
    # Zmazanie dočasného PDF ak existuje
    [[ -f "$TEMP_FILE" ]] && rm -f "$TEMP_FILE" && echo -e "${GREEN}✓${RESET} Dočasný súbor zmazaný"
    
    # Zastavenie CUPS ak ho skript spustil
    if [[ "$CUPS_WAS_STOPPED" == "true" ]] && (systemctl is-active --quiet cups 2>/dev/null || systemctl is-active --quiet cupsd 2>/dev/null); then
        echo -e "${YELLOW}⏳ Zastavujem CUPS (dočasne spustený skriptom)...${RESET}"
        sudo systemctl stop cups 2>/dev/null || sudo systemctl stop cupsd 2>/dev/null || true
        echo -e "${GREEN}✓${RESET} CUPS zastavený"
    fi
    
    echo -e "${GREEN}✅ Systém obnovený do pôvodného stavu${RESET}"
}

trap cleanup EXIT INT TERM

# ========== ÚVOD ==========
echo -e "${BOLD}🖨️  Dočasný CUPS Print Manager (všetky tlačiarne)${RESET}"
echo -e "${YELLOW}💡 Skript nájde všetky tlačiarne v sieti a vytlačí dokument na každú pripravenú${RESET}\n"

# ========== KONTROLA PODMIENOK ==========
for cmd in nmap lp lpstat; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}❌ Chýba '$cmd' – nainštalujte: sudo apt install cups nmap${RESET}"
        exit 1
    fi
done

# ========== PRÍPRAVA DOKUMENTU ==========
TEMP_FILE=""
if [[ -f "test.pdf" ]]; then
    TEMP_FILE="$(pwd)/test.pdf"
    echo -e "${GREEN}✓${RESET} Nájdený súbor: test.pdf"
elif [[ -f "test.docx" ]]; then
    echo -e "${YELLOW}⚠️  test.pdf neexistuje – konvertujem test.docx → PDF${RESET}"
    TEMP_FILE="/tmp/print_$(date +%s)_$$.pdf"
    if command -v libreoffice &>/dev/null; then
        libreoffice --headless --convert-to pdf "test.docx" --outdir /tmp 2>/dev/null
        mv "/tmp/test.pdf" "$TEMP_FILE" 2>/dev/null || {
            echo -e "${RED}❌ Konverzia zlyhala${RESET}"
            exit 1
        }
        echo -e "${GREEN}✓${RESET} Konverzia úspešná: $TEMP_FILE"
    else
        echo -e "${RED}❌ Chýba LibreOffice pre konverziu DOCX → PDF${RESET}"
        exit 1
    fi
else
    echo -e "${YELLOW}⚠️  Žiadny vstupný súbor (test.pdf/test.docx) – vytváram testovací text${RESET}"
    TEMP_FILE="/tmp/print_test_$$.txt"
    echo -e "TESTOVACÍ DOKUMENT\nDátum: $(date)\n\nTento dokument bol vytlačený automaticky cez bash skript" > "$TEMP_FILE"
fi

# ========== STAV CUPS PRED SPUSTENÍM ==========
CUPS_WAS_STOPPED="false"
if ! systemctl is-active --quiet cups 2>/dev/null && ! systemctl is-active --quiet cupsd 2>/dev/null; then
    echo -e "${YELLOW}⚠️  CUPS nie je aktívny – spúšťam dočasne...${RESET}"
    sudo systemctl start cups 2>/dev/null || sudo systemctl start cupsd 2>/dev/null || {
        echo -e "${RED}❌ Nepodarilo sa spustiť CUPS${RESET}"
        exit 1
    }
    CUPS_WAS_STOPPED="true"
    echo -e "${GREEN}✓${RESET} CUPS dočasne spustený\n"
else
    echo -e "${GREEN}✓${RESET} CUPS už beží – používam existujúcu inštanciu\n"
fi

# ========== DETEKcia TLAČIARNÍ ==========
echo -e "${BLUE}🔍 Zisťujem sieť...${RESET}"
LOCAL_IP=$(hostname -I | awk '{print $1}' | head -1)
SUBNET=$(echo "$LOCAL_IP" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.')
echo -e "${GREEN}✓${RESET} Podsieť: ${SUBNET}0/24"

echo -e "\n${BLUE}📡 Hľadám tlačiarne v sieti...${RESET}"
FOUND_PRINTERS=()

# CUPS nakonfigurované tlačiarne
while IFS= read -r printer; do
    [[ -n "$printer" ]] && FOUND_PRINTERS+=("cups:$printer")
    echo -e "${GREEN}✓${RESET} CUPS: $printer"
done < <(lpstat -p 2>/dev/null | awk '{print $2}' || true)

# Sieťové tlačiarne cez port scan
while IFS= read -r ip; do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    
    if timeout 1 bash -c "echo >/dev/tcp/$ip/631" 2>/dev/null; then
        FOUND_PRINTERS+=("ipp:$ip")
        echo -e "${GREEN}✓${RESET} Sieť: $ip (IPP/631)"
    elif timeout 1 bash -c "echo >/dev/tcp/$ip/9100" 2>/dev/null; then
        FOUND_PRINTERS+=("raw:$ip")
        echo -e "${GREEN}✓${RESET} Sieť: $ip (Raw/9100)"
    fi
done < <(nmap -sn -T4 "${SUBNET}0/24" -oG - 2>/dev/null | grep "Up" | awk '{print $2}' || true)

if [[ ${#FOUND_PRINTERS[@]} -eq 0 ]]; then
    echo -e "\n${RED}❌ Žiadne tlačiarne nenájdené${RESET}"
    exit 1
fi

echo -e "\n${GREEN}✅ Nájdené tlačiarne: ${#FOUND_PRINTERS[@]}${RESET}"

# ========== BEZPEČNOSTNÁ KONTROLA ==========
if [[ "${#FOUND_PRINTERS[@]}" -gt 1 && "$FORCE_MODE" == false ]]; then
    echo -e "\n${YELLOW}⚠️  POZOR: Dokument sa vytlačí na ${#FOUND_PRINTERS[@]} tlačiarní naraz!${RESET}"
    echo -e "${YELLOW}💡 Toto môže spôsobiť waste papiera ak sú tlačiarne verejné${RESET}"
    read -p "Naozaj chcete pokračovať? (y/n): " -n 1 -r
    echo
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo -e "${RED}❌ Operácia zrušená používateľom${RESET}"
        exit 0
    fi
fi

# ========== TLAČ NA VŠETKY TLAČIARNE ==========
SUCCESS_COUNT=0
FAIL_COUNT=0

echo -e "\n${BOLD}🖨️  TLAČ NA VŠETKY DOSTUPNÉ TLAČIARNE${RESET}"
echo -e "${BLUE}📄 Súbor: ${TEMP_FILE}${RESET}\n"

for entry in "${FOUND_PRINTERS[@]}"; do
    IFS=':' read -r TYPE TARGET <<< "$entry"
    
    case "$TYPE" in
        cups)
            PRINTER_NAME="$TARGET"
            STATUS=$(lpstat -p "$PRINTER_NAME" 2>/dev/null | awk '{print $3}' || echo "unknown")
            
            if [[ "$STATUS" == "idle" || "$STATUS" == "printing" ]]; then
                echo -e "${BLUE}→ Tlač na CUPS tlačiareň '$PRINTER_NAME'...${RESET}"
                if lp -d "$PRINTER_NAME" "$TEMP_FILE" 2>/dev/null; then
                    JOB_ID=$(lpstat -o 2>/dev/null | grep "$PRINTER_NAME" | tail -1 | awk '{print $1}' || echo "N/A")
                    echo -e "${GREEN}✅ Úspešne odoslané: $JOB_ID${RESET}"
                    ((SUCCESS_COUNT++))
                else
                    echo -e "${RED}❌ Zlyhanie pri odosielaní${RESET}"
                    ((FAIL_COUNT++))
                fi
            else
                echo -e "${YELLOW}⚠️  '$PRINTER_NAME' nie je pripravená (stav: $STATUS)${RESET}"
                ((FAIL_COUNT++))
            fi
            ;;
        ipp|raw)
            IP="$TARGET"
            PRINTER_NAME="temp_$IP"
            
            # Skontrolujeme dostupnosť
            if ! ping -c 1 -W 1 "$IP" &>/dev/null; then
                echo -e "${YELLOW}⚠️  $IP je offline (neodpovedá na ping)${RESET}"
                ((FAIL_COUNT++))
                continue
            fi
            
            # Dočasné pridanie do CUPS
            echo -e "${BLUE}→ Pridávam sieťovú tlačiareň $IP...${RESET}"
            if sudo lpadmin -p "$PRINTER_NAME" -v "ipp://$IP/ipp/print" -m everywhere -E 2>/dev/null; then
                echo -e "${BLUE}→ Tlač na $IP...${RESET}"
                if lp -d "$PRINTER_NAME" "$TEMP_FILE" 2>/dev/null; then
                    JOB_ID=$(lpstat -o 2>/dev/null | grep "$PRINTER_NAME" | tail -1 | awk '{print $1}' || echo "N/A")
                    echo -e "${GREEN}✅ Úspešne odoslané: $JOB_ID${RESET}"
                    ((SUCCESS_COUNT++))
                else
                    echo -e "${RED}❌ Zlyhanie pri odosielaní${RESET}"
                    ((FAIL_COUNT++))
                fi
                # Okamžité odstránenie dočasnej tlačiarne
                sudo lpadmin -x "$PRINTER_NAME" 2>/dev/null || true
            else
                echo -e "${YELLOW}⚠️  Nepodarilo sa pridať $IP do CUPS${RESET}"
                ((FAIL_COUNT++))
            fi
            ;;
    esac
done

# ========== ZÁVER ==========
echo -e "\n${BOLD}📊 Výsledok tlače:${RESET}"
echo -e "${GREEN}✅ Úspešné: $SUCCESS_COUNT${RESET}"
echo -e "${RED}❌ Zlyhané:  $FAIL_COUNT${RESET}"

if [[ $SUCCESS_COUNT -eq 0 ]]; then
    echo -e "\n${RED}❌ Žiadna tlačiareň neprijala úlohu${RESET}"
    echo -e "${YELLOW}💡 Skontrolujte: napájanie tlačiarne, sieťové pripojenie, stav 'Ready'${RESET}"
    exit 1
else
    echo -e "\n${GREEN}🎉 Dokument bol odoslaný na tlač na $SUCCESS_COUNT tlačiarní${RESET}"
    exit 0
fi
