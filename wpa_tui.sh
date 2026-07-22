#!/usr/bin/env bash
set -euo pipefail

WPA_CLI="wpa_cli"

die() {
    echo "Errore: $1" >&2
    exit 1
}

check_deps() {
    command -v whiptail >/dev/null 2>&1 || die "whiptail non trovato (pacchetto 'newt')"
    command -v wpa_cli >/dev/null 2>&1 || die "wpa_cli non trovato"
}

detect_interface() {
    local ifaces=()
    local line
    while IFS= read -r line; do
        [[ "$line" == p2p-dev-* ]] && continue
        [[ -z "$line" ]] && continue
        ifaces+=("$line")
    done < <("$WPA_CLI" interface 2>/dev/null | tail -n +3)

    if [ "${#ifaces[@]}" -eq 0 ]; then
        die "Nessuna interfaccia wpa_supplicant trovata"
    elif [ "${#ifaces[@]}" -eq 1 ]; then
        echo "${ifaces[0]}"
    else
        local menu_args=()
        for i in "${ifaces[@]}"; do
            menu_args+=("$i" "$i")
        done
        whiptail --title "Seleziona interfaccia" --menu "Interfacce disponibili:" 15 50 6 \
            "${menu_args[@]}" 3>&1 1>&2 2>&3
    fi
}

run_scan_gauge() {
    "$WPA_CLI" -i "$IFACE" scan >/dev/null 2>&1 || true
    (
        for pct in 0 20 40 60 80 100; do
            echo "$pct"
            sleep 0.7
        done
    ) | whiptail --gauge "Scansione delle reti in corso..." 8 50 0
}

get_scan_results() {
    "$WPA_CLI" -i "$IFACE" scan_results | tail -n +2 | \
        awk -F'\t' '
            $5 != "" {
                ssid = $5
                sig = $3
                if (!(ssid in best) || sig > best[ssid]) {
                    best[ssid] = sig
                    flags[ssid] = $4
                }
            }
            END {
                for (s in best) printf "%d\t%s\t%s\n", best[s], s, flags[s]
            }
        ' | sort -t $'\t' -k1,1nr
}

create_network() {
    run_scan_gauge

    local menu_args=()
    local sig ssid _flags
    while IFS=$'\t' read -r sig ssid _flags; do
        menu_args+=("$ssid" "(${sig} dBm)")
    done < <(get_scan_results)

    if [ "${#menu_args[@]}" -eq 0 ]; then
        whiptail --msgbox "Nessuna rete trovata." 8 40 || true
        return 0
    fi

    local ssid_choice
    ssid_choice=$(whiptail --title "Crea nuova rete ($IFACE)" \
        --menu "$(printf '%-28s %s' 'SSID' 'Segnale')" 20 60 10 \
        "${menu_args[@]}" 3>&1 1>&2 2>&3) || return 0

    local psk
    psk=$(whiptail --title "Password" \
        --passwordbox "Inserisci la password per \"$ssid_choice\":" 10 60 \
        3>&1 1>&2 2>&3) || return 0

    if [ "${#psk}" -lt 8 ] || [ "${#psk}" -gt 63 ]; then
        whiptail --msgbox "Password non valida: deve essere lunga tra 8 e 63 caratteri." 8 60 || true
        return 0
    fi

    local net_id
    net_id=$("$WPA_CLI" -i "$IFACE" add_network)
    if ! [[ "$net_id" =~ ^[0-9]+$ ]]; then
        whiptail --msgbox "Impossibile creare la rete." 8 50 || true
        return 0
    fi

    "$WPA_CLI" -i "$IFACE" set_network "$net_id" ssid "\"$ssid_choice\"" >/dev/null 2>&1
    "$WPA_CLI" -i "$IFACE" set_network "$net_id" psk "\"$psk\"" >/dev/null 2>&1
    "$WPA_CLI" -i "$IFACE" enable_network "$net_id" >/dev/null 2>&1
    "$WPA_CLI" -i "$IFACE" select_network "$net_id" >/dev/null 2>&1
    "$WPA_CLI" -i "$IFACE" save_config >/dev/null 2>&1

    wait_for_connection "$ssid_choice"
}

wait_for_connection() {
    local target_ssid="$1"
    local timeout=15
    local result

    if (
        local elapsed=0
        local state cur_ssid
        while [ "$elapsed" -lt "$timeout" ]; do
            state=$("$WPA_CLI" -i "$IFACE" status 2>/dev/null | awk -F= '$1=="wpa_state"{print $2}') || true
            cur_ssid=$("$WPA_CLI" -i "$IFACE" status 2>/dev/null | awk -F= '$1=="ssid"{print $2}') || true

            if [ "$state" = "COMPLETED" ] && [ "$cur_ssid" = "$target_ssid" ]; then
                echo 100
                exit 0
            fi

            echo $(( elapsed * 100 / timeout ))
            sleep 1
            elapsed=$((elapsed + 1))
        done
        exit 1
    ) | whiptail --gauge "Verifica connessione a \"$target_ssid\"..." 8 60 0; then
        :
    fi
    result=${PIPESTATUS[0]}

    if [ "$result" -eq 0 ]; then
        whiptail --msgbox "Connesso a \"$target_ssid\"." 8 50 || true
    else
        whiptail --msgbox "Connessione a \"$target_ssid\" non riuscita (timeout). Verifica la password." 8 60 || true
    fi
}

get_saved_networks() {
    "$WPA_CLI" -i "$IFACE" list_networks | tail -n +2
}

connect_to_network() {
    local list
    list=$(get_saved_networks)

    if [ -z "$list" ]; then
        whiptail --msgbox "Nessuna rete salvata." 8 40 || true
        return 0
    fi

    local menu_args=()
    declare -A id_to_ssid
    local id ssid _bssid flags
    while IFS=$'\t' read -r id ssid _bssid flags; do
        local desc="$ssid"
        [ -n "$flags" ] && desc="$ssid $flags"
        menu_args+=("$id" "$desc")
        id_to_ssid["$id"]="$ssid"
    done <<< "$list"

    local choice
    choice=$(whiptail --title "Reti salvate ($IFACE)" \
        --menu "Seleziona una rete a cui connetterti:" 20 60 10 \
        "${menu_args[@]}" 3>&1 1>&2 2>&3) || return 0

    "$WPA_CLI" -i "$IFACE" select_network "$choice" >/dev/null 2>&1

    wait_for_connection "${id_to_ssid[$choice]}"
}

delete_network() {
    local list
    list=$(get_saved_networks)

    if [ -z "$list" ]; then
        whiptail --msgbox "Nessuna rete salvata." 8 40 || true
        return 0
    fi

    local menu_args=()
    declare -A id_to_ssid
    local id ssid _bssid flags
    while IFS=$'\t' read -r id ssid _bssid flags; do
        local desc="$ssid"
        [ -n "$flags" ] && desc="$ssid $flags"
        menu_args+=("$id" "$desc")
        id_to_ssid["$id"]="$ssid"
    done <<< "$list"

    local choice
    choice=$(whiptail --title "Elimina rete ($IFACE)" \
        --menu "Seleziona la rete da eliminare:" 20 60 10 \
        "${menu_args[@]}" 3>&1 1>&2 2>&3) || return 0

    if ! whiptail --yesno "Eliminare definitivamente \"${id_to_ssid[$choice]}\"?" 8 60; then
        return 0
    fi

    "$WPA_CLI" -i "$IFACE" remove_network "$choice" >/dev/null 2>&1
    "$WPA_CLI" -i "$IFACE" save_config >/dev/null 2>&1

    whiptail --msgbox "Rete \"${id_to_ssid[$choice]}\" eliminata." 8 50 || true
}

main_menu() {
    whiptail --title "wpa_tui ($IFACE)" --menu "Scegli un'azione:" 15 50 6 \
        1 "Connetti a rete esistente" \
        2 "Crea nuova rete" \
        3 "Elimina rete" \
        4 "Esci" \
        3>&1 1>&2 2>&3
}

check_deps
IFACE=$(detect_interface)

while true; do
    choice=$(main_menu) || exit 0
    case "$choice" in
        1) connect_to_network ;;
        2) create_network ;;
        3) delete_network ;;
        4) exit 0 ;;
    esac
done
