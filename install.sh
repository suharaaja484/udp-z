#!/bin/bash
# Zivpn UDP Module Manager
# This script installs the base Zivpn service and then sets up an advanced management interface.

# --- UI Definitions ---
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD_WHITE='\033[1;37m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
LIGHT_GREEN='\033[1;32m'
NC='\033[0m' # No Color

# ─── License Info ───
LICENSE_URL="https://raw.githubusercontent.com/suharaaja484/izin/main/register2"
LICENSE_INFO_FILE="/etc/zivpn/.license_info"
CONFIG_DIR="/etc/zivpn"
TELEGRAM_CONF="${CONFIG_DIR}/telegram.conf"

# ─── Pre-flight Checks ───
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo or run as root user." >&2
  exit 1
fi

function send_telegram_notification() {
    local message="$1"
    local keyboard="$2"

    if [ ! -f "$TELEGRAM_CONF" ]; then
        return 1
    fi
    # shellcheck source=/etc/zivpn/telegram.conf
    source "$TELEGRAM_CONF"

    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        local api_url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
        if [ -n "$keyboard" ]; then
            curl -s -X POST "$api_url" -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${message}" -d "reply_markup=${keyboard}" > /dev/null
        else
            curl -s -X POST "$api_url" -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${message}" -d "parse_mode=Markdown" > /dev/null
        fi
    fi
}


# --- License Verification Function ---
function verify_license() {
    echo "Verifying installation license..."
    local SERVER_IP
    SERVER_IP=$(curl -4 -s ifconfig.me)
    if [ -z "$SERVER_IP" ]; then
        echo -e "${RED}Failed to retrieve server IP. Please check your internet connection.${NC}"
        exit 1
    fi

    local license_data
    license_data=$(curl -s "$LICENSE_URL")
    if [ $? -ne 0 ] || [ -z "$license_data" ]; then
        echo -e "${RED}Gagal terhubung ke server lisensi. Mohon periksa koneksi internet Anda.${NC}"
        exit 1
    fi

    local license_entry
    license_entry=$(echo "$license_data" | grep -w "$SERVER_IP")

    if [ -z "$license_entry" ]; then
        echo -e "${RED}Verifikasi Lisensi Gagal! IP Anda tidak terdaftar. IP: ${SERVER_IP}${NC}"
        exit 1
    fi

    local client_name
    local expiry_date_str
    client_name=$(echo "$license_entry" | awk '{print $1}')
    expiry_date_str=$(echo "$license_entry" | awk '{print $2}')

    local expiry_timestamp
    expiry_timestamp=$(date -d "$expiry_date_str" +%s)
    local current_timestamp
    current_timestamp=$(date +%s)

    if [ "$expiry_timestamp" -le "$current_timestamp" ]; then
        echo -e "${RED}Verifikasi Lisensi Gagal! Lisensi untuk IP ${SERVER_IP} telah kedaluwarsa. Tanggal Kedaluwarsa: ${expiry_date_str}${NC}"
        exit 1
    fi
    
    echo -e "${LIGHT_GREEN}Verifikasi Lisensi Berhasil! Client: ${client_name}, IP: ${SERVER_IP}${NC}"
    sleep 2 # Brief pause to show the message
    
    mkdir -p /etc/zivpn
    echo "CLIENT_NAME=${client_name}" > "$LICENSE_INFO_FILE"
    echo "EXPIRY_DATE=${expiry_date_str}" >> "$LICENSE_INFO_FILE"
}

# --- Utility Functions ---
function restart_zivpn() {
    echo "Restarting ZIVPN service..."
    systemctl restart zivpn.service
    echo "Service restarted."
}

# --- Internal Logic Functions (for API calls) ---
function _create_account_logic() {
    local password="$1"
    local days="$2"
    local db_file="/etc/zivpn/users.db"

    if [ -z "$password" ] || [ -z "$days" ]; then
        echo "Error: Password and days are required."
        return 1
    fi
    
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid number of days."
        return 1
    fi

    if grep -q "^${password}:" "$db_file"; then
        echo "Error: Password '${password}' already exists."
        return 1
    fi

    local expiry_date
    expiry_date=$(date -d "+$days days" +%s)
    echo "${password}:${expiry_date}" >> "$db_file"
    
    # Use a temporary file for atomic write
    jq --arg pass "$password" '.auth.config += [$pass]' /etc/zivpn/config.json > /etc/zivpn/config.json.tmp && mv /etc/zivpn/config.json.tmp /etc/zivpn/config.json
    
    if [ $? -eq 0 ]; then
        echo "Success: Account '${password}' created, expires in ${days} days."
        restart_zivpn
        return 0
    else
        # Rollback the change in users.db if config update fails
        sed -i "/^${password}:/d" "$db_file"
        echo "Error: Failed to update config.json."
        return 1
    fi
}

# --- Core Logic Functions ---
function create_manual_account() {
    echo "--- Create New Zivpn Account ---"
    read -p "Enter new password: " password
    if [ -z "$password" ]; then
        echo "Password cannot be empty."
        return
    fi

    read -p "Enter active period (in days): " days
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        echo "Invalid number of days."
        return
    fi

    # Call the logic function and capture its output
    local result
    result=$(_create_account_logic "$password" "$days")
    
    # Display logic remains here for interactive mode if successful
    if [[ "$result" == "Success"* ]]; then
        local db_file="/etc/zivpn/users.db"
        local user_line
        user_line=$(grep "^${password}:" "$db_file")
        if [ -n "$user_line" ]; then
            local expiry_date
            expiry_date=$(echo "$user_line" | cut -d: -f2)

            local CERT_CN
            CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
            local HOST
            if [ "$CERT_CN" == "zivpn" ]; then
                HOST=$(curl -4 -s ifconfig.me)
            else
                HOST=$CERT_CN
            fi

            local EXPIRE_FORMATTED
            EXPIRE_FORMATTED=$(date -d "@$expiry_date" +"%d %B %Y")
            
ip=$(curl -4 -s ifconfig.me)
isp=$(curl -s ipinfo.io | jq -r '.org // "N/A"')
CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
local host
if [ "$CERT_CN" == "zivpn" ]; then
host=$(curl -4 -s ifconfig.me)
else
host=$CERT_CN
fi
clear
echo "🔹 CREATE AKUN ZIVPN 🔹"
echo "┌────────────────────────┐"
echo "│ Host   : $host"
echo "│ IP     : $ip"
echo "│ ISP    : $isp"
echo "│ Pass   : $password"
echo "│ Expire : $EXPIRE_FORMATTED"
echo "└────────────────────────┘"
echo "♨ Terima kasih telah menggunakan layanan kami ♨"
# ─── Notifikasi Telegram (CREATE) ───
local message=$(cat <<EOF
🔹 CREATE AKUN ZIVPN 🔹
┌────────────────────────┐
│ Host   : $host
│ IP     : $ip
│ ISP    : $isp
│ Pass   : $password
│ Expire : $days Days
└────────────────────────┘
♨ Terima kasih telah menggunakan layanan kami ♨
EOF
)

send_telegram_notification "$message"
        fi
    else
        # If it failed, show the error message
        echo "$result"
    fi
    
    read -p "Tekan Enter untuk kembali ke menu..."
}

function _generate_api_key() {
    clear
    echo "--- Generate API Authentication Key ---"
    
    # Generate a 6-character alphanumeric key
    local api_key
    api_key=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 6)
    
    local key_file="/etc/zivpn/api_auth.key"
    
    echo "$api_key" > "$key_file"
    chmod 600 "$key_file"
    
    echo "New API authentication key has been generated and saved."
    echo "Key: ${api_key}"
    
    echo "Sending API key to Telegram..."
    # Get Server IP and Domain for the notification
    local server_ip
    server_ip=$(curl -4 -s ifconfig.me)
    local cert_cn
    cert_cn=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p' 2>/dev/null || echo "")
    local domain
    if [ "$cert_cn" == "zivpn" ] || [ -z "$cert_cn" ]; then
        domain=$server_ip
    else
        domain=$cert_cn
    fi
    
    /usr/local/bin/zivpn_helper.sh api-key-notification "$api_key" "$server_ip" "$domain"
    
    read -p "Tekan Enter untuk kembali ke menu..."
}

function _create_trial_account_logic() {
    local minutes="$1"
    local db_file="/etc/zivpn/users.db"

    if ! [[ "$minutes" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid number of minutes."
        return 1
    fi

    local password="trial$(shuf -i 10000-99999 -n 1)"

    local expiry_date
    expiry_date=$(date -d "+$minutes minutes" +%s)
    echo "${password}:${expiry_date}" >> "$db_file"
    
    jq --arg pass "$password" '.auth.config += [$pass]' /etc/zivpn/config.json > /etc/zivpn/config.json.tmp && mv /etc/zivpn/config.json.tmp /etc/zivpn/config.json
    
    if [ $? -eq 0 ]; then
        echo "Success: Trial account '${password}' created, expires in ${minutes} minutes."
        restart_zivpn
        return 0
    else
        sed -i "/^${password}:/d" "$db_file"
        echo "Error: Failed to update config.json."
        return 1
    fi
}

function create_trial_account() {
    echo "--- Create Trial Zivpn Account ---"
    read -p "Enter active period (in minutes): " minutes
    if ! [[ "$minutes" =~ ^[0-9]+$ ]]; then
        echo "Invalid number of minutes."
        return
    fi

    local result
    result=$(_create_trial_account_logic "$minutes")
    
    if [[ "$result" == "Success"* ]]; then
        # Extract password from the success message
        local password
        password=$(echo "$result" | sed -n "s/Success: Trial account '\([^']*\)'.*/\1/p")
        
        local db_file="/etc/zivpn/users.db"
        local user_line
        user_line=$(grep "^${password}:" "$db_file")
        if [ -n "$user_line" ]; then
            local expiry_date
            expiry_date=$(echo "$user_line" | cut -d: -f2)

            local CERT_CN
            CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
            local HOST
            if [ "$CERT_CN" == "zivpn" ]; then
                HOST=$(curl -4 -s ifconfig.me)
            else
                HOST=$CERT_CN
            fi

            local EXPIRE_FORMATTED
            EXPIRE_FORMATTED=$(date -d "@$expiry_date" +"%d %B %Y %H:%M:%S")
            
ip=$(curl -4 -s ifconfig.me)
isp=$(curl -s ipinfo.io | jq -r '.org // "N/A"')
CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
local host
if [ "$CERT_CN" == "zivpn" ]; then
host=$(curl -4 -s ifconfig.me)
else
host=$CERT_CN
fi            
clear
echo "🔹 TRIAL AKUN ZIVPN 🔹"
echo "┌────────────────────────┐"
echo "│ Host   : $host"
echo "│ IP     : $ip"
echo "│ ISP    : $isp"
echo "│ Pass   : $password"
echo "│ Expire : $EXPIRE_FORMATTED"
echo "└────────────────────────┘"
echo "♨ Terima kasih telah menggunakan layanan kami ♨"

# ─── Notifikasi Telegram (TRIAL) ───
local message=$(cat <<EOF
🔹 TRIAL AKUN ZIVPN 🔹
┌────────────────────────┐
│ Host   : $host
│ IP     : $ip
│ ISP    : $isp
│ Pass   : $password
│ Expire : $minutes Minutes
└────────────────────────┘
♨ Terima kasih telah mencoba layanan kami ♨
EOF
)

send_telegram_notification "$message"
        fi
    else
        echo "$result"
    fi
    
    read -p "Tekan Enter untuk kembali ke menu..."
}

function _renew_account_logic() {
    local password="$1"
    local days="$2"
    local db_file="/etc/zivpn/users.db"

    if [ -z "$password" ] || [ -z "$days" ]; then
        echo "Error: Password and days are required."
        return 1
    fi
    
    if ! [[ "$days" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: Invalid number of days."
        return 1
    fi

    local user_line
    user_line=$(grep "^${password}:" "$db_file")

    if [ -z "$user_line" ]; then
        echo "Error: Account '${password}' not found."
        return 1
    fi

    local current_expiry_date
    current_expiry_date=$(echo "$user_line" | cut -d: -f2)

    if ! [[ "$current_expiry_date" =~ ^[0-9]+$ ]]; then
        echo "Error: Corrupted database entry for user '$password'."
        return 1
    fi
    
    local seconds_to_add=$((days * 86400))
    local new_expiry_date=$((current_expiry_date + seconds_to_add))
    
    sed -i "s/^${password}:.*/${password}:${new_expiry_date}/" "$db_file"
    echo "Success: Account '${password}' has been renewed for ${days} days."
    return 0
}

function renew_account() {
    clear
    echo "--- Renew Account ---"
    _display_accounts
    echo "" # Add a newline for better spacing
    read -p "Enter password to renew: " password
    if [ -z "$password" ]; then
        echo "Password cannot be empty."
        return
    fi

    read -p "Enter number of days to extend: " days
    if ! [[ "$days" =~ ^[1-9][0-9]*$ ]]; then
        echo "Invalid number of days. Please enter a positive number."
        return
    fi

    local result
    result=$(_renew_account_logic "$password" "$days")
    
    if [[ "$result" == "Success"* ]]; then
        local db_file="/etc/zivpn/users.db"
        local user_line
        user_line=$(grep "^${password}:" "$db_file")
        local new_expiry_date
        new_expiry_date=$(echo "$user_line" | cut -d: -f2)
        local new_expiry_formatted
        new_expiry_formatted=$(date -d "@$new_expiry_date" +"%d %B %Y")
ip=$(curl -4 -s ifconfig.me)
isp=$(curl -s ipinfo.io | jq -r '.org // "N/A"')
CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
local host
if [ "$CERT_CN" == "zivpn" ]; then
host=$(curl -4 -s ifconfig.me)
else
host=$CERT_CN
fi
clear
echo "🔹 RENEW AKUN ZIVPN 🔹"
echo "┌────────────────────────┐"
echo "│ Host   : $host"
echo "│ IP     : $ip"
echo "│ ISP    : $isp"
echo "│ Pass   : $password"
echo "│ Expire : $new_expiry_formatted"
echo "└────────────────────────┘"
echo "♨ Terima kasih telah menggunakan layanan kami ♨"
# ─── Notifikasi Telegram (RENEW) ───
local message=$(cat <<EOF
🔹 RENEW AKUN ZIVPN 🔹
┌────────────────────────┐
│ Host   : $host
│ IP     : $ip
│ ISP    : $isp
│ Pass   : $password
│ Expire : $new_expiry_formatted
└────────────────────────┘
♨ Terima kasih telah menggunakan layanan kami ♨
EOF
)

send_telegram_notification "$message"
    else
        echo "$result"
    fi
    read -p "Tekan Enter untuk kembali ke menu..."
}

function _delete_account_logic() {
    local password="$1"
    local db_file="/etc/zivpn/users.db"
    local config_file="/etc/zivpn/config.json"
    local tmp_config_file="${config_file}.tmp"

    if [ -z "$password" ]; then
        echo "Error: Password is required."
        return 1
    fi

    if [ ! -f "$db_file" ] || ! grep -q "^${password}:" "$db_file"; then
        echo "Error: Password '${password}' not found."
        return 1
    fi

    # Step 1: Try to update the config file first to a temporary location
    jq --arg pass "$password" 'del(.auth.config[] | select(. == $pass))' "$config_file" > "$tmp_config_file"
    
    if [ $? -eq 0 ]; then
        # Step 2: If config update is successful, remove user from db
        sed -i "/^${password}:/d" "$db_file"
        
        # Step 3: Atomically replace the old config with the new one
        mv "$tmp_config_file" "$config_file"
        
        restart_zivpn
        ip=$(curl -4 -s ifconfig.me)
isp=$(curl -s ipinfo.io | jq -r '.org // "N/A"')
CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
local host
if [ "$CERT_CN" == "zivpn" ]; then
host=$(curl -4 -s ifconfig.me)
else
host=$CERT_CN
fi
clear
echo "🔹 DELETE AKUN ZIVPN 🔹"
echo "┌────────────────────────┐"
echo "│ Host   : $host"
echo "│ IP     : $ip"
echo "│ ISP    : $isp"
echo "│ Pass   : $password"
echo "│ Status : Deleted"
echo "└────────────────────────┘"
echo "♨ Terima kasih telah menggunakan layanan kami ♨"
# ─── Notifikasi Telegram (DELETE) ───
local message=$(cat <<EOF
🔹 DELETE AKUN ZIVPN 🔹
┌────────────────────────┐
│ Host   : $host
│ IP     : $ip
│ ISP    : $isp
│ Pass   : $password
│ Status : Deleted
└────────────────────────┘
♨ Terima kasih telah menggunakan layanan kami ♨
EOF
)

send_telegram_notification "$message"
        return 0
    else
        # If config update fails, do not touch the db file and report error
        rm -f "$tmp_config_file" # Clean up temp file
        echo "Error: Failed to update config.json. No changes were made."
        return 1
    fi
}

function delete_account() {
    clear
    echo "--- Delete Account ---"
    _display_accounts
    echo "" # Add a newline for better spacing
    read -p "Enter password to delete: " password
    if [ -z "$password" ]; then
        echo "Password cannot be empty."
        return
    fi

    local result
    result=$(_delete_account_logic "$password")
    
    echo "$result" # Display the result from the logic function
    read -p "Tekan Enter untuk kembali ke menu..."
}

function change_domain() {
    echo "--- Change Domain ---"
    read -p "Enter the new domain name for the SSL certificate: " domain
    if [ -z "$domain" ]; then
        echo "Domain name cannot be empty."
        return
    fi

    echo "Generating new certificate for domain '${domain}'..."
    openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
        -subj "/C=US/ST=California/L=Los Angeles/O=Example Corp/OU=IT Department/CN=${domain}" \
        -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt"

    echo "New certificate generated."
    restart_zivpn
}

function _display_accounts() {
    local db_file="/etc/zivpn/users.db"

    if [ ! -f "$db_file" ] || [ ! -s "$db_file" ]; then
        echo "No accounts found."
        return
    fi

    local current_date
    current_date=$(date +%s)
    printf "%-20s | %s\n" "Password" "Expires in (days)"
    echo "------------------------------------------"
    while IFS=':' read -r password expiry_date; do
        if [[ -n "$password" ]]; then
            local remaining_seconds=$((expiry_date - current_date))
            if [ $remaining_seconds -gt 0 ]; then
                local remaining_days=$((remaining_seconds / 86400))
                printf "%-20s | %s days\n" "$password" "$remaining_days"
            else
                printf "%-20s | Expired\n" "$password"
            fi
        fi
    done < "$db_file"
    echo "------------------------------------------"
}

function list_accounts() {
    clear
    echo "--- Active Accounts ---"
    _display_accounts
    echo "" # Add a newline for better spacing
    read -p "Press Enter to return to the menu..."
}

function format_kib_to_human() {
    local kib=$1
    if ! [[ "$kib" =~ ^[0-9]+$ ]] || [ -z "$kib" ]; then
        kib=0
    fi
    
    # Using awk for floating point math
    if [ "$kib" -lt 1048576 ]; then
        awk -v val="$kib" 'BEGIN { printf "%.2f MiB", val / 1024 }'
    else
        awk -v val="$kib" 'BEGIN { printf "%.2f GiB", val / 1048576 }'
    fi
}

function get_main_interface() {
    # Find the default network interface using the IP route. This is the most reliable method.
    ip -o -4 route show to default | awk '{print $5}' | head -n 1
}

function _draw_info_panel() {
    # --- Fetch Data ---
    local os_info isp_info ip_info host_info bw_today bw_month client_name license_exp

    os_info=$( (hostnamectl 2>/dev/null | grep "Operating System" | cut -d: -f2 | sed 's/^[ \t]*//') || echo "N/A" )
    os_info=${os_info:-"N/A"}

    local ip_data
    ip_data=$(curl -s ipinfo.io)
    ip_info=$(echo "$ip_data" | jq -r '.ip // "N/A"')
    isp_info=$(echo "$ip_data" | jq -r '.org // "N/A"')
    ip_info=${ip_info:-"N/A"}
    isp_info=${isp_info:-"N/A"}

    local CERT_CN
    CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p' 2>/dev/null || echo "")
    if [ "$CERT_CN" == "zivpn" ] || [ -z "$CERT_CN" ]; then
        host_info=$ip_info
    else
        host_info=$CERT_CN
    fi
    host_info=${host_info:-"N/A"}

    if command -v vnstat &> /dev/null; then
        local iface
        iface=$(get_main_interface)
        local current_year current_month current_day
        current_year=$(date +%Y)
        current_month=$(date +%-m) # Use %-m to avoid leading zero
        current_day=$(date +%-d) # Use %-d to avoid leading zero for days < 10

        # Daily
         
    
        

