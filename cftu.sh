#!/bin/bash

# --- 顏色定義 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

# ==========================================
# ⚠️ 請將下方的網址替換為您腳本的真實 GitHub Raw 網址
# ==========================================
SCRIPT_URL="https://raw.githubusercontent.com/YouKap/cftu/main/cftu.sh"

# --- 確保以 Root 權限執行 ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}錯誤: 本腳本必須以 root 權限執行！${PLAIN}" 
   exit 1
fi

# --- 自我安裝與全域環境註冊邏輯 ---
if [[ "$0" != "/usr/local/bin/cftu" ]]; then
    echo -e "${BLUE}>>> 檢測到首次安裝或管道執行，正在將腳本註冊至系統全域...${PLAIN}"
    curl -sSL "$SCRIPT_URL" -o /usr/local/bin/cftu
    chmod +x /usr/local/bin/cftu
    echo -e "${GREEN}>>> 腳本已成功安裝為全域指令 'cftu'！${PLAIN}"
    sleep 1
    exec /usr/local/bin/cftu
fi

# --- 基礎目錄 ---
CF_DIR="/etc/cloudflared"
mkdir -p "$CF_DIR"
chown -R root:root "$CF_DIR"

# ==========================================
# 核心功能模組
# ==========================================

# 1. 安裝環境與 Cloudflared
install_env_and_cf() {
    echo -e "${BLUE}>>> 開始初始化 Debian 環境與安裝 Cloudflared...${PLAIN}"
    apt-get update -y
    apt-get install -y curl wget gnupg sudo systemd awk nano

    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | sudo tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
    apt-get update -y && apt-get install cloudflared -y
    
    echo -e "${GREEN}>>> 基礎環境與 Cloudflared 安裝完成！${PLAIN}"
    read -p "按 Enter 鍵返回主選單..."
}

# 2. 登入與授權
login_cf() {
    echo -e "${BLUE}>>> 準備登入 Cloudflare 帳號...${PLAIN}"
    echo -e "${YELLOW}請複製下方出現的網址到瀏覽器中打開，並授權您的網域。${PLAIN}"
    cloudflared tunnel login
    echo -e "${GREEN}>>> 授權完成！(憑證預設存於 /root/.cloudflared/cert.pem)${PLAIN}"
    read -p "按 Enter 鍵返回主選單..."
}

# 3. 新建並發佈通道
create_tunnel() {
    echo -e "${BLUE}=== ➕ 創建全新 Cloudflare 通道 ===${PLAIN}"
    if [ ! -f /root/.cloudflared/cert.pem ]; then
        echo -e "${RED}錯誤: 找不到登入憑證！請先執行選單 [2] 進行登入授權。${PLAIN}"
        sleep 2; return
    fi

    read -p "1. 請設定通道名稱 (例如: cf-pro, cf-king): " TUN_NAME
    if [[ -z "$TUN_NAME" ]]; then echo -e "${RED}名稱不可為空！${PLAIN}"; sleep 2; return; fi

    read -p "2. 請設定綁定網域 (例如: zoop.duntok.com): " TUN_DOMAIN
    read -p "3. 請設定本地目標地址 (例如: http://127.0.0.1:41880): " TUN_TARGET

    echo -e "${YELLOW}正在創建通道 $TUN_NAME ...${PLAIN}"
    cloudflared tunnel create "$TUN_NAME"
    
    # 精準獲取 UUID
    UUID=$(cloudflared tunnel list | grep -w "$TUN_NAME" | awk '{print $1}')
    if [[ -z "$UUID" ]]; then
        echo -e "${RED}通道創建失敗或無法獲取 UUID！${PLAIN}"
        sleep 3; return
    fi

    echo -e "${GREEN}通道建立成功！UUID: $UUID${PLAIN}"

    # 按照您的要求生成標準化 YAML (嚴格匹配格式)
    cat > ${CF_DIR}/${TUN_NAME}.yml << EOF
tunnel: ${UUID}
credentials-file: /root/.cloudflared/${UUID}.json

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
Description=Cloudflare Tunnel - ${TUN_NAME}
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel --config ${CF_DIR}/${TUN_NAME}.yml run
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now ${TUN_NAME}.service
    
    echo -e "${GREEN}>>> 通道 ${TUN_NAME} 已成功啟動並運行！${PLAIN}"
    echo -e "${YELLOW}!!! 請記得到 Cloudflare 網頁後台，將 ${TUN_DOMAIN} 的 CNAME 指向: ${UUID}.cfargotunnel.com !!!${PLAIN}"
    read -p "按 Enter 鍵返回主選單..."
}

# 4. 動態管理現有通道
manage_tunnels() {
    while true; do
        clear
        echo -e "${BLUE}=== ⚙️ 管理現有通道 ===${PLAIN}"
        
        # 動態抓取所有 .yml 配置文件作為通道列表
        TUNNELS=( $(ls -1 $CF_DIR/*.yml 2>/dev/null | xargs -n 1 basename | sed 's/\.yml//g') )
        
        if [ ${#TUNNELS[@]} -eq 0 ]; then
            echo -e "${YELLOW}目前沒有找到任何已部署的通道。${PLAIN}"
            read -p "按 Enter 鍵返回..."
            return
        fi

        echo -e "${GREEN}請選擇您要管理的通道：${PLAIN}"
        # 動態渲染選單項目 (例如: 1. 通道: cf-pro)
        for i in "${!TUNNELS[@]}"; do
            STATUS_CHECK=$(systemctl is-active ${TUNNELS[$i]}.service 2>/dev/null)
            if [[ "$STATUS_CHECK" == "active" ]]; then
                STATUS_TEXT="${GREEN}運行中${PLAIN}"
            else
                STATUS_TEXT="${RED}已停止${PLAIN}"
            fi
            echo -e " ${YELLOW}$((i+1)).${PLAIN} 通道: ${BLUE}${TUNNELS[$i]}${PLAIN} [狀態: $STATUS_TEXT]"
        done
        echo -e "-------------------------------------------------"
        echo -e " ${YELLOW}0.${PLAIN} 返回主選單"
        
        read -p "請輸入數字選擇 [0-$(( ${#TUNNELS[@]} ))]: " TUN_CHOICE
        
        if [[ "$TUN_CHOICE" == "0" ]]; then
            return
        fi

        # 驗證輸入合法性
        if ! [[ "$TUN_CHOICE" =~ ^[0-9]+$ ]] || [ "$TUN_CHOICE" -gt "${#TUNNELS[@]}" ] || [ "$TUN_CHOICE" -lt 1 ]; then
            echo -e "${RED}無效的選擇！${PLAIN}"; sleep 1; continue
        fi

        TARGET_SVC="${TUNNELS[$((TUN_CHOICE-1))]}"
        
        # 進入單一通道的「專屬子選單」
        manage_single_tunnel "$TARGET_SVC"
    done
}

# 4.1 單一通道管理子模組
manage_single_tunnel() {
    local TARGET_SVC=$1
    while true; do
        clear
        echo -e "${BLUE}=================================================${PLAIN}"
        echo -e "      ⚙️ 正在管理通道: ${GREEN}${TARGET_SVC}${PLAIN}"
        echo -e "${BLUE}=================================================${PLAIN}"
        echo -e "${YELLOW} 1.${PLAIN} 查看實時日誌 (排錯專用)"
        echo -e "${YELLOW} 2.${PLAIN} 重啟該通道服務"
        echo -e "${YELLOW} 3.${PLAIN} 停止該通道服務"
        echo -e "${YELLOW} 4.${PLAIN} 修改目標路由 (編輯 .yml 配置)"
        echo -e "-------------------------------------------------"
        echo -e "${YELLOW} 5.${PLAIN} ${RED}🗑️ 徹底刪除該通道${PLAIN}"
        echo -e "-------------------------------------------------"
        echo -e "${YELLOW} 0.${PLAIN} 返回上一層列表"
        echo -e "${BLUE}=================================================${PLAIN}"
        
        read -p "請選擇操作 [0-5]: " ACTION

        case $ACTION in
            1) journalctl -u ${TARGET_SVC}.service -f ;;
            2) systemctl restart ${TARGET_SVC}.service && echo -e "${GREEN}已重啟！${PLAIN}"; sleep 1 ;;
            3) systemctl stop ${TARGET_SVC}.service && echo -e "${YELLOW}已停止！${PLAIN}"; sleep 1 ;;
            4) 
               nano ${CF_DIR}/${TARGET_SVC}.yml
               systemctl restart ${TARGET_SVC}.service
               echo -e "${GREEN}配置已保存並自動重啟生效！${PLAIN}"; sleep 2
               ;;
            5)
               read -p "⚠️ 確定要徹底刪除 ${TARGET_SVC} 嗎？此操作不可逆！(y/n): " CONFIRM
               if [[ "$CONFIRM" == "y" ]]; then
                   systemctl stop ${TARGET_SVC}.service
                   systemctl disable ${TARGET_SVC}.service
                   # 精準刪除憑證與配置
                   UUID=$(grep 'tunnel:' ${CF_DIR}/${TARGET_SVC}.yml | awk '{print $2}')
                   rm -f /root/.cloudflared/${UUID}.json
                   rm -f /etc/systemd/system/${TARGET_SVC}.service
                   rm -f ${CF_DIR}/${TARGET_SVC}.yml
                   systemctl daemon-reload
                   cloudflared tunnel delete ${TARGET_SVC} 2>/dev/null
                   echo -e "${GREEN}通道 ${TARGET_SVC} 已從伺服器與 Cloudflare 徹底清除！${PLAIN}"
                   sleep 2
                   return # 刪除後自動返回上一層選單
               fi
               ;;
            0) return ;;
            *) echo -e "${RED}無效選擇${PLAIN}"; sleep 1 ;;
        esac
    done
}

# 5. 查看狀態總覽
show_status() {
    echo -e "${BLUE}=== 📊 系統通道狀態總覽 ===${PLAIN}"
    TUNNELS=( $(ls -1 $CF_DIR/*.yml 2>/dev/null | xargs -n 1 basename | sed 's/\.yml//g') )
    if [ ${#TUNNELS[@]} -eq 0 ]; then
        echo -e "${YELLOW}沒有找到任何配置好的通道。${PLAIN}"
    else
        for t in "${TUNNELS[@]}"; do
            STATUS=$(systemctl is-active ${t}.service 2>/dev/null)
            if [[ "$STATUS" == "active" ]]; then
                echo -e "通道 [${GREEN}${t}${PLAIN}] : ${GREEN}正常運行中 (Running)${PLAIN}"
            else
                echo -e "通道 [${RED}${t}${PLAIN}] : ${RED}異常或停止 ($STATUS)${PLAIN}"
            fi
        done
    fi
    echo -e "-------------------------------------------------"
    read -p "按 Enter 鍵返回主選單..."
}

# 6. 更新腳本自身
update_script() {
    echo -e "${BLUE}>>> 正在檢查並更新 cftu 腳本...${PLAIN}"
    curl -sSL "$SCRIPT_URL" -o /usr/local/bin/cftu
    chmod +x /usr/local/bin/cftu
    echo -e "${GREEN}>>> 更新完成！正在重啟面板...${PLAIN}"
    sleep 1
    exec /usr/local/bin/cftu
}

# ==========================================
# 主選單渲染
# ==========================================
while true; do
    clear
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "  🚀 ${GREEN}Cloudflare Tunnel (cftu) 全自動管理面板${PLAIN}  "
    echo -e "      適用環境: Debian 11/12+ | 狀態: 全域已安裝"
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "${YELLOW} 1.${PLAIN} 初始化 Debian 環境並安裝 Cloudflared"
    echo -e "${YELLOW} 2.${PLAIN} 登入 Cloudflare 帳號 (取得授權)"
    echo -e "-------------------------------------------------"
    echo -e "${YELLOW} 3.${PLAIN} ${GREEN}➕ 新建並發佈通道 (自動生成標準配置)${PLAIN}"
    echo -e "${YELLOW} 4.${PLAIN} ⚙️  管理/修改/刪除 現有通道 ${BLUE}(動態選單)${PLAIN}"
    echo -e "${YELLOW} 5.${PLAIN} 📊 查看所有通道運行狀態"
    echo -e "-------------------------------------------------"
    echo -e "${YELLOW} 6.${PLAIN} 🔄 更新本腳本"
    echo -e "${YELLOW} 0.${PLAIN} 退出腳本"
    echo -e "${BLUE}=================================================${PLAIN}"
    read -p "請輸入數字選擇功能 [0-6]: " choice

    case $choice in
        1) install_env_and_cf ;;
        2) login_cf ;;
        3) create_tunnel ;;
        4) manage_tunnels ;;
        5) show_status ;;
        6) update_script ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}無效的輸入，請重新選擇!${PLAIN}"; sleep 1 ;;
    esac
done
