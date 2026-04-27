#!/bin/bash

# --- 顏色定義 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

SCRIPT_URL="https://raw.githubusercontent.com/YouKap/cftu/main/cftu.sh"
CF_DIR="/etc/cloudflared"
CREDS_DIR="/root/.cloudflared"

# 確保以 Root 權限執行
[[ $EUID -ne 0 ]] && echo -e "${RED}錯誤: 必須以 root 執行！${PLAIN}" && exit 1

# 自我安裝與執行環境校正
if [[ "$0" != "/usr/local/bin/cftu" ]]; then
    echo -e "${BLUE}>>> 正在同步腳本至全域環境...${PLAIN}"
    curl -sSL "$SCRIPT_URL" -o /usr/local/bin/cftu && chmod +x /usr/local/bin/cftu
    exec /usr/local/bin/cftu
fi

# ==========================================
# 核心功能模組
# ==========================================

install_cf() {
    clear
    echo -e "${BLUE}正在安裝 Cloudflared 環境...${PLAIN}"
    mkdir -p /etc/cloudflared
    apt-get update && apt-get install -y curl wget gnupg sudo systemd mawk nano
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | sudo tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
    apt-get update && apt-get install cloudflared -y
    read -rp "安裝完成，按回車鍵返回..." dummy < /dev/tty
}

create_tunnel() {
    mkdir -p "$CF_DIR"
    local STEP_TITLE="${BLUE}=== ➕ 創建全新通道與深度 DNS 綁定 ===${PLAIN}"
    
    # 步驟 1: 通道名稱
    while true; do
        clear
        echo -e "$STEP_TITLE"
        [[ ! -f /root/.cloudflared/cert.pem ]] && echo -e "${RED}錯誤: 未檢測到登入憑證，請先執行選單 2。${PLAIN}" && sleep 2 && return
        
        read -rp "1. 通道名稱 (自定義): " TUN_NAME < /dev/tty
        [[ -z "$TUN_NAME" ]] && return
        break
    done

    # 步驟 2: 綁定網域 (增加回退刷新邏輯)
    while true; do
        clear
        echo -e "$STEP_TITLE"
        echo -e "1. 通道名稱: ${GREEN}$TUN_NAME${PLAIN}"
        read -rp "2. 綁定網域 (如 www.google.com): " TUN_DOMAIN < /dev/tty
        
        # 驗證網域格式
        if [[ "$TUN_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
            break
        else
            echo -e "${RED}錯誤: [${TUN_DOMAIN}] 網域格式不正確！${PLAIN}"
            sleep 1.5 # 停留一下讓用戶看清錯誤訊息
        fi
    done

    # 步驟 3: 本地端口 (增加範圍校驗)
    USED_PORTS=$(grep -roE "127\.0\.0\.1:[0-9]+" $CF_DIR/*.yml 2>/dev/null | awk -F: '{print $NF}')
    while true; do
        clear
        echo -e "$STEP_TITLE"
        echo -e "1. 通道名稱: ${GREEN}$TUN_NAME${PLAIN}"
        echo -e "2. 綁定網域: ${GREEN}$TUN_DOMAIN${PLAIN}"
        echo -e "3. 本地端口 (回車自動分配)"
        read -rp "   輸入端口號 [1-65535]: " TUN_PORT < /dev/tty
        
        if [[ -z "$TUN_PORT" ]]; then
            while true; do
                TUN_PORT=$(shuf -i 10000-60000 -n 1)
                [[ ! "$USED_PORTS" =~ "$TUN_PORT" ]] && break
            done
            echo -e "${YELLOW}>>> 已分配隨機端口: ${TUN_PORT}${PLAIN}"
            sleep 1
            break
        elif [[ "$TUN_PORT" =~ ^[0-9]+$ ]] && [ "$TUN_PORT" -ge 1 ] && [ "$TUN_PORT" -le 65535 ]; then
            if [[ "$USED_PORTS" =~ "$TUN_PORT" ]]; then
                echo -e "${RED}警告: 端口 ${TUN_PORT} 已被佔用！${PLAIN}"
                read -rp "強制使用？(y/N): " p_force < /dev/tty
                [[ "$p_force" == "y" ]] && break
            else
                break
            fi
        else
            echo -e "${RED}錯誤: 端口號必須是 1-65535 之間的數字！${PLAIN}"
            sleep 1.5
        fi
    done
    
    TUN_TARGET="http://127.0.0.1:${TUN_PORT}"

    echo -e "${YELLOW}正在雲端創建通道...${PLAIN}"
    CREATE_OUT=$(cloudflared tunnel create "$TUN_NAME" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}創建失敗: $CREATE_OUT${PLAIN}"
        read -rp "回車返回..." d < /dev/tty && return
    fi
    UUID=$(echo "$CREATE_OUT" | grep -oE "[0-9a-f-]{36}" | head -1)

    echo -e "${YELLOW}正在執行深度 DNS 綁定 [${TUN_DOMAIN}]...${PLAIN}"
    cloudflared tunnel route dns -f "$TUN_NAME" "$TUN_DOMAIN" > /dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        DNS_STATUS="${GREEN}✅ 深度綁定成功 (面板已顯示 Tunnel 類型)${PLAIN}"
    else
        cloudflared tunnel route dns "$TUN_NAME" "$TUN_DOMAIN" > /dev/null 2>&1
        [[ $? -eq 0 ]] && DNS_STATUS="${GREEN}✅ 綁定成功${PLAIN}" || DNS_STATUS="${RED}❌ 綁定失敗 (請手動檢查 DNS 面板)${PLAIN}"
    fi

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
    
    echo -e "-------------------------------------------------"
    echo -e "${GREEN}>>> 部署成功！${PLAIN}"
    echo -e "通道名稱: ${BLUE}${TUN_NAME}${PLAIN}"
    echo -e "綁定網域: ${BLUE}${TUN_DOMAIN}${PLAIN}"
    echo -e "DNS 狀態: ${DNS_STATUS}"
    echo -e "本地服務: ${BLUE}${TUN_TARGET}${PLAIN}"
    echo -e "-------------------------------------------------"
    read -rp "回車返回主選單..." d < /dev/tty
}

manage_tunnels() {
    while true; do
        clear
        echo -e "${BLUE}=== ⚙️ 管理現有通道 ===${PLAIN}"
        TUNNELS=( $(ls -1 $CF_DIR/*.yml 2>/dev/null | xargs -n 1 basename | sed 's/\.yml//g') )
        
        if [ ${#TUNNELS[@]} -eq 0 ]; then
            echo -e "${YELLOW}暫無通道項目。${PLAIN}"; read -rp "按回車返回..." d < /dev/tty; return
        fi

        for i in "${!TUNNELS[@]}"; do
            ST=$(systemctl is-active ${TUNNELS[$i]}.service 2>/dev/null)
            [[ "$ST" == "active" ]] && S_TEXT="${GREEN}● 運行中${PLAIN}" || S_TEXT="${RED}○ 已停止${PLAIN}"
            echo -e " ${YELLOW}$((i+1)).${PLAIN} 通道: ${BLUE}${TUNNELS[$i]}${PLAIN} [$S_TEXT]"
        done
        echo -e " 0. 返回主選單"
        
        read -rp "請選擇編號: " T_CHOICE < /dev/tty
        [[ -z "$T_CHOICE" || "$T_CHOICE" == "0" ]] && return
        
        TARGET="${TUNNELS[$((T_CHOICE-1))]}"
        
        echo -e "\n當前操作: ${CYAN}${TARGET}${PLAIN}"
        echo -e " 1. 檢視日誌 | 2. 重啟服務 | 3. 編輯配置 | 4. ${RED}徹底刪除${PLAIN}"
        read -rp "選擇操作 [1-4]: " ACT < /dev/tty
        
        case $ACT in
            1) journalctl -u ${TARGET}.service -n 50 --no-pager; read -rp "回車返回..." d < /dev/tty ;;
            2) systemctl restart ${TARGET}.service && echo -e "${GREEN}重啟成功${PLAIN}"; sleep 1 ;;
            3) nano ${CF_DIR}/${TARGET}.yml < /dev/tty && systemctl restart ${TARGET}.service; echo -e "${GREEN}已重啟${PLAIN}"; sleep 1 ;;
            4) 
               echo -e "${RED}警告：這將同步刪除雲端隧道與 DNS 記錄！${PLAIN}"
               read -rp "確定刪除 ${TARGET} 嗎？[y/N]: " confirm < /dev/tty
               if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                   UUID_DEL=$(grep 'tunnel:' ${CF_DIR}/${TARGET}.yml | awk '{print $2}')
                   DOM_DEL=$(grep 'hostname:' ${CF_DIR}/${TARGET}.yml | awk '{print $2}')
                   
                   systemctl stop ${TARGET} 2>/dev/null
                   systemctl disable ${TARGET} 2>/dev/null
                   
                   if [[ -n "$UUID_DEL" ]]; then
                       [[ -n "$DOM_DEL" ]] && cloudflared tunnel route dns cleanup "$DOM_DEL" >/dev/null 2>&1
                       cloudflared tunnel delete -f "$UUID_DEL" >/dev/null 2>&1
                   fi

                   rm -f /etc/systemd/system/${TARGET}.service ${CF_DIR}/${TARGET}.yml ${CREDS_DIR}/${UUID_DEL}.json
                   systemctl daemon-reload
                   echo -e "${GREEN}✅ 徹底刪除完成！${PLAIN}"; sleep 2; return
               fi ;;
        esac
    done
}

show_status() {
    clear
    echo -e "${BLUE}=== 📊 運行狀態總覽 ===${PLAIN}"
    TUNNELS=( $(ls -1 $CF_DIR/*.yml 2>/dev/null | xargs -n 1 basename | sed 's/\.yml//g') )
    if [[ ${#TUNNELS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}目前沒有任何已配置的通道。${PLAIN}"
    else
        for t in "${TUNNELS[@]}"; do
            STATUS=$(systemctl is-active ${t}.service 2>/dev/null)
            [[ "$STATUS" == "active" ]] && echo -e "通道 [${GREEN}${t}${PLAIN}] : ${GREEN}正常運行中${PLAIN}" || echo -e "通道 [${RED}${t}${PLAIN}] : ${RED}未運行 ($STATUS)${PLAIN}"
        done
    fi
    echo -e "-------------------------------------------------"
    read -rp "按回車鍵返回..." dummy < /dev/tty
}

# --- 新增：選項 6 清理日誌並重啟 ---
clean_and_restart() {
    clear
    echo -e "${BLUE}=== 🧹 清理日誌並重啟所有服務 ===${PLAIN}"
    echo -e "${YELLOW}正在清理系統日誌空間...${PLAIN}"
    journalctl --rotate >/dev/null 2>&1
    journalctl --vacuum-time=1s >/dev/null 2>&1
    
    TUNNELS=( $(ls -1 $CF_DIR/*.yml 2>/dev/null | xargs -n 1 basename | sed 's/\.yml//g') )
    if [ ${#TUNNELS[@]} -eq 0 ]; then
         echo -e "${GREEN}無通道需要重啟。${PLAIN}"
    else
         for t in "${TUNNELS[@]}"; do
             echo -ne "正在重啟通道 ${CYAN}${t}${PLAIN} ... "
             systemctl restart ${t}.service && echo -e "${GREEN}[成功]${PLAIN}" || echo -e "${RED}[失敗]${PLAIN}"
         done
    fi
    echo -e "\n${GREEN}✅ 日誌清理與服務重啟完成！${PLAIN}"
    read -rp "按回車鍵返回主選單..." dummy < /dev/tty
}

# --- 新增：選項 7 徹底清理所有服務 ---
nuke_all_tunnels() {
    clear
    echo -e "${RED}=================================================${PLAIN}"
    echo -e "      ⚠️  警告：徹底清理所有服務與通道"
    echo -e "${RED}=================================================${PLAIN}"
    echo -e "這將會："
    echo -e " 1. 停止並刪除本地所有的通道服務"
    echo -e " 2. 撤銷所有關聯的 DNS 路由"
    echo -e " 3. 從 Cloudflare 雲端強制刪除所有通道實體\n"
    
    read -rp "您確定要執行此毀滅性操作嗎？請輸入 'YES' 確認: " confirm < /dev/tty
    if [[ "$confirm" == "YES" ]]; then
        TUNNELS=( $(ls -1 $CF_DIR/*.yml 2>/dev/null | xargs -n 1 basename | sed 's/\.yml//g') )
        if [ ${#TUNNELS[@]} -eq 0 ]; then
            echo -e "${YELLOW}沒有找到任何本地通道配置，無須清理。${PLAIN}"
        else
            for t in "${TUNNELS[@]}"; do
                echo -e "${BLUE}>>> 正在銷毀通道: ${t}${PLAIN}"
                UUID_DEL=$(grep 'tunnel:' ${CF_DIR}/${t}.yml | awk '{print $2}')
                DOM_DEL=$(grep 'hostname:' ${CF_DIR}/${t}.yml | awk '{print $2}')
                
                systemctl stop ${t} 2>/dev/null
                systemctl disable ${t} 2>/dev/null
                
                if [[ -n "$UUID_DEL" ]]; then
                    [[ -n "$DOM_DEL" ]] && cloudflared tunnel route dns cleanup "$DOM_DEL" >/dev/null 2>&1
                    cloudflared tunnel delete -f "$UUID_DEL" >/dev/null 2>&1
                fi
                
                rm -f /etc/systemd/system/${t}.service
                rm -f ${CF_DIR}/${t}.yml
                rm -f ${CREDS_DIR}/${UUID_DEL}.json
            done
            systemctl daemon-reload
            echo -e "\n${GREEN}✅ 所有通道服務已徹底從本地與雲端清理完畢！${PLAIN}"
        fi
    else
        echo -e "\n${BLUE}已取消操作。${PLAIN}"
    fi
    read -rp "按回車鍵返回主選單..." dummy < /dev/tty
}

# ==========================================
# 主介面循環
# ==========================================
while true; do
    clear
    [[ -f /usr/bin/cloudflared ]] && ICON1="${GREEN}(已安裝)${PLAIN}" || ICON1=""
    [[ -f /root/.cloudflared/cert.pem ]] && ICON2="${GREEN}(已授權)${PLAIN}" || ICON2=""
    
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "  🚀 ${GREEN}Cloudflare Tunnel (cftu) 管理面板${PLAIN}"
    echo -e "      快捷指令: cftu  |  版本: 1.0.0"
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "${YELLOW} 1.${PLAIN} 初始化環境並安裝 Cloudflared $ICON1"
    echo -e "${YELLOW} 2.${PLAIN} 登入 Cloudflare 帳號 $ICON2"
    echo -e "-------------------------------------------------"
    echo -e "${YELLOW} 3.${PLAIN} ${GREEN}➕ 新建並發佈通道 (自動生成配置)${PLAIN}"
    echo -e "${YELLOW} 4.${PLAIN} ⚙️  管理/修改/單獨刪除 現有通道"
    echo -e "${YELLOW} 5.${PLAIN} 📊 查看所有通道運行狀態"
    echo -e "-------------------------------------------------"
    echo -e "${YELLOW} 6.${PLAIN} 🧹 清理日誌並重啟所有服務"
    echo -e "${RED} 7.${PLAIN} 💥 徹底清理所有服務"
    echo -e "-------------------------------------------------"
    echo -e "${YELLOW} 0.${PLAIN} 退出腳本"
    echo -e "${BLUE}=================================================${PLAIN}"
    
    read -rp "請選擇數字 [0-7]: " choice < /dev/tty
    [[ -z "$choice" ]] && continue

    case $choice in
        1) install_cf ;;
        2) cloudflared tunnel login ;;
        3) create_tunnel ;;
        4) manage_tunnels ;;
        5) show_status ;;
        6) clean_and_restart ;;
        7) nuke_all_tunnels ;;
        0) exit 0 ;;
        *) echo -e "${RED}無效選擇${PLAIN}"; sleep 1 ;;
    esac
done
