/**
 * UI 组件防退化守卫。
 *
 * 背景：`AdaptiveGrid` 曾经把 ForEach 的数据源写死成 `[0..8]`（9 格），
 * 结果任何长度 >9 的列表**第 10 条起完全不渲染**，界面也没有任何提示。
 * 编译通过、运行不报错、单测全绿 —— 只有肉眼看界面才能发现。
 *
 * 这类 bug 必须有静态守卫，否则改一次退一次。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * 源码根目录，**按本文件位置解析**。
 *
 * 🔴 不能写死绝对路径（2026-10-07 交付时发现）
 *   原本是写死 '<项目根>/entry/src/main/ets'，复制项目后扫不到文件
 *   → 守卫「通过」但实际什么都没检查。绿灯是假的。
 */
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets');
const RESPONSIVE = `${SRC}/view/Responsive.ets`;
const NET = `${SRC}/net`;

let pass = 0;
const fail: string[] = [];

function ok(name: string, cond: boolean, detail: string = ''): void {
  if (cond) {
    pass++;
  } else {
    fail.push(`  ✗ ${name}${detail ? '\n      ' + detail : ''}`);
  }
}

/**
 * 提取 ForEach 的第一个实参（数据源表达式）。
 * 必须按括号深度找顶层逗号 —— 用 `[^,]+` 会在数组字面量的第一个逗号处截断，
 * 导致「硬编码数组」这条检查失效（实测：注入 [0..8] 后只报了另一条）。
 */
function forEachSource(body: string): string | null {
  const i = body.indexOf('ForEach(');
  if (i < 0) {
    return null;
  }
  const start = i + 'ForEach('.length;
  let depth = 0;
  for (let j = start; j < body.length; j++) {
    const c = body.charAt(j);
    if (c === '(' || c === '[' || c === '{') {
      depth++;
    } else if (c === ')' || c === ']' || c === '}') {
      if (depth === 0) {
        break;
      }
      depth--;
    } else if (c === ',' && depth === 0) {
      return body.slice(start, j).trim();
    }
  }
  return null;
}

const resp = fs.readFileSync(RESPONSIVE, 'utf8');

// ── 1. AdaptiveGrid 的数据源不能是硬编码字面量数组 ──
const gridBlock = resp.match(/export struct AdaptiveGrid \{[\s\S]*?\n\}/);
ok('AdaptiveGrid 组件存在', gridBlock !== null);

if (gridBlock !== null) {
  const body = gridBlock[0];

  // 必须提供 count 入参
  ok('AdaptiveGrid 暴露 count 参数（调用方才能传真实长度）',
    /@Prop\s+count:\s*number/.test(body),
    '没有 count 参数 → 无法感知列表真实长度');

  const src = forEachSource(body);
  ok('AdaptiveGrid 的 ForEach 数据源可提取', src !== null);
  if (src !== null) {
    ok('ForEach 数据源不是硬编码字面量数组',
      !/^\[[\s\d,]*\]$/.test(src),
      `实际数据源: ${src} —— 硬编码数组会让超出部分永远不渲染`);
    ok('ForEach 数据源来自动态计算（range()）',
      src.indexOf('range()') >= 0,
      `实际数据源: ${src}`);
  }

  // range() 必须用到 count 且不能封顶
  const rangeBlock = body.match(/private range\(\)[\s\S]*?\n  \}/);
  ok('range() 方法存在', rangeBlock !== null);
  if (rangeBlock !== null) {
    const rb = rangeBlock[0];
    ok('range() 读取 this.count', rb.indexOf('this.count') >= 0,
      '没用 count → 长度信息丢失');
    ok('range() 不封顶（n 由 count 决定）', rb.indexOf('this.count >') >= 0,
      '看不到 max(9, count) 的比较');
  }
}

// ── 2. 所有 AdaptiveGrid 调用点必须传 count ──
const pagesDir = `${SRC}/pages`;
let callSites = 0;
for (const f of fs.readdirSync(pagesDir)) {
  if (!f.endsWith('.ets')) {
    continue;
  }
  const text = fs.readFileSync(`${pagesDir}/${f}`, 'utf8');
  const re = /AdaptiveGrid\(\{([\s\S]*?)\}\)/g;
  let m = re.exec(text);
  while (m !== null) {
    callSites++;
    const args = m[1];
    ok(`${f} 的 AdaptiveGrid 调用传了 count`, /count:\s*this\.[A-Za-z]+\.length/.test(args),
      '漏传 count → 该页长列表第 10 条起不可见');
    m = re.exec(text);
  }
}
ok('至少存在 1 个 AdaptiveGrid 调用点', callSites > 0, `实际 ${callSites} 个`);

// ── 2.5 路由参数不能用 Record + 动态键访问 ──
//
// 实测踩过：GroupChatPage 写 `router.getParams() as Record<string,string>`
// 然后 `p?.['roomId']` —— ArkTS 禁止动态键访问（arkts-no-props-by-index），
// **编译能过但运行时取不到值**，表现是「点进去提示记录不存在」。
// 同工程里 ChatPage 用了具名 interface + 点号访问就正常。
// 这类 bug 编译器不报，只能静态扫。
const BAD_PARAM = new RegExp('getParams\\(\\)\\s*as\\s*Record[\\s\\S]{0,200}?\\?\\.\\[');
for (const f of fs.readdirSync(pagesDir).filter((x) => x.endsWith('.ets'))) {
  const t = fs.readFileSync(`${pagesDir}/${f}`, 'utf-8');
  ok(`${f} 路由参数未用动态键访问`, !BAD_PARAM.test(t),
    '发现 getParams() as Record + p?.[key]，ArkTS 下运行时取不到值');
}

// ── 3. 组件属性名不能撞 CustomComponent 内置方法 ──
// 撞了会编译失败，但列在这里便于快速定位
const RESERVED = ['size', 'width', 'height', 'padding', 'margin', 'border', 'clip', 'enabled'];
for (const f of fs.readdirSync(pagesDir)) {
  if (!f.endsWith('.ets')) {
    continue;
  }
  const text = fs.readFileSync(`${pagesDir}/${f}`, 'utf8');
  for (const r of RESERVED) {
    const re = new RegExp(`@(Prop|State|Link|StorageProp|StorageLink)\\s+${r}\\s*[:?]`);
    ok(`${f} 没有用保留名 ${r} 做状态字段`, !re.test(text));
  }
}

// ── 4. 覆盖层不能作为 Column 的直接布局子节点 ──
//
// 实测踩过（2026-10-06）：ChatPage 的 agent 选择面板写成
//   Column() { 顶栏; 列表; 输入区; this.profileOverlay() }
// 而 profileOverlay 里是 Stack{ 遮罩(height 100%); 面板 }。
// Column 的子节点**都参与布局分配**，覆盖层会把输入区顶出屏幕，
// 表现是「一打开面板整页错位」。
//
// 正确写法：build() 用 Stack 套 Column，覆盖层作为 Stack 的兄弟节点。
// 判据：build() 的根是 Stack，且覆盖层调用出现在根 Stack 的子树里。
const OVERLAY_HINT = /(overlay|panel|sheet|Sheet|drawer|modal)/;
for (const f of fs.readdirSync(pagesDir).filter((x) => x.endsWith('.ets'))) {
  const text = fs.readFileSync(`${pagesDir}/${f}`, 'utf-8');
  const m = text.match(/build\(\)\s*\{[\s\S]{0,300}?\}\s*\n\s*\.width\(/);
  if (m === null || m === null) {
    continue;
  }
  // 只在有覆盖层 Builder 的页面做检查
  if (!new RegExp(`@Builder\\s*\\n\\s*(\\w*[Oo]verlay|\\w*[Pp]anel)`).test(text)) {
    continue;
  }
  const head = m[0];
  ok(`${f} build() 根节点用 Stack（覆盖层需要脱离布局流）`,
    /Stack\s*\(\s*\{?\s*(alignContent)?/.test(head.slice(0, 120)),
    'build() 根是 Column + 覆盖层 → 打开面板会把内容顶出屏幕');
}

// ── 5. 列表容器要限高，避免内容多时撑破屏幕 ──
// agent / 成员这类列表长度不可控（PC 上可能十几个），
// 直接 ForEach 不用 Scroll + constraintSize 会顶高面板。
for (const f of ['ChatPage.ets', 'GroupChatPage.ets']) {
  const p = `${pagesDir}/${f}`;
  if (!fs.existsSync(p)) {
    continue;
  }
  const text = fs.readFileSync(p, 'utf-8');
  ok(`${f} 覆盖层面板有高度约束`,
    /constraintSize\(\{\s*maxHeight/.test(text) || /panelOverlay[\s\S]{0,600}?\.height\('\d+%'\)/.test(text),
    '面板没有高度上限 → 项数一多就撑出屏幕');
  // Scroll 与 ForEach 之间可能隔着 Builder 调用（this.xxxContent()），
  // 所以不能要求 Scroll 和 ForEach 直接相邻 —— 放宽到「同在 panelOverlay/xxxOverlay 里」。
  const overlayBlk = text.match(/@(?:Builder)?\s*[\s\S]{0,40}?(?:panelOverlay|profileOverlay)[\s\S]*?\n  \}/);
  if (overlayBlk !== null) {
    ok(`${f} 覆盖层面板内容可滚动`, /Scroll\s*\(\)/.test(overlayBlk[0]),
      '面板内容未包Scroll → 项数多时看不全');
  }
}

// ── 6. 中止链路：句柄与「句柄未到手的建连窗口」两条路都要能停（P2-SEQ11）──
//
// 实测踩过：LlmRunHandle 要等 `await requestInStream(...)` 返回才交给调用方，
//   而建连最长 connectTimeout=20s、流式期间到流结束都还没 resolve。
//   这段窗口里 AgentOrchestrator.running 是空的 → abort() 查不到句柄 →
//   用户点「停止」被**静默丢弃**，请求继续跑、token 继续烧。
//   编译不报、跑起来也没异常，只有真在那个窗口点停止才会发现。
//   守卫点：① 运行中 runId 必须在 await run **之前** 登记；
//         ② LlmEngine 必须有按 runId 的中止入口，并在请求发起前登记；
//         ③ 两张表必须同点释放（否则 static Map 只进不出 → 内存泄漏）。
{
  const orch = fs.readFileSync(`${NET}/Orchestrator.ets`, 'utf-8');
  const llm = fs.readFileSync(`${NET}/LlmEngine.ets`, 'utf-8');

  ok('Orchestrator 有 runId 运行表（句柄未到手时也能按 runId 停）',
    /private static activeRunIds = new Map<string, string>\(\)/.test(orch),
    '没有按 runId 的运行表 → 建连窗口点「停止」会被丢弃');

  ok('runId 在 await LlmEngine.run 之前登记',
    /activeRunIds\.set\(ctxKey, msgId\);[\s\S]{0,200}?await LlmEngine\.run\(/.test(orch),
    '先 await run 再登记 → 建连窗口仍然是空的');

  ok('runId 登记在 finally 里清理',
    /finally\s*\{[\s\S]{0,300}?activeRunIds\.delete\(ctxKey\)/.test(orch),
    '异常路径不清理 → runId 表只进不出');

  ok('abort 在拿不到句柄时回落到 abortRun',
    /handle !== undefined[\s\S]{0,200}?return;[\s\S]{0,400}?LlmEngine\.abortRun\(liveRunId\)/.test(orch),
    '拿不到句柄就直接返回 → 建连窗口的 abort 被吞掉');

  ok('LlmEngine 提供按 runId 的中止入口', /static abortRun\(runId: string\): void/.test(llm),
    '缺 abortRun → 只能在拿到句柄之后中止');

  ok('中止回调在请求发起前登记（建连窗口才能命中）',
    (llm.match(/aborts\.set\(runId, abortFn\)/g) ?? []).length >= 2
    && /inflight\.set\(runId, client\);[\s\S]{0,200}?aborts\.set\(runId, abortFn\);[\s\S]{0,400}?await client\.requestInStream\(/.test(llm),
    'abort 登记晚于 requestInStream → 还是只能在流结束后才停');

  ok('OpenAI 与 Anthropic 两条路径共用同一 abortFn（事件语义一致）',
    (llm.match(/return newHandle\(abortFn\)/g) ?? []).length >= 2,
    '两条路径事件不一致 → 队列项可能落 failed 而不是 cancelled');

  ok('所有终态走 releaseSlot（两张表成对释放）',
    !/inflight\.delete\(runId\)/.test(llm.replace(/private static releaseSlot[\s\S]*?\n  \}/, '')),
    '存在裸 inflight.delete → aborts 表泄漏');

  // ── 7. 「停止」按钮要幂等（P2-SEQ11）──
  //
  // 连点 5 次会发起 5 次 abortRoom 并弹 5 次 toast。
  // abort 本身幂等（finished 守卫）所以无副作用，但重复提示是用户可见的缺陷。
  const gc = fs.readFileSync(`${pagesDir}/GroupChatPage.ets`, 'utf-8');
  ok('GroupChatPage 有停止幂等位',
    /@State stopping: boolean = false;/.test(gc),
    '没有幂等位 → 连点会重复触发停止');
  ok('stopAll 入口挡重复点击',
    /private async stopAll\(\)[\s\S]{0,200}?if \(this\.stopping\)[\s\S]{0,80}?return;/.test(gc),
    'stopAll 没有重入门 → 连点多次重复弹 toast');
  ok('stopping 在 finally 复位（异常后不会永久卡住按钮）',
    /private async stopAll\(\)[\s\S]{0,900}?finally\s*\{[\s\S]{0,120}?this\.stopping = false;/.test(gc),
    'stopping 不复位 → 一次异常后停止按钮永远禁用');
}

// ── 8. 单聊「停止」也要覆盖建连窗口（P1-SEQ12）──
//
// 与第 6 节群聊同源：ChatPage 的 this.handle 同样要等 `await LlmEngine.run`
// 返回（建连最长 20s / 流式最长 300s）。窗口内 handle 恒为 null，只判句柄会把
// 用户点的「停止」静默丢弃 —— UI 假装已停止、token 继续烧、退出页面也拦不住。
// Pi SEQ12 审核发现：上轮 P2-1 只修了群聊 Orchestrator 一条路径，漏了单聊。
{
  const chat = fs.readFileSync(`${pagesDir}/ChatPage.ets`, 'utf-8');
  const sendBlock = chat.match(/private async send\(\): Promise<void> \{[\s\S]*?\n  \}/);

  ok('ChatPage 有本地 runId 登记位（句柄未到手时按 runId 停）',
    /private liveLocalRunId: string = '';/.test(chat),
    '没有 runId 登记位 → 单聊建连窗口点「停止」仍被丢弃');

  ok('ChatPage 在 await LlmEngine.run 之前登记 runId',
    sendBlock !== null
    && /liveLocalRunId = localRunId;[\s\S]*?await LlmEngine\.run\(req, localRunId, sink\)/.test(sendBlock[0]),
    'runId 晚于 await run 登记 → 建连窗口仍是空的');

  ok('ChatPage stopIfRunning 回落到 LlmEngine.abortRun',
    /private stopIfRunning\(\)[\s\S]{0,700}?LlmEngine\.abortRun\(this\.liveLocalRunId\)/.test(chat),
    'stopIfRunning 只看 this.handle → 建连窗口的 abort 被吞掉');

  ok('ChatPage 停止后不再补发起请求（runId 归属校验）',
    /if \(this\.liveLocalRunId !== localRunId\)\s*\{[\s\S]{0,80}?return;/.test(chat),
    'buildContext 等 await 期间点停止后仍会发起请求 → 白烧一次 token');

  ok('ChatPage 只给「当前这一轮」挂句柄',
    /if \(this\.liveLocalRunId === localRunId\)\s*\{[\s\S]{0,80}?this\.handle = h;/.test(chat),
    '不校验归属 → 会把已结束的陈旧句柄挂到 this.handle，下一轮停止走错分支');

  ok('ChatPage 收尾 / 停止都摘掉 runId 登记',
    (chat.match(/this\.liveLocalRunId = '';/g) ?? []).length >= 2,
    'runId 只设不清 → 重复 abort 或停止后仍然「算在跑」');
}

// ── 9. 群聊「发送」也要幂等（P2-SEQ12）──
//
// send() 里有多处 await；连点两次会在两次 await 之间并行跑第二遍
// → 队列 2 条重复任务、agent 对同一条消息回两遍。
// ChatPage 侧靠 streaming 守住，群聊侧原先没有对称保护。
{
  const gcSend = fs.readFileSync(`${pagesDir}/GroupChatPage.ets`, 'utf-8');
  ok('GroupChatPage 有发送幂等位',
    /@State sending: boolean = false;/.test(gcSend),
    '没有 sending 位 → 连点两次会重复入队，agent 回两遍');
  ok('send 入口挡重复点击',
    /private async send\(\)[\s\S]{0,300}?if \(this\.sending\)[\s\S]{0,100}?return;/.test(gcSend),
    'send 没有重入门 → 两次 await 之间可并行进入');
  ok('sending 在 finally 复位（异常后不会永久禁用发送）',
    /private async send\(\)[\s\S]{0,500}?finally\s*\{[\s\S]{0,120}?this\.sending = false;/.test(gcSend),
    'sending 不复位 → 一次异常后发送按钮永远禁用');
  ok('发送按钮在发送中禁用',
    /\.enabled\(this\.draft\.trim\(\)\.length > 0 && !this\.sending\)/.test(gcSend),
    '按钮不看 sending → 连点仍可触发');
}

// ── 10. API Key 加密链路防退化守卫（③ API Key 脱敏 + P1-NEW-2 / P1-NEW-3 / seq22-R2）──
//
// 背景：asset.query 无匹配资产时抛 24000002（NOT_FOUND）而非返回空数组，首装主密钥
// 创建分支曾被外层 catch 吞掉 → API Key 静默降级明文落库（P1-NEW-2）。asset.add
// 不接受 query 专用 tag RETURN_TYPE，真机报 Unsupported tag（P1-NEW-3）。
// 错误码判别必须用 SDK 导出的 asset.ErrorCode 枚举名（DSH：裸字面量和正则都不需要）。
// seq22-R2：asset.query 不带 RETURN_TYPE=ReturnType.ALL 时服务端主动剥掉 SECRET
// （有行无密文）→ 密钥/令牌永远读不回。所有读 SECRET 的 query 必须带该 tag；
// asset.remove 不接受该 tag，clearToken 必须保持裸 tokenQuery。
{
  const apiCrypto = fs.readFileSync(`${SRC}/data/ApiKeyCrypto.ets`, 'utf8');
  const appStore = fs.readFileSync(`${SRC}/viewmodel/AppStore.ets`, 'utf8');
  const repos = fs.readFileSync(`${SRC}/data/Repos.ets`, 'utf8');

  ok('ApiKeyCrypto 用 asset.ErrorCode.DUPLICATED 判别 add 冲突',
    apiCrypto.indexOf('asset.ErrorCode.DUPLICATED') >= 0,
    '错误码判别退化为裸字面量/正则 → 静态守卫无法覆盖');

  ok('ApiKeyCrypto 用 asset.ErrorCode.NOT_FOUND 判别 query 未命中',
    apiCrypto.indexOf('asset.ErrorCode.NOT_FOUND') >= 0,
    '首装 query 未命中判别退化 → 创建分支可能再次不可达，API Key 静默明文落库');

  ok('ApiKeyCrypto add 撞 DUPLICATED 后重查取既有 key（内层 catch）',
    /asset\.ErrorCode\.DUPLICATED[\s\S]{0,800}?asset\.query\(masterKeyQuery\(\)\)/.test(apiCrypto),
    '撞 DUPLICATED 后不重查 → 并发/重复创建时主密钥丢失，已存密文永久解不开');

  ok('ApiKeyCrypto masterKeyQuery 带 RETURN_TYPE=ReturnType.ALL（读 SECRET）',
    /asset\.Tag\.RETURN_TYPE,\s*asset\.ReturnType\.ALL/.test(apiCrypto),
    'masterKeyQuery 不带 RETURN_TYPE.ALL → 服务端剥掉 SECRET，主密钥永远读不回（seq22-R2 根因）');

  ok('AppStore.restoreToken 包内层 catch（首装 NOT_FOUND 静默）',
    /static async restoreToken\(\): Promise<void> \{[\s\S]{0,400}?asset\.query\(AppStore\.tokenSecretQuery\(\)\)[\s\S]{0,300}?catch \(e\)/.test(appStore)
    && appStore.indexOf('asset.ErrorCode.NOT_FOUND') >= 0,
    'restoreToken 无内层 catch → 冷启动无令牌落假告警');

  ok('AppStore 读令牌用 tokenSecretQuery（带 RETURN_TYPE=ReturnType.ALL）',
    /asset\.Tag\.RETURN_TYPE,\s*asset\.ReturnType\.ALL/.test(appStore),
    'tokenSecretQuery 不带 RETURN_TYPE.ALL → 令牌 SECRET 被剥，杀进程重启后掉登录（seq22-R2 根因）');

  ok('AppStore clearToken 的 remove 继续用裸 tokenQuery（remove 拒 RETURN_TYPE）',
    /asset\.remove\(AppStore\.tokenQuery\(\)\)/.test(appStore),
    'remove 误带 RETURN_TYPE → 真机报 Unsupported tag，退出登录清不掉令牌（P1-NEW-3 同类）');

  ok('ProviderRepo.list() 引用 migrateLegacyKey（列表路径惰性迁移）',
    /static async list\([\s\S]{0,600}?migrateLegacyKey/.test(repos),
    'list() 不迁移 → 升级后只走列表路径的存量明文继续躺库');
}

console.log('─'.repeat(56));
console.log(`UI 防退化守卫：  通过 ${pass} · 失败 ${fail.length}`);
console.log('─'.repeat(56));
if (fail.length > 0) {
  console.log('\n发现问题：');
  fail.forEach((x) => console.log(x));
  process.exit(1);
}
console.log(`\n>>> 全部通过（覆盖 ${callSites} 个 AdaptiveGrid 调用点）`);
