# Telegram消息无代理接收

本项目用于将Telegram 新消息无代理自动推送

```text
Telegram 收到新消息
        ↓
VPS 上 Python 脚本监听 Telegram
        ↓
飞书群机器人 Webhook 推送
        ↓
飞书群收到提醒
```

最终飞书消息格式示例：

```text
张三: 你好，在吗？
```

## 功能特点

- 支持 Telegram 私聊消息推送
- 支持飞书群机器人 Webhook 直推，不依赖 Server 酱
- 支持过滤群组/频道消息，只推送私聊
- 支持关键词过滤
- 支持防刷屏限频
- 支持 systemd 后台运行和开机自启

## 准备工作

## 一、申请 Telegram API

打开 Telegram 官方开发者页面：
```text
https://my.telegram.org/apps
```
登录你的 Telegram 账号。
创建 App 时可以参考：
```text
App title: TGNotify2026
Short name: tgnotify2026
URL: https://example.com
Platform: Desktop
Description: Telegram message notify
```
创建成功后保存：
```text
api_id
api_hash
```

注意：

```text
api_id 和 api_hash 不要公开。
api_hash 泄露后建议重新创建或更换。
```

## 二、创建飞书群机器人 Webhook

下载飞书电脑端APP

```text
群设置
→ 群机器人
→ 添加机器人
→ 自定义机器人
```

创建完成后会得到一个 Webhook，格式类似：

```text
https://open.feishu.cn/open-apis/bot/v2/hook/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```
同理，企业微信机器人及其他程序webhook可自行搜索方法。

## 三、测试飞书/企业微信/钉钉 Webhook

在 VPS 上执行：

```bash
curl -X POST "你的飞书Webhook地址" \
  -H "Content-Type: application/json" \
  -d '{
    "msg_type": "text",
    "content": {
      "text": "Telegram提醒测试：飞书Webhook直推成功"
    }
  }'
```

如果飞书群能收到，说明 Webhook 正常。

## 四、VPS 安装 Python 环境

以 Debian / Ubuntu 为例：

```bash
sudo -i
apt update
apt install -y python3 python3-pip python3-venv nano
```

创建目录：

```bash
mkdir -p /opt/tg-serverchan
cd /opt/tg-serverchan
```

创建虚拟环境：

```bash
python3 -m venv venv
```

安装依赖：

```bash
/opt/tg-serverchan/venv/bin/pip install --upgrade pip
/opt/tg-serverchan/venv/bin/pip install telethon requests
```

## 五、创建配置文件

创建配置文件：

```bash
nano /opt/tg-serverchan/config.env
```

写入：

```bash
API_ID=你的api_id
API_HASH=你的api_hash
FEISHU_WEBHOOK=你的飞书Webhook地址
```

示例，注意这只是格式，不要照抄：

```bash
API_ID=12345678
API_HASH=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
FEISHU_WEBHOOK=https://open.feishu.cn/open-apis/bot/v2/hook/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

设置权限：

```bash
chmod 600 /opt/tg-serverchan/config.env
```

## 六、创建 Python 监听脚本

创建脚本：

```bash
nano /opt/tg-serverchan/tg_feishu.py
```

写入：

```python
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

# 关键词过滤：留空表示所有消息都提醒
# 示例：KEYWORDS = ["订单", "付款", "客户", "故障"]
KEYWORDS = []

# 是否忽略自己发出的消息
IGNORE_OUTGOING = True

# 是否只推送私聊消息
# True = 群组、频道消息不推送
ONLY_PRIVATE_CHAT = True

# 单条消息最大长度
MAX_TEXT_LEN = 1000

# 同一个私聊/群组多少秒内最多推一次，防刷屏
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
        print("飞书返回：", resp.status_code, resp.text[:300])
    except Exception as e:
        print("飞书推送失败：", repr(e))


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

        # 只推送私聊消息，群组、超级群、频道不推送
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

        # 飞书显示格式：昵称:消息
        text = f"{sender_text}: {msg_short}"

        print(f"收到消息：{text[:120]}")
        push_to_feishu(text)

    except Exception as e:
        print("处理消息出错：", repr(e))


async def main():
    print("Telegram → 飞书Webhook 监听启动中...")
    await client.start()
    me = await client.get_me()
    print(f"Telegram 登录成功：{getattr(me, 'username', None) or getattr(me, 'first_name', None)}")
    print("正在监听 Telegram 新消息...")
    await client.run_until_disconnected()


if __name__ == "__main__":
    asyncio.run(main())
```

保存退出：

```text
Ctrl + O
回车
Ctrl + X
```

## 七、第一次手动运行并登录 Telegram

执行：

```bash
cd /opt/tg-serverchan
/opt/tg-serverchan/venv/bin/python /opt/tg-serverchan/tg_feishu.py
```

第一次运行会提示输入 Telegram 手机号：

```text
Please enter your phone
```

输入格式示例：

```text
+86138xxxxxxxx
```

然后 Telegram 会把验证码发到 Telegram App 里。

输入验证码后，如果账号开启了二步验证，还需要输入 Telegram 二步验证密码。

登录成功后，会生成 session 文件：

```text
/opt/tg-serverchan/tg_session.session
```

这个文件很重要，不能公开。

测试方法：

```text
让别人给你的 Telegram 发一条私聊消息，看飞书群是否收到提醒。
```

## 八、设置 systemd 后台运行

确认手动运行正常后，按：

```text
Ctrl + C
```

停止脚本。

创建 systemd 服务：

```bash
nano /etc/systemd/system/tg-feishu.service
```

写入：

```ini
[Unit]
Description=Telegram to Feishu Webhook Notify
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/tg-serverchan
ExecStart=/opt/tg-serverchan/venv/bin/python /opt/tg-serverchan/tg_feishu.py
Restart=always
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

启动并设置开机自启：

```bash
systemctl daemon-reload
systemctl enable tg-feishu
systemctl start tg-feishu
```

查看状态：

```bash
systemctl status tg-feishu
```

查看实时日志：

```bash
journalctl -u tg-feishu -f
```

## 九、常用管理命令

启动：

```bash
systemctl start tg-feishu
```

停止：

```bash
systemctl stop tg-feishu
```

重启：

```bash
systemctl restart tg-feishu
```

查看状态：

```bash
systemctl status tg-feishu
```

查看最近日志：

```bash
journalctl -u tg-feishu -n 100 --no-pager
```

## 十、可选优化

### 1. 只推送关键词消息

编辑脚本：

```bash
nano /opt/tg-serverchan/tg_feishu.py
```

找到：

```python
KEYWORDS = []
```

改成：

```python
KEYWORDS = ["订单", "付款", "客户", "充值", "故障", "售后"]
```

重启服务：

```bash
systemctl restart tg-feishu
```

### 2. 不过滤群组消息

如果想群组消息也推送，把：

```python
ONLY_PRIVATE_CHAT = True
```

改成：

```python
ONLY_PRIVATE_CHAT = False
```

重启：

```bash
systemctl restart tg-feishu
```

### 3. 调整限频

找到：

```python
COOLDOWN_SECONDS = 5
```

如果群消息多，可以改成：

```python
COOLDOWN_SECONDS = 30
```

表示同一个聊天 30 秒内最多推送一次。

### 4. 飞书开启关键词校验时

如果飞书机器人设置了关键词，例如：

```text
Telegram
```

那脚本里这一行：

```python
text = f"{sender_text}: {msg_short}"
```

需要改成：

```python
text = f"Telegram提醒\n{sender_text}: {msg_short}"
```

否则飞书机器人可能拒收。

## 十一、日志大小控制

查看日志占用：

```bash
journalctl --disk-usage
```

限制 journald 日志大小：

```bash
nano /etc/systemd/journald.conf
```

添加或修改：

```ini
SystemMaxUse=100M
SystemMaxFileSize=20M
SystemMaxFiles=5
MaxRetentionSec=7day
```

重启 journald：

```bash
systemctl restart systemd-journald
```

清理旧日志：

```bash
journalctl --vacuum-time=7d
journalctl --vacuum-size=100M
```

## 十二、安全注意事项

不要公开以下内容：

```text
1. Telegram api_id
2. Telegram api_hash
3. 飞书 Webhook
4. tg_session.session
5. Telegram 手机号和验证码
6. VPS 登录信息
```

如果这些信息已经泄露，建议：

```text
1. 重新生成飞书 Webhook
2. 重新申请或更换 Telegram API
3. 删除旧 session 文件并重新登录
```

删除 Telegram session 并重新登录：

```bash
systemctl stop tg-feishu
rm -f /opt/tg-serverchan/tg_session.session
/opt/tg-serverchan/venv/bin/python /opt/tg-serverchan/tg_feishu.py
```

## 十三、最终效果

飞书群收到的消息格式：

```text
昵称: Telegram消息内容
```

例如：

```text
张三: 你好，这个还有货吗？
```

这样就可以在不开 Telegram、不打开 VPN 的情况下，通过飞书群收到 Telegram 私聊提醒。
