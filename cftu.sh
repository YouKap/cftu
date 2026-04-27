#!/bin/bash

# --- 顏色定義 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

# --- 項目配置 ---
SCRIPT_URL="https://raw.githubusercontent.com/YouKap/cftu/main/cftu.sh"
CF_DIR="/etc/cloudflared"
CREDS_DIR="/root/.cloudflared"

# --- 確保以 Root 權限執行 ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}錯誤: 本腳本必須以 root 權限執行！${PLAIN}" 
   exit 1
fi

# --- 自我安裝邏輯 (適配 curl | bash) ---
if [[ "$0" != "/usr/local/bin/cftu" ]]; then
    echo -e "${BLUE}>>> 正在安裝 cftu 至全域指令...${PLAIN}"
    curl -sSL "$SCRIPT_URL" -o /usr/local/bin/cftu
    chmod +x /usr/local/bin/cftu
    echo -e "${GREEN}>>> 安裝成功！請輸入 cftu 啟動。${PLAIN}"
    # 這裡直接執行安裝好的腳本並退出當前管道
    exec /usr/local/bin/cftu
fi

# ==========================================
# 核心功能模組 (加入 < /dev/tty 確保不閃爍)
# ==========================================

# 1. 安裝環境
install_cf() {
    clear
    echo -e "${BLUE}正在安裝 Cloudflared 環境...${PLAIN}"
    apt-get update && apt-get install -y curl wget gnupg sudo systemd awk nano
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | sudo tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
    apt-get update && apt-get install cloudflared -y
    echo -e "${GREEN}環境安裝完成！${PLAIN}"
    read -rp "按回車鍵返回主選單..." dummy < /dev/tty
}

# 3. ➕ 新建通道
create_tunnel() {
    echo -e "${BLUE}=== ➕ 創建全新通道 ===${PLAIN}"
    read -rp "1. 請設定通道名稱: " TUN_NAME < /dev/tty
    [[ -z "$TUN_NAME" ]] && return

    read -rp "2. 請設定綁定網域: " TUN_DOMAIN < /dev/tty
    read -rp "3. 請設定本地目標 (例 http://127.0.0.1:80): " TUN_TARGET < /dev/tty

    echo -e "${YELLOW}正在創建通道...${PLAIN}"
    cloudflared tunnel create "$TUN_NAME"
    
    UUID=$(cloudflared tunnel list | grep -w "$TUN_NAME" | awk '{print $1}')
    [[ -z "$UUID" ]] && { echo -e "${RED}創建失敗！${PLAIN}"; sleep 2; return; }

    # 生成標準 YAML
    cat > ${CF_DIR}/${TUN_NAME}.yml << EOF
tunnel: ${UUID}
credentials-file: ${CREDS_DIR}/${UUID}.json

protocol: http2
ha-connections: 8
no-multistream: true

ingress:
  - hostname: ${TUN_DOMAIN}
    service: ${TUN_TARGET}
  - service: http_status:404
EOF

    # 生成 Systemd 服務
    cat > /etc/systemd/system/${TUN_NAME}.service << EOF
[Unit]
Description=CF-Tunnel-${TUN_NAME}
After=network.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel --config ${CF_DIR}/${TUN_NAME}.yml run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable --now ${TUN_NAME}
    echo -e "${GREEN}>>> 通道 ${TUN_NAME} 啟動成功！${PLAIN}"
    read -rp "按回車鍵返回..." dummy < /dev/tty
}

# 4. ⚙️ 管理現有通道 (動態識別)
manage_tunnels() {
    while true; do
        clear
        echo -e "${BLUE}=== ⚙️ 管理現有通道 ===${PLAIN}"
        # 掃描 yml 檔案
        TUNNELS=( $(ls -1 $CF_DIR/*.yml 2>/dev/null | xargs -n 1 basename | sed 's/\.yml//g') )
        
        if [ ${#TUNNELS[@]} -eq 0 ]; then
            echo -e "${YELLOW}暫無通道項目。${PLAIN}"; sleep 2; return
        fi

        for i in "${!TUNNELS[@]}"; do
            echo -e " ${YELLOW}$((i+1)).${PLAIN} 通道: ${BLUE}${TUNNELS[$i]}${PLAIN}"
        done
        echo -e " 0. 返回主選單"
        
        read -rp "請選擇數字: " T_CHOICE < /dev/tty
        [[ -z "$T_CHOICE" || "$T_CHOICE" == "0" ]] && return
        
        TARGET="${TUNNELS[$((T_CHOICE-1))]}"
        
        # 子選單
        echo -e "\n正在管理: ${GREEN}$TARGET${PLAIN}"
        echo -e "1. 查看日誌 | 2. 重啟 | 3. 編輯配置 | 4. ${RED}徹底刪除${PLAIN}"
        read -rp "請選擇操作: " ACT < /dev/tty
        
        case $act in
            1) journalctl -u ${TARGET}.service -f ;;
            2) systemctl restart ${TARGET}.service && echo "已重啟"; sleep 1 ;;
            3) nano ${CF_DIR}/${TARGET}.yml && systemctl restart ${TARGET}.service ;;
            4) 
               read -rp "確認刪除 ${TARGET}? (y/n): " confirm < /dev/tty
               if [[ "$confirm" == "y" ]]; then
                   systemctl stop ${TARGET} && systemctl disable ${TARGET}
                   UUID_DEL=$(grep 'tunnel:' ${CF_DIR}/${TARGET}.yml | awk '{print $2}')
                   rm -f /etc/systemd/system/${TARGET}.service ${CF_DIR}/${TARGET}.yml ${CREDS_DIR}/${UUID_DEL}.json
                   systemctl daemon-reload
                   echo "已清理。"; sleep 1; return
               fi
               ;;
        esac
    done
}

# 5. 📊 運行狀態
show_status() {
    echo -e "${BLUE}=== 📊 運行狀態總覽 ===${PLAIN}"
    systemctl list-units "cf-*" --all | grep service || echo "目前無 cf- 開頭的服務"
    echo -e "-------------------------------------------------"
    read -rp "按回車鍵返回..." dummy < /dev/tty
}

# ==========================================
# 主選單渲染
# ==========================================
while true; do
    clear
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "  🚀 ${GREEN}Cloudflare Tunnel (cftu) 管理面板${PLAIN}  "
    echo -e "      快捷指令: cftu  |  版本: 1.0.1"
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "${YELLOW} 1.${PLAIN} 初始化環境並安裝 Cloudflared"
    echo -e "${YELLOW} 2.${PLAIN} 登入 Cloudflare 帳號 (取得授權)"
    echo -e "-------------------------------------------------"
    echo -e "${YELLOW} 3.${PLAIN} ${GREEN}➕ 新建並發佈通道 (自動生成配置)${PLAIN}"
    echo -e "${YELLOW} 4.${PLAIN} ⚙️  管理/修改/刪除 現有通道"
    echo -e "${YELLOW} 5.${PLAIN} 📊 查看所有通道運行狀態"
    echo -e "-------------------------------------------------"
    echo -e "${YELLOW} 0.${PLAIN} 退出腳本"
    echo -e "${BLUE}=================================================${PLAIN}"
    
    read -rp "請輸入數字選擇功能 [0-5]: " choice < /dev/tty

    [[ -z "$choice" ]] && continue

    case $choice in
        1) install_cf ;;
        2) cloudflared tunnel login ;;
        3) create_tunnel ;;
        4) manage_tunnels ;;
        5) show_status ;;
        0) exit 0 ;;
        *) echo -e "${RED}無效選擇${PLAIN}"; sleep 1 ;;
    esac
done
