# Telegram消息无代理接收


## 整体链路对比

| 方案 | 消息来源 | 中转服务 | 推送目标 | 是否需要 VPS |
|---|---|---|---|---|
| Telegram API + VPS | 个人 Telegram 账号收到的私聊、群消息、频道消息 | VPS 上的 Python 脚本 | 飞书 / 企业微信 / 钉钉 / Bark / ntfy / Server酱等 | 需要 |
| Telegram Bot + Cloudflare Worker | Telegram Bot 收到的消息 | Cloudflare Worker | 飞书 / 企业微信 / 钉钉 / Bark / ntfy / Discord / Slack等 | 不需要 |

本项目用于将Telegram 新消息无代理自动推送，若需要第二种方案，可见链接

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
## 一、创建飞书/企微/钉钉群机器人 Webhook

例如：下载飞书电脑端APP

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

## 二、申请 Telegram API

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
API会检测IP，请使用原生非机房IP进行申请，若需要代申请请联系 telegram@junglexin
```



## 三、运行脚本

curl -fsSL https://raw.githubusercontent.com/chengtz/tgnotice/main/install_tg_feishu_oneclick.sh -o install_tg_feishu_oneclick.sh && chmod +x install_tg_feishu_oneclick.sh && sudo bash install_tg_feishu_oneclick.sh


## 四、常用管理命令

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

