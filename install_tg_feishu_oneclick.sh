#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/opt/tg-serverchan"
VENV_DIR="$BASE_DIR/venv"
CONFIG_FILE="$BASE_DIR/config.env"
SCRIPT_FILE="$BASE_DIR/tg_feishu.py"
SERVICE_FILE="/etc/systemd/system/tg-feishu.service"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash $0"
  exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
  echo "当前脚本仅支持 Debian/Ubuntu（需要 apt）。"
  exit 1
fi

echo "[1/8] 安装基础环境..."
apt update
apt install -y python3 python3-pip python3-venv curl

echo "[2/8] 创建目录与虚拟环境..."
mkdir -p "$BASE_DIR"
if [[ ! -d "$VENV_DIR" ]]; then
  python3 -m venv "$VENV_DIR"
fi

echo "[3/8] 安装 Python 依赖..."
"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install telethon requests

read -r -p "请输入 Telegram API_ID: " API_ID
read -r -p "请输入 Telegram API_HASH: " API_HASH
read -r -p "请输入飞书 Webhook: " FEISHU_WEBHOOK
read -r -p "飞书机器人关键词（可留空）: " FEISHU_KEYWORD

echo "[4/8] 写入配置文件..."
cat > "$CONFIG_FILE" <<EOF
API_ID=$API_ID
API_HASH=$API_HASH
FEISHU_WEBHOOK=$FEISHU_WEBHOOK
FEISHU_KEYWORD=$FEISHU_KEYWORD
EOF
chmod 600 "$CONFIG_FILE"

echo "[5/8] 写入监听脚本..."
cat > "$SCRIPT_FILE" <<'PYEOF'
import os
import time
import asyncio
import requests
from telethon import TelegramClient, events
from telethon.tl.types import User

BASE_DIR = "/opt/tg-serverchan"
CONFIG_FILE = os.path.join(BASE_DIR, "config.env")
SESSION_FILE = os.path.join(BASE_DIR, "tg_session")


def load_env(path):
    config = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            config[key.strip()] = value.strip()
    return config


config = load_env(CONFIG_FILE)
api_id = int(config["API_ID"])
api_hash = config["API_HASH"]
feishu_webhook = config["FEISHU_WEBHOOK"]
feishu_keyword = config.get("FEISHU_KEYWORD", "").strip()

KEYWORDS = []
IGNORE_OUTGOING = True
ONLY_PRIVATE_CHAT = True
MAX_TEXT_LEN = 1000
COOLDOWN_SECONDS = 5
last_push_by_chat = {}

client = TelegramClient(SESSION_FILE, api_id, api_hash)


def push_to_feishu(text):
    payload = {
        "msg_type": "text",
        "content": {
            "text": text
        }
    }
    try:
        resp = requests.post(feishu_webhook, json=payload, timeout=15)
        print("飞书返回:", resp.status_code, resp.text[:200])
    except Exception as e:
        print("飞书推送失败:", repr(e))


def match_keywords(text):
    if not KEYWORDS:
        return True
    return any(k in text for k in KEYWORDS)


@client.on(events.NewMessage(incoming=True))
async def handler(event):
    try:
        if IGNORE_OUTGOING and event.out:
            return

        msg = event.raw_text or ""
        if not msg:
            msg = "[非文本消息]"

        if not match_keywords(msg):
            return

        chat = await event.get_chat()
        if ONLY_PRIVATE_CHAT and not isinstance(chat, User):
            return

        chat_id = event.chat_id or 0
        now = time.time()
        last_time = last_push_by_chat.get(chat_id, 0)
        if now - last_time < COOLDOWN_SECONDS:
            return
        last_push_by_chat[chat_id] = now

        sender = await event.get_sender()
        first_name = getattr(sender, "first_name", "") or ""
        last_name = getattr(sender, "last_name", "") or ""
        sender_text = (first_name + " " + last_name).strip() or "未知发送者"
        msg_short = msg[:MAX_TEXT_LEN]

        text = f"{sender_text}: {msg_short}"
        if feishu_keyword:
            text = f"{feishu_keyword}\n{text}"

        print(f"收到消息: {text[:120]}")
        push_to_feishu(text)

    except Exception as e:
        print("处理消息出错:", repr(e))


async def main():
    print("Telegram -> 飞书 Webhook 监听启动中...")
    await client.start()
    me = await client.get_me()
    print(f"Telegram 登录成功: {getattr(me, 'username', None) or getattr(me, 'first_name', None)}")
    print("正在监听 Telegram 新消息...")
    await client.run_until_disconnected()


if __name__ == "__main__":
    asyncio.run(main())
PYEOF
chmod 700 "$SCRIPT_FILE"

echo "[6/8] 首次登录 Telegram（会提示输入手机号/验证码）..."
"$VENV_DIR/bin/python" - <<'PYEOF'
import os
import asyncio
from telethon import TelegramClient

BASE_DIR = "/opt/tg-serverchan"
CONFIG_FILE = os.path.join(BASE_DIR, "config.env")
SESSION_FILE = os.path.join(BASE_DIR, "tg_session")


def load_env(path):
    data = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            data[k.strip()] = v.strip()
    return data


async def main():
    cfg = load_env(CONFIG_FILE)
    client = TelegramClient(SESSION_FILE, int(cfg["API_ID"]), cfg["API_HASH"])
    await client.start()
    me = await client.get_me()
    print("登录完成:", getattr(me, "username", None) or getattr(me, "first_name", None))
    await client.disconnect()


asyncio.run(main())
PYEOF

echo "[7/8] 配置 systemd 服务..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Telegram to Feishu Webhook Notify
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$BASE_DIR
ExecStart=$VENV_DIR/bin/python $SCRIPT_FILE
Restart=always
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "[8/8] 启动并设置开机自启..."
systemctl daemon-reload
systemctl enable tg-feishu
systemctl restart tg-feishu

echo
echo "完成。可用以下命令查看状态："
echo "  systemctl status tg-feishu"
echo "  journalctl -u tg-feishu -f"
