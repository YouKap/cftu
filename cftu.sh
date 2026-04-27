#!/bin/bash

# --- 顏色定義 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

SCRIPT_URL="https://raw.githubusercontent.com/YouKap/cftu/main/cftu.sh"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}錯誤: 本腳本必須以 root 權限執行！${PLAIN}" 
   exit 1
fi

CF_DIR="/etc/cloudflared"
mkdir -p "$CF_DIR"

# 1. 安裝環境
install_env_and_cf() {
    echo -e "${BLUE}>>> 開始安裝 Cloudflared...${PLAIN}"
    apt-get update -y && apt-get install -y curl wget gnupg sudo systemd awk nano
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | sudo tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
    apt-get update -y && apt-get install cloudflared -y
    echo -e "${GREEN}>>> 安裝完成！${PLAIN}"
    read -rp "按 Enter 鍵返回..." dummy
}

# 2. 登入
login_cf() {
    cloudflared tunnel login
    read -rp "按 Enter 鍵返回..." dummy
}

# 3. 創建通道
create_tunnel() {
    echo -e "${BLUE}=== ➕ 創建新通道 ===${PLAIN}"
    read -rp "1. 通道名稱: " TUN_NAME
    [[ -z "$TUN_NAME" ]] && return
    read -rp "2. 綁定網域: " TUN_DOMAIN
    read -rp "3. 本地目標 (例 http://127.0.0.1:80): " TUN_TARGET
    
    cloudflared tunnel create "$TUN_NAME"
    UUID=$(cloudflared tunnel list | grep -w "$TUN_NAME" | awk '{print $1}')
    
    cat > ${CF_DIR}/${TUN_NAME}.yml << EOL
tunnel: ${UUID}
credentials-file: /root/.cloudflared/${UUID}.json
protocol: http2
ha-connections: 8
no-multistream: true
ingress:
  - hostname: ${TUN_DOMAIN}
    service: ${TUN_TARGET}
  - service: http_status:404
EOL

    cat > /etc/systemd/system/${TUN_NAME}.service << EOL
[Unit]
Description=Cloudflare Tunnel - ${TUN_NAME}
After=network-online.target
[Service]
ExecStart=/usr/bin/cloudflared tunnel --config ${CF_DIR}/${TUN_NAME}.yml run
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOL

    systemctl daemon-reload && systemctl enable --now ${TUN_NAME}
    echo -e "${GREEN}>>> 創建成功！${PLAIN}"
    read -rp "按 Enter 鍵返回..." dummy
}

# 4. 管理通道
manage_tunnels() {
    while true; do
        clear
        echo -e "${BLUE}=== ⚙️ 管理現有通道 ===${PLAIN}"
        TUNNELS=( $(ls -1 $CF_DIR/*.yml 2>/dev/null | xargs -n 1 basename | sed 's/\.yml//g') )
        if [ ${#TUNNELS[@]} -eq 0 ]; then echo "無通道"; sleep 1; return; fi
        for i in "${!TUNNELS[@]}"; do
            echo -e " ${YELLOW}$((i+1)).${PLAIN} ${TUNNELS[$i]}"
        done
        echo -e " 0. 返回"
        read -rp "選擇: " T_CHOICE
        [[ "$T_CHOICE" == "0" || -z "$T_CHOICE" ]] && return
        TARGET_SVC="${TUNNELS[$((T_CHOICE-1))]}"
        
        # 簡易子選單
        echo -e "1.日誌 2.重啟 3.刪除"
        read -rp "操作: " ACT
        case $ACT in
            1) journalctl -u ${TARGET_SVC}.service -f ;;
            2) systemctl restart ${TARGET_SVC}.service ;;
            3) 
               systemctl stop ${TARGET_SVC} && systemctl disable ${TARGET_SVC}
               rm -f /etc/systemd/system/${TARGET_SVC}.service ${CF_DIR}/${TARGET_SVC}.yml
               echo "已刪除"; sleep 1; return ;;
        esac
    done
}

# 5. 狀態
show_status() {
    systemctl list-units "cf-*" --all
    read -rp "按 Enter 鍵返回..." dummy
}

# 主循環
while true; do
    clear
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "  🚀 ${GREEN}Cloudflare Tunnel (cftu) 管理面板${PLAIN}"
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e " 1. 安裝環境"
    echo -e " 2. 授權登入"
    echo -e " 3. ➕ 新建通道"
    echo -e " 4. ⚙️  管理通道"
    echo -e " 5. 📊 運行狀態"
    echo -e " 0. 退出"
    echo -e "${BLUE}=================================================${PLAIN}"
    
    read -rp "請輸入數字 [0-5]: " choice

    case $choice in
        1) install_env_and_cf ;;
        2) login_cf ;;
        3) create_tunnel ;;
        4) manage_tunnels ;;
        5) show_status ;;
        0) exit 0 ;;
        *) sleep 1 ;;
    esac
done
