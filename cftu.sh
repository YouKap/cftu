#!/bin/bash
# 顏色與路徑定義
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;36m'; PLAIN='\033[0m'
CF_DIR="/etc/cloudflared"; mkdir -p "$CF_DIR"

# 函數：安裝環境
install_cf() {
    clear
    echo -e "${BLUE}正在安裝 Cloudflared...${PLAIN}"
    apt-get update && apt-get install -y curl wget gnupg sudo systemd awk nano
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | sudo tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
    apt-get update && apt-get install cloudflared -y
    echo -e "${GREEN}完成。${PLAIN}"; read -p "按回車鍵返回..." dummy
}

# 函數：管理通道 (動態識別)
manage_tunnels() {
    while true; do
        clear
        echo -e "${BLUE}=== ⚙️ 管理現有通道 ===${PLAIN}"
        files=( $(ls -1 $CF_DIR/*.yml 2>/dev/null | xargs -n 1 basename | sed 's/\.yml//g') )
        if [ ${#files[@]} -eq 0 ]; then echo "暫無通道"; sleep 2; return; fi
        for i in "${!files[@]}"; do
            echo -e " ${YELLOW}$((i+1)).${PLAIN} 通道: ${files[$i]}"
        done
        echo -e " 0. 返回主選單"
        read -p "請選擇 [0-${#files[@]}]: " t_choice
        [[ -z "$t_choice" || "$t_choice" == "0" ]] && return
        target="${files[$((t_choice-1))]}"
        
        # 簡易操作
        echo -e "1.日誌 2.重啟 3.刪除"
        read -p "指令: " act
        case $act in
            1) journalctl -u ${target}.service -f ;;
            2) systemctl restart ${target}.service && echo "已重啟"; sleep 1 ;;
            3) systemctl stop ${target}.service && rm -f /etc/systemd/system/${target}.service $CF_DIR/${target}.yml && echo "已刪除"; sleep 1; return ;;
        esac
    done
}

# 主選單循環
while true; do
    clear
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "  🚀 ${GREEN}Cloudflare Tunnel (cftu) 管理面板${PLAIN}"
    echo -e "      系統時間: $(date '+%H:%M:%S')"
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e " 1. 安裝環境"
    echo -e " 2. 授權登入 (cloudflared login)"
    echo -e " 3. ➕ 新建通道 (生成配置與服務)"
    echo -e " 4. ⚙️  管理/修改/刪除 現有通道"
    echo -e " 5. 📊 運行狀態"
    echo -e " 0. 退出"
    echo -e "${BLUE}=================================================${PLAIN}"
    
    # 關鍵：使用 -n 1 限制只讀取一個字符，或者普通的 read
    # 增加 -t 參數，如果讀取不到輸入，不會立刻崩潰
    read -p "請選擇 [0-5]: " choice
    
    # 如果是空輸入，直接 continue 重新循環，不執行下方 case
    if [[ -z "$choice" ]]; then
        continue
    fi

    case $choice in
        1) install_cf ;;
        2) cloudflared tunnel login ;;
        3) 
           read -p "通道名: " n; read -p "網域: " d; read -p "目標 (例 http://127.0.0.1:80): " s
           id=$(cloudflared tunnel create $n | grep -oE "[0-9a-f-]{36}" | head -1)
           cat > $CF_DIR/$n.yml << EOL
tunnel: $id
credentials-file: /root/.cloudflared/$id.json
protocol: http2
ha-connections: 8
no-multistream: true
ingress:
  - hostname: $d
    service: $s
  - service: http_status:404
EOL
           cat > /etc/systemd/system/$n.service << EOL
[Unit]
Description=CF-$n
After=network.target
[Service]
ExecStart=/usr/bin/cloudflared tunnel --config $CF_DIR/$n.yml run
Restart=always
[Install]
WantedBy=multi-user.target
EOL
           systemctl daemon-reload && systemctl enable --now $n
           echo "創建成功"; sleep 2 ;;
        4) manage_tunnels ;;
        5) systemctl list-units "cf-*" --all; read -p "按回車返回..." dummy ;;
        0) exit 0 ;;
        *) echo "無效選擇"; sleep 1 ;;
    esac
done
