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
DEFAULT_PORT="52880"

# 確保以 Root 權限執行
[[ $EUID -ne 0 ]] && echo -e "${RED}錯誤: 必須以 root 執行！${PLAIN}" && exit 1

# 自我安裝與執行環境校正
if [[ "$0" != "/usr/local/bin/cftu" ]]; then
    echo -e "${BLUE}>>> 正在同步腳本至全域環境...${PLAIN}"
    curl -sSL "$SCRIPT_URL" -o /usr/local/bin/cftu 2>/dev/null && chmod +x /usr/local/bin/cftu
fi

# ==========================================
# 核心功能模組
# ==========================================

install_cf() {
    clear
    echo -e "${BLUE}正在安裝 Cloudflared 環境...${PLAIN}"
    mkdir -p "$CF_DIR"
    apt-get update && apt-get install -y curl wget gnupg sudo systemd mawk nano
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | sudo tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
    apt-get update && apt-get install cloudflared -y
    read -rp "安裝完成，按回車鍵返回..." dummy < /dev/tty
}

# 檢測當前 YAML 配置屬於哪種模板
detect_profile() {
    local FILE="$1"
    if grep -q "disableChunkedEncoding: true" "$FILE" 2>/dev/null; then
        echo -e "${CYAN}[🚀 代理模式]${PLAIN}"
    elif grep -q "http2Origin: true" "$FILE" 2>/dev/null; then
        echo -e "${GREEN}[🌐 網站模式]${PLAIN}"
    elif grep -q "no-multistream" "$FILE" 2>/dev/null; then
        echo -e "${YELLOW}[⚠️ 舊版配置(含失效參數)]${PLAIN}"
    else
        echo -e "${BLUE}[⚙️ 標準模式]${PLAIN}"
    fi
}

# 安全提取網域 (相容有減號或無減號的 YAML 格式)
extract_domain() {
    local FILE="$1"
    sed -n 's/.*hostname:[[:space:]]*//p' "$FILE" 2>/dev/null | head -1 | tr -d ' "\r\t'
}

# 安全提取端口
extract_port() {
    local FILE="$1"
    local P=$(grep -oE '127\.0\.0\.1:[0-9]+' "$FILE" 2>/dev/null | head -1 | cut -d: -f2)
    [[ -z "$P" || "$P" == "127" ]] && P="$DEFAULT_PORT"
    echo "$P"
}

# 根據異化類型生成最優的 YAML 配置
write_tunnel_yaml() {
    local TYPE="$1"
    local UUID="$2"
    local DOMAIN="$3"
    local PORT="$4"
    local FILE="$5"

    case $TYPE in
        1) # 🌐 網站業務專用模板 (Web / Nginx / API)
            cat > "$FILE" << EOF
tunnel: ${UUID}
credentials-file: ${CREDS_DIR}/${UUID}.json
protocol: http2
ha-connections: 8
no-prechecks: true
grace-period: 30s
loglevel: warn

originRequest:
  connectTimeout: 5s
  noHappyEyeballs: true
  keepAliveConnections: 500
  keepAliveTimeout: 90s
  http2Origin: true

ingress:
  - hostname: ${DOMAIN}
    service: http://127.0.0.1:${PORT}
  - service: http_status:404
EOF
            ;;
        2) # 🚀 代理服務專用模板 (VLESS / Xray WS)
            cat > "$FILE" << EOF
tunnel: ${UUID}
credentials-file: ${CREDS_DIR}/${UUID}.json
protocol: http2
ha-connections: 8
no-prechecks: true
grace-period: 30s
loglevel: warn

originRequest:
  connectTimeout: 5s
  noHappyEyeballs: true
  disableChunkedEncoding: true
  keepAliveConnections: 200
  keepAliveTimeout: 120s
  tcpKeepAlive: 30s

ingress:
  - hostname: ${DOMAIN}
    service: http://127.0.0.1:${PORT}
  - service: http_status:404
EOF
            ;;
        *) # ⚙️ 通用基礎模板
            cat > "$FILE" << EOF
tunnel: ${UUID}
credentials-file: ${CREDS_DIR}/${UUID}.json
protocol: http2
ha-connections: 4
no-prechecks: true
grace-period: 30s
loglevel: warn

originRequest:
  connectTimeout: 10s
  noHappyEyeballs: true

ingress:
  - hostname: ${DOMAIN}
    service: http://127.0.0.1:${PORT}
  - service: http_status:404
EOF
            ;;
    esac
}

create_tunnel() {
    mkdir -p "$CF_DIR"
    local STEP_TITLE="${BLUE}=== ➕ 創建通道 (預設 52880，支援 網站/代理 異化調優) ===${PLAIN}"
    [[ ! -f /root/.cloudflared/cert.pem ]] && echo -e "${RED}錯誤: 未檢測到登入憑證，請先執行選單 2。${PLAIN}" && sleep 2 && return
    
    # 步驟 1: 選擇業務場景
    clear
    echo -e "$STEP_TITLE"
    echo -e "請選擇當前容器運行的【業務場景】：\n"
    echo -e "  ${YELLOW}1.${PLAIN} 🌐 ${GREEN}網站業務${PLAIN} (Web/Nginx - 優化本地 HTTP/2 直通, 500 連線池)"
    echo -e "  ${YELLOW}2.${PLAIN} 🚀 ${GREEN}代理服務${PLAIN} (VLESS/WS - 停用 Chunked 防斷流, 120s 長保活)"
    echo -e "  ${YELLOW}3.${PLAIN} ⚙️  通用模式 (標準基礎設定)"
    read -rp "請選擇模式 [1-3, 預設 1]: " SCENE_TYPE < /dev/tty
    [[ -z "$SCENE_TYPE" ]] && SCENE_TYPE=1

    # 步驟 2: 通道名稱
    while true; do
        clear
        echo -e "$STEP_TITLE"
        read -rp "1. 通道名稱 (如 web 或 vless): " TUN_NAME < /dev/tty
        [[ -z "$TUN_NAME" ]] && return
        break
    done

    # 步驟 3: 綁定網域
    while true; do
        clear
        echo -e "$STEP_TITLE"
        echo -e "1. 通道名稱: ${GREEN}$TUN_NAME${PLAIN}"
        read -rp "2. 綁定網域 (如 www.yourdomain.com 或 dash.yourdomain.com): " TUN_DOMAIN < /dev/tty
        if [[ "$TUN_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,7}$ ]]; then
            break
        else
            echo -e "${RED}錯誤: [${TUN_DOMAIN}] 網域格式不正確！${PLAIN}"
            sleep 1.5
        fi
    done

    # 步驟 4: 本地端口 (預設 52880)
    clear
    echo -e "$STEP_TITLE"
    echo -e "1. 通道名稱: ${GREEN}$TUN_NAME${PLAIN}"
    echo -e "2. 綁定網域: ${GREEN}$TUN_DOMAIN${PLAIN}"
    echo -e "3. 本地服務端口 [預設: ${CYAN}${DEFAULT_PORT}${PLAIN}，直接回車即可]"
    read -rp "   自定義端口 (直接回車使用 ${DEFAULT_PORT}): " TUN_PORT < /dev/tty
    [[ -z "$TUN_PORT" ]] && TUN_PORT="$DEFAULT_PORT"
    
    TUN_TARGET="http://127.0.0.1:${TUN_PORT}"

    echo -e "\n${YELLOW}正在雲端創建通道...${PLAIN}"
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

    # 寫入異化配置
    write_tunnel_yaml "$SCENE_TYPE" "$UUID" "$TUN_DOMAIN" "$TUN_PORT" "${CF_DIR}/${TUN_NAME}.yml"

    # 註冊 systemd 服務
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
    [[ "$SCENE_TYPE" == "1" ]] && echo -e "策略調優: ${GREEN}🌐 網站業務高並發優化模板${PLAIN}"
    [[ "$SCENE_TYPE" == "2" ]] && echo -e "策略調優: ${GREEN}🚀 VLESS/WS 代理防斷流長連線模板${PLAIN}"
    echo -e "-------------------------------------------------"
    read -rp "回車返回主選單..." d < /dev/tty
}

# --- 【切換/升級通道配置 (強化防呆與精確解析)】 ---
switch_tunnel_profile() {
    while true; do
        clear
        echo -e "${BLUE}=== 🔄 切換/升級通道配置 (網站 ⇋ 代理 異化調優) ===${PLAIN}"
        TUNNELS=( $(ls -1 $CF_DIR/*.yml 2>/dev/null | xargs -n 1 basename | sed 's/\.yml//g') )
        
        if [ ${#TUNNELS[@]} -eq 0 ]; then
            echo -e "${YELLOW}暫無通道項目，請先新建通道。${PLAIN}"
            read -rp "按回車返回主選單..." d < /dev/tty
            return
        fi

        echo -e "請選擇需要切換/升級配置的通道："
        for i in "${!TUNNELS[@]}"; do
            YML_FILE="${CF_DIR}/${TUNNELS[$i]}.yml"
            PROF_TAG=$(detect_profile "$YML_FILE")
            echo -e " ${YELLOW}$((i+1)).${PLAIN} 通道: ${BLUE}${TUNNELS[$i]}${PLAIN} -> 當前狀態: $PROF_TAG"
        done
        echo -e " 0. 返回主選單\n"
        
        read -rp "請選擇通道編號 [0-${#TUNNELS[@]}]: " T_CHOICE < /dev/tty
        [[ -z "$T_CHOICE" || "$T_CHOICE" == "0" ]] && return
        
        if ! [[ "$T_CHOICE" =~ ^[0-9]+$ ]] || [ "$T_CHOICE" -gt "${#TUNNELS[@]}" ]; then
            echo -e "${RED}輸入無效！${PLAIN}"; sleep 1; continue
        fi

        TARGET="${TUNNELS[$((T_CHOICE-1))]}"
        YML_PATH="${CF_DIR}/${TARGET}.yml"

        # 精確讀取現有配置的核心資訊
        UUID_CUR=$(grep -m1 'tunnel:' "$YML_PATH" 2>/dev/null | awk '{print $2}' | tr -d ' "\r')
        DOM_CUR=$(extract_domain "$YML_PATH")
        PORT_CUR=$(extract_port "$YML_PATH")

        # 防呆修復：如果原網域名稱讀取出來是 "hostname:" 或空值，主動要求輸入正確網域名稱
        if [[ -z "$DOM_CUR" || "$DOM_CUR" == "hostname:" ]]; then
            echo -e "${YELLOW}檢測到該通道配置中的網域名稱異常，請補全正確網域：${PLAIN}"
            read -rp "請輸入該通道綁定的正確網域 (如 dash.yourdomain.com): " DOM_CUR < /dev/tty
        fi

        if [[ -z "$UUID_CUR" ]]; then
            echo -e "${RED}錯誤: 無法讀取通道 [${TARGET}] 的 Tunnel UUID，檔案可能損壞！${PLAIN}"
            read -rp "按回車鍵返回..." d < /dev/tty
            continue
        fi

        echo -e "\n當前操作通道: ${CYAN}${TARGET}${PLAIN} (網域: ${BLUE}${DOM_CUR}${PLAIN}, 端口: ${CYAN}${PORT_CUR}${PLAIN})"
        echo -e "-------------------------------------------------"
        echo -e "請選擇欲套用的新最優模板："
        echo -e "  ${YELLOW}1.${PLAIN} 🌐 ${GREEN}切換為【網站業務高並發優化模板】${PLAIN}"
        echo -e "      (配置: HTTP/2 Origin 直通, 500 並發連線池, 5s 握手逾時)"
        echo -e "  ${YELLOW}2.${PLAIN} 🚀 ${GREEN}切換為【VLESS 代理防斷流長連線模板】${PLAIN}"
        echo -e "      (配置: 停用 Chunked 編碼防斷流, 120s 長 KeepAlive, 30s TCP 保活)"
        echo -e "  ${YELLOW}3.${PLAIN} ⚙️  切換為【通用標準模板】"
        echo -e "  0. 放棄變更並返回"
        echo -e "-------------------------------------------------"
        read -rp "請選擇目標模式 [1-3]: " NEW_TYPE < /dev/tty
        [[ -z "$NEW_TYPE" || "$NEW_TYPE" == "0" ]] && continue

        if [[ "$NEW_TYPE" == "1" || "$NEW_TYPE" == "2" || "$NEW_TYPE" == "3" ]]; then
            echo -e "\n${YELLOW}正在重寫 YAML 設定檔並清除無效參數...${PLAIN}"
            write_tunnel_yaml "$NEW_TYPE" "$UUID_CUR" "$DOM_CUR" "$PORT_CUR" "$YML_PATH"
            
            echo -e "${YELLOW}正在重啟通道服務使新參數生效...${PLAIN}"
            systemctl daemon-reload
            systemctl restart ${TARGET}.service
            
            echo -e "${GREEN}✅ 通道 [${TARGET}] 已成功無縫升級並重啟生效！${PLAIN}"
            [[ "$NEW_TYPE" == "1" ]] && echo -e "當前模式已變更為: ${GREEN}🌐 網站高並發模式${PLAIN}"
            [[ "$NEW_TYPE" == "2" ]] && echo -e "當前模式已變更為: ${CYAN}🚀 VLESS 防斷流模式${PLAIN}"
            echo -e "-------------------------------------------------"
            read -rp "按回車鍵返回..." d < /dev/tty
        fi
    done
}

manage_tunnels() {
    while true; do
        clear
        echo -e "${BLUE}=== ⚙️ 管理現有通道 (常規維護) ===${PLAIN}"
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
        YML_PATH="${CF_DIR}/${TARGET}.yml"
        
        echo -e "\n當前操作通道: ${CYAN}${TARGET}${PLAIN}"
        echo -e " 1. 檢視即時日誌 (50 行)"
        echo -e " 2. 重啟此通道服務"
        echo -e " 3. 手動編輯原始設定檔 (nano)"
        echo -e " 4. ${RED}徹底刪除此通道 (包含雲端與 DNS 記錄)${PLAIN}"
        read -rp "選擇操作 [1-4]: " ACT < /dev/tty
        
        case $ACT in
            1) journalctl -u ${TARGET}.service -n 50 --no-pager; read -rp "回車返回..." d < /dev/tty ;;
            2) systemctl restart ${TARGET}.service && echo -e "${GREEN}重啟成功${PLAIN}"; sleep 1 ;;
            3) nano "$YML_PATH" < /dev/tty && systemctl restart ${TARGET}.service; echo -e "${GREEN}已重啟生效${PLAIN}"; sleep 1 ;;
            4) 
               echo -e "${RED}警告：這將同步刪除雲端隧道與 DNS 記錄！${PLAIN}"
               read -rp "確定刪除 ${TARGET} 嗎？[y/N]: " confirm < /dev/tty
               if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                   UUID_DEL=$(grep -m1 'tunnel:' "$YML_PATH" 2>/dev/null | awk '{print $2}' | tr -d ' "\r')
                   DOM_DEL=$(extract_domain "$YML_PATH")
                   
                   systemctl stop ${TARGET} 2>/dev/null
                   systemctl disable ${TARGET} 2>/dev/null
                   
                   if [[ -n "$UUID_DEL" ]]; then
                       [[ -n "$DOM_DEL" && "$DOM_DEL" != "hostname:" ]] && cloudflared tunnel route dns cleanup "$DOM_DEL" >/dev/null 2>&1
                       cloudflared tunnel delete -f "$UUID_DEL" >/dev/null 2>&1
                   fi

                   rm -f /etc/systemd/system/${TARGET}.service "$YML_PATH" ${CREDS_DIR}/${UUID_DEL}.json
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
            YML_FILE="${CF_DIR}/${t}.yml"
            STATUS=$(systemctl is-active ${t}.service 2>/dev/null)
            DOMAIN_INFO=$(extract_domain "$YML_FILE")
            PORT_INFO=$(extract_port "$YML_FILE")
            PROF_TAG=$(detect_profile "$YML_FILE")
            
            if [[ "$STATUS" == "active" ]]; then
                echo -e "通道 [${GREEN}${t}${PLAIN}] : ${GREEN}運行中${PLAIN} | 網域: ${BLUE}${DOMAIN_INFO}${PLAIN} (端口:${PORT_INFO}) | ${PROF_TAG}"
            else
                echo -e "通道 [${RED}${t}${PLAIN}] : ${RED}未運行 ($STATUS)${PLAIN} | 網域: ${BLUE}${DOMAIN_INFO}${PLAIN} (端口:${PORT_INFO})"
            fi
        done
    fi
    echo -e "-------------------------------------------------"
    read -rp "按回車鍵返回..." dummy < /dev/tty
}

clean_and_restart() {
    clear
    echo -e "${BLUE}=== 🧹 清理日誌並重啟所有服務 ===${PLAIN}"
    echo -e "${YELLOW}正在清理系統 journal 日誌空間...${PLAIN}"
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
                UUID_DEL=$(grep -m1 'tunnel:' ${CF_DIR}/${t}.yml 2>/dev/null | awk '{print $2}' | tr -d ' "\r')
                DOM_DEL=$(extract_domain "${CF_DIR}/${t}.yml")
                
                systemctl stop ${t} 2>/dev/null
                systemctl disable ${t} 2>/dev/null
                
                if [[ -n "$UUID_DEL" ]]; then
                    [[ -n "$DOM_DEL" && "$DOM_DEL" != "hostname:" ]] && cloudflared tunnel route dns cleanup "$DOM_DEL" >/dev/null 2>&1
                    cloudflared tunnel delete -f "$UUID_DEL" >/dev/null 2>&1
                fi
                
                rm -f /etc/systemd/system/${t}.service
                rm -f ${CF_DIR}/${t}.yml
                rm -f ${CREDS_DIR}/${UUID_DEL}.json
            done
            systemctl daemon-reload
            echo -e "\n${GREEN}✅ 所有通道服務已徹底清理完畢！${PLAIN}"
        fi
    else
        echo -e "\n${BLUE}已取消操作。${PLAIN}"
    fi
    read -rp "按回車鍵返回主選單..." dummy < /dev/tty
}

# ==========================================
# 主選單循環
# ==========================================
while true; do
    clear
    [[ -f /usr/bin/cloudflared ]] && ICON1="${GREEN}(已安裝)${PLAIN}" || ICON1=""
    [[ -f /root/.cloudflared/cert.pem ]] && ICON2="${GREEN}(已授權)${PLAIN}" || ICON2=""
    
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "  🚀 ${GREEN}Cloudflare Tunnel (cftu) 管理面板${PLAIN}"
    echo -e "      架構: Incus 容器獨立隧道  |  版本: 2.1.1"
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "${YELLOW} 1.${PLAIN} 初始化環境並安裝 Cloudflared $ICON1"
    echo -e "${YELLOW} 2.${PLAIN} 登入 Cloudflare 帳號 $ICON2"
    echo -e "-------------------------------------------------"
    echo -e "${YELLOW} 3.${PLAIN} ${GREEN}➕ 新建並發佈通道 (預設 52880, 支援場景異化)${PLAIN}"
    echo -e "${YELLOW} 4.${PLAIN} ${CYAN}🔄 切換/升級通道配置 (網站 ⇋ 代理)${PLAIN}"
    echo -e "${YELLOW} 5.${PLAIN} ⚙️  管理現有通道 (日誌 / 重啟 / nano編輯 / 刪除)"
    echo -e "${YELLOW} 6.${PLAIN} 📊 查看通道運行狀態與網域"
    echo -e "-------------------------------------------------"
    echo -e "${YELLOW} 7.${PLAIN} 🧹 清理日誌並重啟所有服務"
    echo -e "${RED} 8.${PLAIN} 💥 徹底清理所有服務"
    echo -e "-------------------------------------------------"
    echo -e "${YELLOW} 0.${PLAIN} 退出腳本"
    echo -e "${BLUE}=================================================${PLAIN}"
    
    read -rp "請選擇數字 [0-8]: " choice < /dev/tty
    [[ -z "$choice" ]] && continue

    case $choice in
        1) install_cf ;;
        2) cloudflared tunnel login ;;
        3) create_tunnel ;;
        4) switch_tunnel_profile ;;
        5) manage_tunnels ;;
        6) show_status ;;
        7) clean_and_restart ;;
        8) nuke_all_tunnels ;;
        0) exit 0 ;;
        *) echo -e "${RED}無效選擇${PLAIN}"; sleep 1 ;;
    esac
done
