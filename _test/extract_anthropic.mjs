#!/usr/bin/env node
/**
 * 抽取 LlmEngine.parseAnthropicFrame 到 AnthropicParser.ts 供 Node 回归。
 *
 * 🔴 为什么不复用 extract.mjs
 *   extract.mjs 按 `// ───── banner` 切段再 include 白名单，
 *   而 LlmEngine.ets 全文只有一个 banner（在线JSON结构）， parseAnthropicFrame
 *   根本不在任何 banner 段里 → 抽出 0 字节直接 FATAL。
 *
 *   所以这里改用「锚点行 + 大括号配平」：定位 `parseAnthropicFrame` 的声明行，
 *   配平到函数尾，再向上吞掉紧邻 JSDoc。大括号配平复用 extract.mjs 的规则
 *   （忽略注释和字符串里的括号 —— JSDoc 里写着 `|TEXT|<正文>` 之类的示例，
 *   不忽略就会在函数体中间提前收尾，留下半个块注释，后面全被当注释）。
 *
 * 防漂移：产物必须含 |STOP| / message_stop 两个锚点，且不得残留 SDK 引用。
 *         函数一改名或一改实现，这里立刻报失败，绝不静默测旧代码。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.join(__dirname, '..');

const srcPath = path.join(projectRoot, 'entry/src/main/ets/net/LlmEngine.ets');
const outPath = path.join(__dirname, 'AnthropicParser.ts');

const src = fs.readFileSync(srcPath, 'utf8').replace(/^\uFEFF/, '');
const lines = src.split('\n');

/**
 * 🔴 不复用 extract.mjs 的 findBlockEnd。
 *
 * 那个状态机（逐字符追踪 注释/字符串/括号）在 parseAnthropicFrame 上会失准：
 * 函数体里大量模板字符串 `` `|THINK|${d.thinking}` ``，
 * `${}` 内的字符被当作普通代码，而模板字符串里夹着的引号
 * （如 `{"type":"message_stop"}` 的 JSDoc 示例）会把 inStr 状态带偏，
 * 块尾定位错乱 —— 实测把后面 emptyUsage/parseModels/probe 全抽了进来。
 *
 * 这里用更笨但更稳的办法：从声明行起，按「行内花括号净增量」累加，
 * 到净深度归零为止。parseAnthropicFrame 里没有跨行的字符串/注释，
 * 也没有行内花括号自平衡的边界情况（`as X` 不含括号），
 * 所以行级净计数足够准。
 */
function findFnEnd(declLine) {
  let depth = 0;
  for (let j = declLine; j < lines.length; j++) {
    const s = lines[j];
    for (const ch of s) {
      if (ch === '{') depth++;
      else if (ch === '}') depth--;
    }
    if (depth <= 0 && j > declLine) return j;
    if (depth === 0 && j === declLine) {
      // 声明行自己就配平了（不应该），继续往下找
    }
  }
  return lines.length - 1;
}

/** 向上吞掉紧邻的块注释/行注释 */
function absorbLeadingComments(declLine) {
  let start = declLine;
  while (start > 0) {
    const prev = lines[start - 1].trim();
    if (prev.length === 0) { start--; continue; }
    if (prev.startsWith('//')) { start--; continue; }
    if (prev.endsWith('*/') || prev.startsWith('/*') || prev.includes('/*')) {
      let k = start - 1;
      let found = -1;
      while (k >= 0) {
        const t = lines[k].trim();
        if (t.startsWith('/*')) { found = k; break; }
        if (t.length > 0 && !t.startsWith('*') && !t.startsWith('//')) break;
        k--;
      }
      if (found < 0) break;
      start = found;
      continue;
    }
    break;
  }
  return start;
}

// 锚点：parseAnthropicFrame 的声明行
const declIdx = lines.findIndex((l) => /parseAnthropicFrame\(raw: string\)/.test(l));
if (declIdx < 0) {
  console.error(`[FATAL] LlmEngine.ets 里找不到 parseAnthropicFrame 声明 —— 函数改名了？`);
  process.exit(1);
}
// 🔴 块尾必须从**声明行**起算，不能从 JSDoc 起算。
//   JSDoc 里有 `|TEXT|<正文>`、`4 [ <ns>, ]` 之类的示例文本，
//   findBlockEnd 的字符串/括号状态机会被注释里的引号和花括号带偏，
//   提前或延后收尾 —— 实测把后面 parseModels/probe 全抽了进来。
const endIdx = findFnEnd(declIdx);
const startIdx = absorbLeadingComments(declIdx);

// 取出函数体，转成可独立运行的形态：
//   - 去掉 `private static` 前缀 → export function
//   - 去掉类内缩进
let body = lines.slice(startIdx, endIdx + 1).join('\n');
body = body.replace(/private static parseAnthropicFrame/, 'export function parseAnthropicFrame');
body = body.split('\n').map((l) => {
  // 去掉类内统一缩进（首行无缩进，其余退一级）
  if (l.startsWith('  ')) return l.slice(2);
  return l;
}).join('\n');

// 依赖的 interface 也抽出来：AnthropicFrame 及其引用的 Delta/Usage/Message/ErrBody。
// 🔴 之前只抽 AnthropicFrame 一个，产物引用了未定义的 AnthropicDelta 等，
//   Node 跑到 JSON.parse(...) as AnthropicFrame 时虽不报错（TS 的 as 编译期消失），
//   但严格模式 / 类型检查会炸 —— 必须把闭包内的依赖全带上。
const ifStart = lines.findIndex((l) => /^interface AnthropicFrame \{/.test(l));
let ifBlock = '';
if (ifStart >= 0) {
  const ifEnd = findFnEnd(ifStart);
  ifBlock = lines.slice(ifStart, ifEnd + 1).join('\n') + '\n';
}
// AnthropicFrame 引用的另外三个 interface（在它之前声明）
const need = ['AnthropicDelta', 'AnthropicUsage', 'AnthropicMessage', 'AnthropicErrBody'];
for (const name of need) {
  const idx = lines.findIndex((l) => new RegExp(`^interface ${name} \\{`).test(l));
  if (idx >= 0) {
    const end = findFnEnd(idx);
    ifBlock = lines.slice(idx, end + 1).join('\n') + '\n' + ifBlock;
  }
}

const out = ifBlock + '\n' + body + '\n';

// 自检
const mustContain = ['parseAnthropicFrame', 'message_stop', '|STOP|', '|TEXT|', '|THINK|', '|ERR|'];
for (const needle of mustContain) {
  if (!out.includes(needle)) {
    console.error(`[FATAL] 抽取产物缺少关键符号: ${needle}`);
    process.exit(1);
  }
}
if (out.length < 1200) {
  console.error(`[FATAL] 抽取产物过短(${out.length})，抽取规则可能失效`);
  process.exit(1);
}
// 不得残留 SDK 引用（ArkTS 侧的 import 已在抽取时丢弃，这里再兜底）
if (/@ohos\.|@kit\./.test(out)) {
  console.error('[FATAL] 抽取产物残留 SDK 引用');
  process.exit(1);
}

fs.writeFileSync(outPath, out, 'utf8');
console.log(`OK 抽取 ${out.length} 字节 -> ${outPath}`);
