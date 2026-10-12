/**
 * 把 .ets 里的协议纯逻辑抽成 .ts 供 Node 跑回归。
 *
 * 策略（不用正则删代码块，避免误伤）：
 *   1. 去掉 import 行
 *   2. 按 include 标记白名单保留代码块，命中 skip 标记的一律丢弃
 *   3. 自检：代码行不得残留 SDK 引用；产物过短即失败
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const __projectRoot = path.join(__dirname, '..');

const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

/**
 * 🔴 路径必须能相对解析（2026-10-07 交付时发现）
 *
 * 配置里原本写死绝对路径 `<旧路径>/...`。项目复制给别人（比如 `<其他目录>`）
 * 之后，抽取器仍然从**旧目录**读源码 —— 副本里是旧代码，
 * 而你改的是新目录。测试看着通过，测的却是另一份代码。
 *
 * 这是「测试副本漂移」的另一种形态：不是手抄过期，是路径指向了别处。
 *
 * 约定：配置里的路径以 `<root>/` 开头表示相对项目根，否则按绝对路径处理。
 */
function resolvePath(p) {
  if (p.startsWith('<root>/')) {
    return path.join(__projectRoot, p.slice('<root>/'.length));
  }
  return p;
}

cfg.src = resolvePath(cfg.src);
cfg.out = resolvePath(cfg.out);

const skipPatterns = (cfg.skip ?? []).map((p) => new RegExp(p));

function shouldSkipBlock(headerLine) {
  return skipPatterns.some((re) => re.test(headerLine));
}

/**
 * 找到一个声明的收尾行号（大括号配平）。
 *
 * 🔴 必须忽略注释和字符串里的括号（2026-10-07 收尾时发现）
 *
 *   之前直接数 `{` / `}`，而函数上方的 JSDoc 里写着
 *       `4 [ <namespace>, ] [ <ackId> ] <subType> <json>`
 *   以及各种 `{xxx}` 示例 —— 这些花括号被当成了代码，
 *   导致 depth 提前归零、**函数体在中间就被截断**。
 *
 *   后果特别恶劣：产物里留下半个块注释，后面所有代码都被当成注释，
 *   测试「全绿」但实际上只测了前几个函数 —— **假通过**。
 *
 * @returns 收尾行号（含）
 */
function findBlockEnd(lines, from) {
  let depth = 0;
  let sawBrace = false;
  let inBlock = false;   // 在 /* */ 里
  let inLine = false;    // 在 // 里
  let inStr = null;      // 在 ' " ` 里

  for (let j = from; j < lines.length; j++) {
    const s = lines[j];
    for (let k = 0; k < s.length; k++) {
      const c = s[k];
      const n = k + 1 < s.length ? s[k + 1] : '';

      if (inBlock) {
        if (c === '*' && n === '/') { inBlock = false; k++; }
        continue;
      }
      if (inLine) {
        if (c === '\n') inLine = false;
        continue;
      }
      if (inStr !== null) {
        if (c === '\\') { k++; continue; }
        if (c === inStr) inStr = null;
        continue;
      }
      // 开始注释 / 字符串
      if (c === '/' && n === '*') { inBlock = true; k++; continue; }
      if (c === '/' && n === '/') { inLine = true; k++; continue; }
      if (c === '\'' || c === '"' || c === '`') { inStr = c; continue; }
      // 真正的代码括号
      if (c === '{') { depth++; sawBrace = true; }
      else if (c === '}') { depth--; }
    }
    if (sawBrace && depth <= 0) return j;
  }
  return lines.length - 1;
}

/**
 * 从声明行向上吞掉紧邻的注释，返回块的真实起点。
 *
 * 段是按 banner 切的，段首常是「上一段尾巴的注释 + 本段第一段 JSDoc」，
 * 所以要一路吞到最近的**代码行**为止。
 *
 * ⚠ 块注释必须整体吞（找到起始的 `/*`），
 *   只吞末尾几行同样会留下半个注释。
 *
 * @param lines 段内所有行
 * @param declLine 声明所在行号
 * @returns 块的起始行号
 */
function absorbLeadingComments(lines, declLine) {
  let start = declLine;
  while (start > 0) {
    const prev = lines[start - 1].trim();
    if (prev.length === 0) { start--; continue; }
    if (prev.startsWith('//')) { start--; continue; }
    // 块注释：往上找起始 /**，跨行吞完整段
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

function extractBlockRanges(src) {
  const lines = src.split('\n');
  const blocks = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();

    // 分隔注释 banner
    if (/^\/\/ ─+/.test(trimmed)) {
      let j = i + 1;
      let banner = '';
      while (j < lines.length && /^\/\/ [^\/]/.test(lines[j].trim())) {
        banner += lines[j].trim().slice(3) + ' ';
        j++;
      }
      blocks.push({ kind: 'banner', header: banner.trim(), start: i, end: j - 1 });
      i = j;
      continue;
    }

    // 导出类型/类/函数/接口/枚举 → 找到配对的收尾大括号
    if (/^(export )?(interface|class|function|enum|const|let|type) /.test(line)) {
      const j = findBlockEnd(lines, i);
      /**
       * 🔴 块起点要向上吞掉紧邻的注释（2026-10-07 收尾时发现）
       *
       * ArkTS 代码普遍在声明上方挂 JSDoc。若 start 从声明行起算，
       * 注释就留在块外 —— 后面 include/skip 一过滤，
       * 产物里就是**半个块注释**，其后的代码全被当成注释，
       * 测试「全绿」但实际只测了一小部分（这个坑真踩过：
       * 产物只有 7554 字节，修完是 12517 字节，多出 65% 的代码没在测）。
       */
      blocks.push({
        kind: 'code',
        header: trimmed,
        start: absorbLeadingComments(lines, i),
        end: j
      });
      i = j + 1;
      continue;
    }

    if (trimmed.startsWith('export function ')) {
      const j = findBlockEnd(lines, i);
      blocks.push({ kind: 'code', header: trimmed, start: absorbLeadingComments(lines, i), end: j });
      i = j + 1;
      continue;
    }

    i++;
  }
  return blocks;
}

const src = fs.readFileSync(cfg.src, 'utf8').replace(/^\uFEFF/, '');
// 预先按 banner 断点切段
const bannerRe = /^\/\/ ─{5,}\s*(.*)$/;
const lines = src.split('\n');
const segments = [];
let cur = { name: '__head__', lines: [] };
for (const line of lines) {
  const m = bannerRe.exec(line.trim());
  if (m !== null) {
    segments.push(cur);
    cur = { name: m[1].trim(), lines: [] };
    continue;
  }
  cur.lines.push(line);
}
segments.push(cur);

const include = (cfg.include ?? []).map((p) => new RegExp(p));
const out = [];
for (const seg of segments) {
  if (seg.name === '__head__') {
    // 头部：丢弃（只有 import 和文件头注释）
    continue;
  }
  const keep = include.some((re) => re.test(seg.name));
  if (!keep) {
    continue;
  }
  const body = seg.lines.join('\n');
  // 段内可能混着需跳过的成员（按类/接口头判断）
  const blocks = extractBlockRanges(body);
  const keptLines = [];
  for (const b of blocks) {
    if (b.kind === 'banner') {
      continue;
    }
    if (shouldSkipBlock(b.header)) {
      continue;
    }
    keptLines.push(...body.split('\n').slice(b.start, b.end + 1));
  }
  // 段内可能有裸函数（非 export）也被上面覆盖；没有块就整体保留
  if (keptLines.length === 0) {
    out.push(body);
  } else {
    out.push(keptLines.join('\n'));
  }
}

let result = out.join('\n\n');
// 去掉残留 import
result = result.replace(/^import[\s\S]*?from\s+'[^']+';\s*$/gm, '');
result = result.replace(/^import\s+'[^']+';\s*$/gm, '');
result = result.replace(/BusinessError/g, 'any');

const codeOnly = result
  .split('\n')
  .filter((l) => {
    const t = l.trim();
    return !t.startsWith('*') && !t.startsWith('//') && !t.startsWith('/*');
  })
  .join('\n');

const bad = codeOnly.match(/@ohos|@kit/g);
if (bad !== null) {
  console.error('[FATAL] 抽取产物仍含 SDK 引用: ' + [...new Set(bad)].join(', '));
  process.exit(1);
}
if (result.length < cfg.minLength ?? 500) {
  console.error('[FATAL] 抽取产物过短(' + result.length + ')，抽取规则可能失效');
  process.exit(1);
}
// 断言必须存在的符号，证明真的抽到了东西
for (const sym of cfg.mustContain ?? []) {
  if (!result.includes(sym)) {
    console.error(`[FATAL] 抽取产物缺少关键符号 ${sym}，测试已失效`);
    process.exit(1);
  }
}

/**
 * 🔴 遇到 stopAtBanner 就停（2026-10-07 收尾时发现）
 *
 * include 白名单是「命中就保留」，但**不会在下一个 banner 处停下**——
 * 于是「协议编解码」段之后的高层客户端代码也被带进来，
 * 而那里有依赖 @kit.* 的 class / JSDoc，抽完必然残缺
 * （表现：块注释不配平，后面代码全被当注释，测试**假通过**）。
 *
 * 明确配置分段终点，别靠猜。
 */
if (cfg.stopAtBanner) {
  const stopRe = new RegExp(cfg.stopAtBanner);
  const outLines = [];
  let stopped = false;
  for (const l of result.split('\n')) {
    if (stopRe.test(l)) {
      stopped = true;
      break;
    }
    outLines.push(l);
  }
  if (!stopped) {
    console.error(`[FATAL] 没找到 stopAtBanner（${cfg.stopAtBanner}），` +
      '\n        生产文件结构可能变了 —— 抽取结果不可信，拒绝写出。');
    process.exit(1);
  }
  result = outLines.join('\n');
}

/**
 * 🔴 块注释必须配平（2026-10-07 收尾时发现）
 *
 * 抽取器按「include 标记白名单」保留代码块。如果某个块的开头
 * 被保留、结尾落在被丢弃的块里，产物就会留下**未闭合的块注释** ——
 * 于是后面所有代码都被当成注释，测试跑不起来或悄悄少测一大片。
 *
 * 真实踩过：`SocketClient.ts` 产物在函数中间截断，
 * 报 Unterminated block comment。
 *
 * ⚠ 计数必须**跳过字符串**，因为文档里会写
 *   「路径**恒为 /socket.io/」+ 星号 + 星号结尾这种句式——
 *   那两个字符看着像注释结束，其实只是正文。
 *   直接 split 会误判。
 */
const BLOCK_OPEN = '/' + '*';
const BLOCK_CLOSE = '*' + '/';

/** 数真正的注释分隔符，字符串与转义里的不算 */
function countBlockDelims(text, wantOpen) {
  let n = 0;
  let inBlock = false;
  let inStr = null;
  for (let k = 0; k < text.length - 1; k++) {
    const c = text[k];
    const nx = text[k + 1];
    if (inStr !== null) {
      if (c === '\\') { k++; continue; }
      if (c === inStr) inStr = null;
      continue;
    }
    if (inBlock) {
      if (c === '*' && nx === '/') {
        inBlock = false;
        if (!wantOpen) n++;
        k++;
      }
      continue;
    }
    if (c === '/' && nx === '*') {
      inBlock = true;
      if (wantOpen) n++;
      k++;
      continue;
    }
    if (c === '\'' || c === '"' || c === '`') { inStr = c; continue; }
  }
  return n;
}

const blockOpen = countBlockDelims(result, true);
const blockClose = countBlockDelims(result, false);
if (blockOpen !== blockClose) {
  console.error(
    `[FATAL] 块注释不配平：产物里有 ${blockOpen} 个 /* 但只有 ${blockClose} 个 */。` +
    '\n通常�� include 白名单把注释的开头留下了、结尾丢掉了。' +
    '\n        产物会把后面的代码全当注释 —— 测试看着跑了，其实少测了一大片。');
  process.exit(1);
}

fs.writeFileSync(cfg.out, result, 'utf8');
console.log(`OK 抽取 ${result.length} 字节 -> ${cfg.out}`);