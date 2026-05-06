# Telegram Bot + Cloudflare Worker 消息通知教程

本教程用于搭建一个**无 VPS** 的 Telegram 消息通知转发系统。

实现效果：

```text
Telegram Bot 收到消息
        ↓
Telegram Bot Webhook
        ↓
Cloudflare Worker
        ↓
飞书 / 企业微信 / 钉钉 / Bark / ntfy / Discord / Slack 等通知通道
```

适合场景：

- 想做一个无服务器、低成本的 Telegram Bot 消息通知系统。
- 想把 Telegram Bot 收到的消息同步到飞书、企业微信、钉钉等平台。
- 想把 Telegram 群消息、Bot 咨询消息转发到其他通知软件。
- 不想购买 VPS。

不适合场景：

- 想监听个人 Telegram 账号收到的私聊。
- 想监听别人发给你个人账号的消息。
- 想像 Telethon 一样登录个人 Telegram 账号长期监听。

如果要监听个人 Telegram 账号私聊，应使用：

```text
Telegram API + VPS + Telethon/Pyrogram
```

---

## 一、方案说明

本方案使用 Telegram Bot API 的 Webhook 模式。

Telegram Bot 收到消息后，Telegram 会主动向 Cloudflare Worker 的 HTTPS 地址发送请求。Cloudflare Worker 收到消息后，再把内容转发到你配置的通知平台。

整体链路：

```text
用户 / 群组
   ↓
Telegram Bot
   ↓ Webhook
Cloudflare Worker
   ↓
飞书 / 企业微信 / 钉钉 / Bark / ntfy / Discord / Slack
```

优点：

| 项目 | 说明 |
|---|---|
| 是否需要 VPS | 不需要 |
| 成本 | 可使用 Cloudflare Workers 免费额度 |
| 部署难度 | 较低 |
| 维护成本 | 低 |
| 适合消息来源 | Telegram Bot 私聊、群组消息、频道消息 |
| 支持多通道通知 | 支持 |

限制：

| 限制 | 说明 |
|---|---|
| 不能监听个人账号私聊 | Bot 只能接收发给 Bot 的消息 |
| 群组消息受隐私模式影响 | 需要在 BotFather 关闭 Group Privacy |
| 不能直接读取个人 Telegram 会话 | 这是 Bot API 的限制 |
| 不能像个人账号一样加入所有私聊 | 需要用户主动找 Bot 或把 Bot 拉入群 |

---

## 二、准备工作

需要准备：

```text
1. Telegram 账号
2. Telegram Bot Token
3. Cloudflare 账号
4. 一个通知平台 Webhook，例如飞书、企业微信、钉钉等
```

可选通知通道：

| 通道 | 适合场景 |
|---|---|
| 飞书 Webhook | 团队通知、群提醒 |
| 企业微信 Webhook | 微信生态提醒 |
| 钉钉 Webhook | 国内企业通知 |
| Bark | iPhone 个人推送 |
| ntfy | 跨平台推送 |
| Discord Webhook | 海外社区/团队 |
| Slack Webhook | 海外团队协作 |

---

## 三、创建 Telegram Bot

在 Telegram 中搜索：

```text
@BotFather
```

发送：

```text
/newbot
```

按照提示创建 Bot。

创建完成后，BotFather 会给你一个 Bot Token，格式类似：

```text
1234567890:AAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

注意：

```text
Bot Token 不要公开。
如果泄露，请在 BotFather 中重新生成。
```

---

## 四、创建 Cloudflare Worker

打开 Cloudflare 控制台：

```text
https://dash.cloudflare.com/
```

进入：

```text
Workers & Pages
→ Create
→ Worker
```

创建一个 Worker，例如：

```text
tg-notify-worker
```

创建后点击：

```text
Edit code
```

删除默认代码，粘贴下面的完整 Worker 代码。

---

## 五、Cloudflare Worker 完整代码

该代码支持多个通知通道，可以只配置其中一个，也可以同时配置多个。

```js
export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // 健康检查
    if (request.method === "GET") {
      return new Response("Telegram notify worker is running.");
    }

    // 只接受 POST
    if (request.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    // 路径校验，避免别人乱请求
    // Telegram webhook URL 建议设置为：
    // https://你的worker域名/telegram/你自定义的SECRET_PATH
    const expectedPath = `/telegram/${env.SECRET_PATH}`;
    if (url.pathname !== expectedPath) {
      return new Response("Forbidden", { status: 403 });
    }

    let update;
    try {
      update = await request.json();
    } catch (e) {
      return new Response("Bad Request", { status: 400 });
    }

    const msg =
      update.message ||
      update.edited_message ||
      update.channel_post ||
      update.edited_channel_post;

    if (!msg) {
      return new Response("No message");
    }

    const from = msg.from || msg.sender_chat || {};
    const chat = msg.chat || {};

    const name = [
      from.first_name || "",
      from.last_name || ""
    ].join(" ").trim()
      || from.username
      || chat.title
      || "未知用户";

    const text =
      msg.text ||
      msg.caption ||
      getNonTextMessageName(msg);

    // 如果钉钉/飞书机器人开启了关键词校验，可以改成：
    // const finalText = `Telegram提醒\n${name}: ${text}`;
    const finalText = `${name}: ${text}`;

    const tasks = [];

    if (env.FEISHU_WEBHOOK) {
      tasks.push(sendFeishu(env.FEISHU_WEBHOOK, finalText));
    }

    if (env.WECOM_WEBHOOK) {
      tasks.push(sendWeCom(env.WECOM_WEBHOOK, finalText));
    }

    if (env.DINGTALK_WEBHOOK) {
      tasks.push(sendDingTalk(env.DINGTALK_WEBHOOK, finalText));
    }

    if (env.BARK_URL) {
      tasks.push(sendBark(env.BARK_URL, "Telegram提醒", finalText));
    }

    if (env.NTFY_URL) {
      tasks.push(sendNtfy(env.NTFY_URL, finalText));
    }

    if (env.DISCORD_WEBHOOK) {
      tasks.push(sendDiscord(env.DISCORD_WEBHOOK, finalText));
    }

    if (env.SLACK_WEBHOOK) {
      tasks.push(sendSlack(env.SLACK_WEBHOOK, finalText));
    }

    if (tasks.length === 0) {
      return new Response("No notification channel configured");
    }

    const results = await Promise.allSettled(tasks);
    const failed = results.filter(r => r.status === "rejected");

    if (failed.length > 0) {
      console.log("Some pushes failed:", failed);
    }

    return new Response("OK");
  }
};

function getNonTextMessageName(msg) {
  if (msg.photo) return "[图片]";
  if (msg.video) return "[视频]";
  if (msg.voice) return "[语音]";
  if (msg.document) return "[文件]";
  if (msg.sticker) return "[贴纸]";
  if (msg.animation) return "[动图]";
  if (msg.location) return "[位置]";
  if (msg.contact) return "[联系人]";
  return "[非文本消息]";
}

async function sendFeishu(webhook, text) {
  return fetch(webhook, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      msg_type: "text",
      content: {
        text
      }
    })
  });
}

async function sendWeCom(webhook, text) {
  return fetch(webhook, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      msgtype: "text",
      text: {
        content: text
      }
    })
  });
}

async function sendDingTalk(webhook, text) {
  return fetch(webhook, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      msgtype: "text",
      text: {
        content: text
      }
    })
  });
}

async function sendBark(barkUrl, title, body) {
  // BARK_URL 示例：https://api.day.app/你的KEY
  return fetch(barkUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json; charset=utf-8"
    },
    body: JSON.stringify({
      title,
      body
    })
  });
}

async function sendNtfy(ntfyUrl, text) {
  // NTFY_URL 示例：https://ntfy.sh/your-secret-topic
  return fetch(ntfyUrl, {
    method: "POST",
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Title": "Telegram提醒"
    },
    body: text
  });
}

async function sendDiscord(webhook, text) {
  return fetch(webhook, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      content: text
    })
  });
}

async function sendSlack(webhook, text) {
  return fetch(webhook, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      text
    })
  });
}
```

保存并部署。

---

## 六、配置环境变量 / Secrets

进入 Worker：

```text
Settings
→ Variables and Secrets
→ Add
```

建议所有 Webhook、Token、Secret 都设置为 Secret。

至少添加：

```text
SECRET_PATH=自己设置一个复杂字符串
```

例如：

```text
SECRET_PATH=tg_notify_2026_x7k9p2
```

注意：

```text
SECRET_PATH 不要太简单。
不要使用 123456、test、telegram 这种容易猜到的值。
```

---

## 七、配置通知通道

下面这些通道按需配置。只要添加对应环境变量，Worker 就会自动推送到该通道。

### 1. 飞书 Webhook

变量名：

```text
FEISHU_WEBHOOK
```

值示例：

```text
https://open.feishu.cn/open-apis/bot/v2/hook/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

飞书群机器人路径：

```text
飞书群
→ 群设置
→ 群机器人
→ 添加机器人
→ 自定义机器人
→ 复制 Webhook
```

---

### 2. 企业微信 Webhook

变量名：

```text
WECOM_WEBHOOK
```

值示例：

```text
https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

企业微信群机器人路径：

```text
企业微信群
→ 群设置
→ 群机器人
→ 添加机器人
→ 复制 Webhook
```

---

### 3. 钉钉 Webhook

变量名：

```text
DINGTALK_WEBHOOK
```

值示例：

```text
https://oapi.dingtalk.com/robot/send?access_token=xxxxxxxxxxxxxxxx
```

钉钉群机器人路径：

```text
钉钉群
→ 群设置
→ 机器人
→ 添加机器人
→ 自定义机器人
→ 复制 Webhook
```

如果开启关键词校验，推送内容里必须包含对应关键词。

可以把代码中的：

```js
const finalText = `${name}: ${text}`;
```

改成：

```js
const finalText = `Telegram提醒\n${name}: ${text}`;
```

---

### 4. Bark

变量名：

```text
BARK_URL
```

值示例：

```text
https://api.day.app/你的KEY
```

适合 iPhone 个人通知。

---

### 5. ntfy

变量名：

```text
NTFY_URL
```

值示例：

```text
https://ntfy.sh/your-secret-topic
```

注意：

```text
ntfy 的 topic 要设置得足够复杂。
不要用 public、test、telegram 这种容易猜到的名字。
```

---

### 6. Discord Webhook

变量名：

```text
DISCORD_WEBHOOK
```

值示例：

```text
https://discord.com/api/webhooks/xxxx/yyyy
```

---

### 7. Slack Webhook

变量名：

```text
SLACK_WEBHOOK
```

值示例：

```text
https://hooks.slack.com/services/xxxx/yyyy/zzzz
```

---

## 八、设置 Telegram Bot Webhook

Worker 部署后，会得到一个 Worker 地址，例如：

```text
https://tg-notify-worker.example.workers.dev
```

假设你设置的：

```text
SECRET_PATH=tg_notify_2026_x7k9p2
```

那么 Telegram Webhook URL 就是：

```text
https://tg-notify-worker.example.workers.dev/telegram/tg_notify_2026_x7k9p2
```

设置 Webhook：

```bash
curl "https://api.telegram.org/bot你的BOT_TOKEN/setWebhook?url=https://tg-notify-worker.example.workers.dev/telegram/tg_notify_2026_x7k9p2"
```

查看 Webhook 状态：

```bash
curl "https://api.telegram.org/bot你的BOT_TOKEN/getWebhookInfo"
```

如果返回里看到你的 Worker 地址，说明设置成功。

删除 Webhook：

```bash
curl "https://api.telegram.org/bot你的BOT_TOKEN/deleteWebhook"
```

---

## 九、测试

给你的 Telegram Bot 发送：

```text
hello
```

你的通知通道应该收到类似：

```text
你的昵称: hello
```

如果是图片、语音、文件等非文本消息，会显示：

```text
你的昵称: [图片]
你的昵称: [语音]
你的昵称: [文件]
```

---

## 十、在 Telegram 群组中使用

如果想让 Bot 接收群消息，需要把 Bot 拉入 Telegram 群。

默认情况下，Bot 可能收不到所有普通群消息，这是因为 BotFather 的隐私模式。

关闭隐私模式：

```text
@BotFather
→ /mybots
→ 选择你的 Bot
→ Bot Settings
→ Group Privacy
→ Turn off
```

关闭后，Bot 才能收到群里更多消息。

注意：

```text
关闭隐私模式后，Bot 能接收更多群消息。
如果群消息很多，通知通道可能会被刷屏。
```

---

## 十一、安全建议

不要公开以下信息：

```text
1. Telegram Bot Token
2. Cloudflare Worker SECRET_PATH
3. 飞书 Webhook
4. 企业微信 Webhook
5. 钉钉 Webhook
6. Bark Key
7. ntfy 私密 topic
8. Discord / Slack Webhook
```

建议：

```text
1. Webhook 尽量设置为 Secret，而不是普通 Variable。
2. SECRET_PATH 设置得复杂一点。
3. 如果 Webhook 泄露，立即重置。
4. 不要把真实 Token 写进公开 GitHub 仓库。
5. 发教程或截图时，记得打码。
```

---

## 十二、常见问题

### 1. Worker 根路径可以打开，但 Telegram 消息没有转发

检查：

```text
1. setWebhook 的 URL 是否正确
2. SECRET_PATH 是否一致
3. Worker 实时日志是否收到请求
4. 通知通道 Webhook 是否正确
```

查看 Webhook：

```bash
curl "https://api.telegram.org/bot你的BOT_TOKEN/getWebhookInfo"
```

---

### 2. 飞书/钉钉收不到，但 Worker 有日志

可能原因：

```text
1. Webhook 填错
2. 群机器人被删除
3. 开启了关键词校验，但内容没有关键词
4. 通知平台限流
```

如果开启关键词校验，把代码改成：

```js
const finalText = `Telegram提醒\n${name}: ${text}`;
```

---

### 3. Telegram 群消息收不到

检查 BotFather 的 Group Privacy：

```text
@BotFather
→ /mybots
→ 选择 Bot
→ Bot Settings
→ Group Privacy
→ Turn off
```

然后把 Bot 重新拉入群，或者在群里给 Bot 管理员权限后再测试。

---

### 4. 不想推送所有消息，只想关键词推送

可以在 Worker 代码中加入关键词过滤。

例如在生成 `finalText` 后面加：

```js
const keywords = ["订单", "付款", "客户", "故障"];
if (!keywords.some(k => finalText.includes(k))) {
  return new Response("Keyword not matched");
}
```

位置示例：

```js
const finalText = `${name}: ${text}`;

const keywords = ["订单", "付款", "客户", "故障"];
if (!keywords.some(k => finalText.includes(k))) {
  return new Response("Keyword not matched");
}
```

---

### 5. 想只推送私聊，不推送群组

Telegram Bot 更新里的 `chat.type` 可以判断消息来源。

在生成 `chat` 后添加：

```js
if (chat.type !== "private") {
  return new Response("Skip non-private chat");
}
```

位置示例：

```js
const from = msg.from || msg.sender_chat || {};
const chat = msg.chat || {};

if (chat.type !== "private") {
  return new Response("Skip non-private chat");
}
```

---

## 十三、和 VPS + Telethon 方案对比

| 对比项 | Telegram Bot + Cloudflare Worker | Telegram API + VPS + Telethon |
|---|---|---|
| 是否需要 VPS | 不需要 | 需要 |
| 是否免费 | 可用免费额度 | VPS 通常需要费用 |
| 能否监听个人账号私聊 | 不能 | 可以 |
| 能否接收 Bot 私聊 | 可以 | 不适合 |
| 能否接收群消息 | 可以，需要拉 Bot 入群 | 可以，取决于账号所在群 |
| 部署难度 | 较低 | 中等 |
| 维护成本 | 低 | 中等 |
| 安全风险 | Bot Token 泄露风险 | Telegram session 泄露风险 |
| 适合场景 | Bot 咨询、群通知、无服务器通知 | 个人账号消息提醒、客户私信提醒 |

---

## 十四、最终效果

用户给 Telegram Bot 发消息：

```text
你好，还有货吗？
```

飞书/企业微信/钉钉等通知平台收到：

```text
张三: 你好，还有货吗？
```

非文本消息示例：

```text
张三: [图片]
李四: [语音]
王五: [文件]
```

---

## 十五、总结

`Telegram Bot + Cloudflare Worker` 方案适合做一个**轻量、免费、无 VPS** 的 Telegram Bot 消息通知系统。

推荐使用场景：

```text
1. Bot 客服提醒
2. Telegram 群消息同步
3. Telegram Bot 咨询转飞书/企业微信/钉钉
4. 个人轻量消息通知
5. 无服务器自动提醒系统
```

不推荐使用场景：

```text
1. 监听个人 Telegram 账号私聊
2. 监听别人直接发给你个人账号的消息
3. 需要模拟真人账号收发消息
```

如果你的需求是“别人给我的个人 Telegram 账号发私聊，也要同步到飞书”，请使用：

```text
Telegram API + VPS + Telethon
```

如果你的需求是“别人发给我的 Bot 或群里的 Bot，我要同步到飞书/企业微信/钉钉”，本教程这个方案就足够。
