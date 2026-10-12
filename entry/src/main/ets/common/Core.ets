/**
 * 纯逻辑层：格式化、@ 提及解析、流式事件归约、SSE 解析、JWT、Markdown 分段。
 *
 * 本文件不 import 任何 @kit.*，因此可以直接被 Node 以
 * --experimental-transform-types 复刻运行做回归测试（见 _test/run.ts）。
 *
 * ArkTS 约束（改本文件前必读，都是编译器实测报错，不是"建议"）：
 *  -禁止 any / unknown：JSON 反序列化必须 `as` 成显式 interface。
 *  - 禁止对象字面量当类型：必须先声明具名 interface。
 *  - 禁止对象展开 {...x}：要显式逐字段赋值。
 *  - 禁止对字符串用 [] 下标取字符：用 charAt()。
 *  - 禁止 obj['k'] 这种动态键访问：改成具名 interface 的具名字段。
 */

// ───────────────────────── 基础类型 ─────────────────────────

/** 键值对（替代 Record<string, unknown>） */
export interface KeyValue {
  key: string;
  value: string;
}

/** 显示宽度：CJK 与 emoji 按 2 列计（padEnd 按码点算，表格会错位）。 */
export function displayWidth(s: string): number {
  let w = 0;
  for (const ch of s) {
    const cp = ch.codePointAt(0) ?? 0;
    if ((cp >= 0x1100 && cp <= 0x115f) ||
      (cp >= 0x2e80 && cp <= 0xa4cf) ||
      (cp >= 0xac00 && cp <= 0xd7a3) ||
      (cp >= 0xf900 && cp <= 0xfaff) ||
      (cp >= 0xfe30 && cp <= 0xfe6f) ||
      (cp >= 0xff00 && cp <= 0xff60) ||
      (cp >= 0xffe0 && cp <= 0xffe6)) {
      w += 2;
    } else if (cp >= 0x1f300 && cp <= 0x1faff) {
      w += 2; // emoji
    } else if (cp >= 0x200b && cp <= 0x200f) {
      w += 0; // 零宽字符
    } else {
      w += 1;
    }
  }
  return w;
}

export function padDisplay(s: string, width: number, alignLeft: boolean = true): string {
  const gap = Math.max(0, width - displayWidth(s));
  if (!alignLeft) {
    return repeatSpace(gap) + s;
  }
  return s + repeatSpace(gap);
}

function repeatSpace(n: number): string {
  let s = '';
  for (let i = 0; i < n; i++) {
    s += ' ';
  }
  return s;
}

export function formatNumber(n: number, digits: number = 2): string {
  if (!isFinite(n)) {
    return '0';
  }
  const neg = n < 0;
  const abs = Math.abs(n);
  const fixed = abs.toFixed(digits);
  const parts = fixed.split('.');
  const intPart = groupThousands(parts[0]);
  const out = parts.length > 1 ? `${intPart}.${parts[1]}` : intPart;
  return neg ? `-${out}` : out;
}

function groupThousands(digits: string): string {
  let out = '';
  let count = 0;
  for (let i = digits.length - 1; i >= 0; i--) {
    const c = digits.charAt(i);
    if (c === '-') {
      out = `${c}${out}`;
      continue;
    }
    count++;
    out = c + out;
    if (count % 3 === 0 && i > 0) {
      out = `,${out}`;
    }
  }
  return out;
}

export function compactNumber(n: number): string {
  const abs = Math.abs(n);
  if (abs < 1000) {
    return String(Math.round(n));
  }
  if (abs < 1000000) {
    return `${trimZero(n / 1000)}K`;
  }
  if (abs < 1000000000) {
    return `${trimZero(n / 1000000)}M`;
  }
  return `${trimZero(n / 1000000000)}B`;
}

function trimZero(n: number): string {
  const s = n.toFixed(1);
  return s.endsWith('.0') ? s.slice(0, -2) : s;
}

export function relativeTime(ts: number, now: number): string {
  const diff = Math.max(0, now - ts);
  const min = Math.floor(diff / 60000);
  if (min < 1) {
    return '刚刚';
  }
  if (min < 60) {
    return `${min}分钟前`;
  }
  const hour = Math.floor(min / 60);
  if (hour < 24) {
    return `${hour}小时前`;
  }
  const day = Math.floor(hour / 24);
  if (day === 1) {
    return '昨天';
  }
  if (day < 7) {
    return `${day}天前`;
  }
  const d = new Date(ts);
  const mm = `${d.getMonth() + 1}`.padStart(2, '0');
  const dd = `${d.getDate()}`.padStart(2, '0');
  if (d.getFullYear() === new Date(now).getFullYear()) {
    return `${mm}-${dd}`;
  }
  return `${d.getFullYear()}-${mm}-${dd}`;
}

export function timeSeparator(ts: number, now: number): string {
  const a = new Date(ts);
  const b = new Date(now);
  const sameDay = a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  const hh = `${a.getHours()}`.padStart(2, '0');
  const mi = `${a.getMinutes()}`.padStart(2, '0');
  if (sameDay) {
    return `今天 ${hh}:${mi}`;
  }
  const y = new Date(now - 86400000);
  const isYesterday = a.getFullYear() === y.getFullYear() &&
    a.getMonth() === y.getMonth() && a.getDate() === y.getDate();
  if (isYesterday) {
    return `昨天 ${hh}:${mi}`;
  }
  return relativeTime(ts, now);
}

// ───────────────────────── @ 提及 ─────────────────────────

export interface MentionCandidate {
  agentId: string;
  /** 房间内记录 id，仅用于排查 */
  recordId: string;
  name: string;
  removedAt: number;
  canMentionAll: boolean;
}

export interface MentionRef {
  type: string;      // 'agent' | 'all'
  participantId: string;
  displayName: string;
}

export function extractMentionNames(text: string): string[] {
  const out: string[] = [];
  const re = /@([^\s@，。！？；：、,.!?;:)\]}]+)/g;
  let m = re.exec(text);
  while (m !== null) {
    const name = m[1];
    if (name.length > 0 && out.indexOf(name) === -1) {
      out.push(name);
    }
    m = re.exec(text);
  }
  return out;
}

export function resolveMentions(text: string, agents: MentionCandidate[]): MentionRef[] {
  const mentioned = extractMentionNames(text);
  const refs: MentionRef[] = [];
  if (mentioned.length === 0) {
    return refs;
  }
  for (const raw of mentioned) {
    const idx = matchAgentIndex(raw, agents);
    if (idx >= 0) {
      const hit = agents[idx];
      let exists = false;
      for (const r of refs) {
        if (r.participantId === hit.agentId) {
          exists = true;
        }
      }
      if (!exists) {
        refs.push({ type: 'agent', participantId: hit.agentId, displayName: hit.name });
      }
      continue;
    }
    if (raw === 'all') {
      for (const a of agents) {
        if (a.canMentionAll) {
          refs.push({ type: 'all', participantId: 'all', displayName: '全体' });
          break;
        }
      }
    }
  }
  return refs;
}

/** 返回下标而非对象，便于 ArkTS 里在循环里复用 */
export function matchAgentIndex(raw: string, agents: MentionCandidate[]): number {
  const target = normName(raw);
  // 1. 精确
  for (let i = 0; i < agents.length; i++) {
    const a = agents[i];
    if (a.removedAt === 0 && a.name === raw) {
      return i;
    }
  }
  // 2. 忽略大小写 + 去空格
  for (let i = 0; i < agents.length; i++) {
    const a = agents[i];
    if (a.removedAt === 0 && normName(a.name) === target) {
      return i;
    }
  }
  // 3. 前缀/后缀包含（取最具体：优先从原名开头匹配）
  for (let i = 0; i < agents.length; i++) {
    const a = agents[i];
    if (a.removedAt !== 0) {
      continue;
    }
    const n = normName(a.name);
    if (n.length > 0 && target.length > 0 &&
      (n.indexOf(target) === 0 || target.indexOf(n) === 0)) {
      return i;
    }
  }
  return -1;
}

function normName(s: string): string {
  return s.toLowerCase().replace(/\s+/g, '');
}

export function validateGroupMessage(text: string, refs: MentionRef[]): string {
  if (text.trim().length === 0) {
    return '消息不能为空';
  }
  if (refs.length === 0) {
    return '需要 @ 至少一个 Agent 才会开始执行';
  }
  return '';
}

// ───────────────────────── 流式事件归约 ─────────────────────────

export interface TraceLite {
  name: string;
  status: string;    // 'running' | 'ok' | 'failed'
  args: string;
  result: string;
}

export interface UsageLite {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  contextTokens: number;
  costUsd: number;
}

export interface StreamState {
  text: string;
  reasoning: string;
  tools: TraceLite[];
  status: string;    // 'idle' | 'streaming' | 'done' | 'failed' | 'aborted'
  error: string;
  usage: UsageLite;
  title: string;
}

/** 与服务端 run 事件对齐的载荷（字段名保持原版 snake_case） */
export interface UsagePayload {
  input_tokens: number;
  output_tokens: number;
  total_tokens: number;
  cache_read_tokens: number;
  cost_usd: number;
}

export interface RunEventLite {
  event: string;
  run_id: string;
  session_id: string;
  delta: string;
  text: string;
  tool: string;
  name: string;
  /** 工具参数/结果：已在入口处 JSON 字符串化，避免 any */
  argsJson: string;
  error: string;
  status: string;
  output: string;
  usage: UsagePayload;
  title: string;
}

export function emptyStream(): StreamState {
  return {
    text: '',
    reasoning: '',
    tools: [],
    status: 'idle',
    error: '',
    usage: {
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      contextTokens: 0,
      costUsd: 0
    },
    title: ''
  };
}

export function emptyRunEvent(event: string): RunEventLite {
  return {
    event: event,
    run_id: '',
    session_id: '',
    delta: '',
    text: '',
    tool: '',
    name: '',
    argsJson: '',
    error: '',
    status: '',
    output: '',
    usage: {
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      cache_read_tokens: 0,
      cost_usd: 0
    },
    title: ''
  };
}

/**
 * 把一条 run 事件归约进当前状态（不可变更新）。
 *
 * 事件语义严格对齐原版：
 * - message.delta / message.interim  追加正文
 * - reasoning.delta / thinking.delta  追加思考
 * - reasoning.available               整体替换思考
 * - tool.started/completed/failed     工具轨迹
 * - run.usage.updated                 合并 usage
 * - session.title.updated             设置标题
 * - run.completed                     收尾，output 非空则作为最终正文
 */
export function reduceRunEvent(prev: StreamState, ev: RunEventLite): StreamState {
  const next: StreamState = {
    text: prev.text,
    reasoning: prev.reasoning,
    tools: [],
    status: prev.status,
    error: prev.error,
    usage: {
      inputTokens: prev.usage.inputTokens,
      outputTokens: prev.usage.outputTokens,
      cacheReadTokens: prev.usage.cacheReadTokens,
      contextTokens: prev.usage.contextTokens,
      costUsd: prev.usage.costUsd
    },
    title: prev.title
  };
  for (const t of prev.tools) {
    next.tools.push({ name: t.name, status: t.status, args: t.args, result: t.result });
  }

  switch (ev.event) {
    case 'run.started':
      next.status = 'streaming';
      break;

    case 'message.delta':
    case 'message.interim':
      if (ev.delta.length > 0) {
        next.text += ev.delta;
      }
      next.status = 'streaming';
      break;

    case 'reasoning.delta':
    case 'thinking.delta':
      if (ev.text.length > 0) {
        next.reasoning += ev.text;
      }
      break;

    case 'reasoning.available':
      next.reasoning = ev.text;
      break;

    case 'tool.started': {
      const name = ev.name.length > 0 ? ev.name : (ev.tool.length > 0 ? ev.tool : 'tool');
      next.tools.push({ name: name, status: 'running', args: ev.argsJson, result: '' });
      break;
    }

    case 'tool.completed': {
      const name = ev.name.length > 0 ? ev.name : (ev.tool.length > 0 ? ev.tool : 'tool');
      const idx = findToolIndex(next.tools, name);
      if (idx >= 0) {
        next.tools[idx].status = 'ok';
        next.tools[idx].result = ev.argsJson;
      } else {
        next.tools.push({ name: name, status: 'ok', args: '', result: ev.argsJson });
      }
      break;
    }

    case 'tool.failed': {
      const name = ev.name.length > 0 ? ev.name : (ev.tool.length > 0 ? ev.tool : 'tool');
      const idx = findToolIndex(next.tools, name);
      const detail = ev.argsJson.length > 0 ? ev.argsJson : ev.error;
      if (idx >= 0) {
        next.tools[idx].status = 'failed';
        next.tools[idx].result = detail;
      } else {
        next.tools.push({ name: name, status: 'failed', args: '', result: detail });
      }
      break;
    }

    case 'run.usage.updated':
    case 'usage.updated':
      if (ev.usage.input_tokens > 0) {
        next.usage.inputTokens = ev.usage.input_tokens;
      }
      if (ev.usage.output_tokens > 0) {
        next.usage.outputTokens = ev.usage.output_tokens;
      }
      if (ev.usage.cache_read_tokens > 0) {
        next.usage.cacheReadTokens = ev.usage.cache_read_tokens;
      }
      if (ev.usage.cost_usd > 0) {
        next.usage.costUsd = ev.usage.cost_usd;
      }
      break;

    case 'session.title.updated':
      if (ev.title.length > 0) {
        next.title = ev.title;
      }
      break;

    case 'run.completed':
      // output 优先：中途流式丢失时用它兜底
      if (ev.output.length > 0) {
        next.text = ev.output;
      }
      next.status = 'done';
      break;

    case 'run.failed':
      next.status = 'failed';
      next.error = ev.error.length > 0 ? ev.error : '运行失败';
      break;

    case 'abort.completed':
      next.status = 'aborted';
      break;

    default:
      break;
  }
  return next;
}

/** 从后往前找同名工具：同名多次调用时改的是最近一次 */
function findToolIndex(tools: TraceLite[], name: string): number {
  for (let i = tools.length - 1; i >= 0; i--) {
    if (tools[i].name === name) {
      return i;
    }
  }
  return -1;
}

export function previewOf(text: string, maxLen: number = 60): string {
  const flat = text.replace(/\s+/g, ' ').trim();
  if (flat.length <= maxLen) {
    return flat;
  }
  return `${flat.slice(0, maxLen)}…`;
}

// ───────────────────────── Markdown 轻量渲染 ─────────────────────────

export interface Segment {
  kind: string;      // 'text' | 'code' | 'bold' | 'codeblock'
  value: string;
  lang: string;
}

export function parseInlineMd(src: string): Segment[] {
  const out: Segment[] = [];
  let i = 0;
  const n = src.length;
  let buf = '';

  const flush = (): void => {
    if (buf.length > 0) {
      out.push({ kind: 'text', value: buf, lang: '' });
      buf = '';
    }
  };

  while (i < n) {
    if (src.startsWith('```', i)) {
      flush();
      const eol = src.indexOf('\n', i);
      if (eol < 0) {
        break;
      }
      const lang = src.slice(i + 3, eol).trim();
      const close = src.indexOf('```', eol + 1);
      const end = close < 0 ? n : close;
      let body = src.slice(eol + 1, end);
      if (body.endsWith('\n')) {
        body = body.slice(0, -1);
      }
      out.push({ kind: 'codeblock', value: body, lang: lang });
      i = close < 0 ? n : close + 3;
      continue;
    }
    if (src.charAt(i) === '`' && src.charAt(i + 1) !== '`') {
      const close = src.indexOf('`', i + 1);
      if (close > i + 1) {
        flush();
        out.push({ kind: 'code', value: src.slice(i + 1, close), lang: '' });
        i = close + 1;
        continue;
      }
    }
    if (src.startsWith('**', i)) {
      const close = src.indexOf('**', i + 2);
      if (close > i + 2) {
        flush();
        out.push({ kind: 'bold', value: src.slice(i + 2, close), lang: '' });
        i = close + 2;
        continue;
      }
    }
    buf += src.charAt(i);
    i++;
  }
  flush();
  return out;
}

export function detectLang(block: string): string {
  const first = (block.trim().split('\n')[0] ?? '');
  if (/^(typescript|ts|javascript|js|tsx|jsx|arkts|ets)$/.test(first)) {
    return 'typescript';
  }
  if (/^(json|jsonc)$/.test(first)) {
    return 'json';
  }
  if (/^(python|py)$/.test(first)) {
    return 'python';
  }
  if (/^(bash|sh|shell|zsh)$/.test(first)) {
    return 'bash';
  }
  return 'text';
}

// ───────────────────────── SQL 构造 ─────────────────────────

export interface WhereClause {
  clause: string;
  args: string[];
}

export interface SqlStatement {
  sql: string;
  args: string[];
}

export function sqlEscape(v: string): string {
  return v.replace(/'/g, "''");
}

export function whereEq(field: string, value: string | number | null): WhereClause {
  if (value === null) {
    return { clause: `${field} IS NULL`, args: [] };
  }
  const w: WhereClause = { clause: `${field} = ?`, args: [] };
  w.args.push(typeof value === 'number' ? `${value}` : value);
  return w;
}

export function buildInsert(table: string, fields: string[]): string {
  const cols = fields.join(', ');
  let marks = '';
  for (let i = 0; i < fields.length; i++) {
    marks += i === 0 ? '?' : ', ?';
  }
  return `INSERT INTO ${table} (${cols}) VALUES (${marks})`;
}

export function buildUpdate(table: string, fields: string[], where: string): SqlStatement {
  const st: SqlStatement = { sql: '', args: [] };
  let sets = '';
  for (let i = 0; i < fields.length; i++) {
    sets += i === 0 ? `${fields[i]} = ?` : `, ${fields[i]} = ?`;
  }
  st.sql = `UPDATE ${table} SET ${sets} WHERE ${where}`;
  return st;
}

// ───────────────────────── JWT（HS256） ─────────────────────────

export interface JwtClaims {
  sub: string;
  username: string;
  role: string;
  type: string;
  aud: string;
  iat: number;
  exp: number;
}

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

export function base64UrlEncode(s: string): string {
  const bytes = utf8Bytes(s);
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const b0 = bytes[i];
    const b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += B64.charAt(b0 >> 2);
    out += B64.charAt(((b0 & 0x03) << 4) | (b1 >> 4));
    out += i + 1 < bytes.length ? B64.charAt(((b1 & 0x0f) << 2) | (b2 >> 6)) : '=';
    out += i + 2 < bytes.length ? B64.charAt(b2 & 0x3f) : '=';
  }
  return out.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function utf8Bytes(s: string): number[] {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let cp = s.codePointAt(i) ?? 0;
    if (cp > 0xffff) {
      i++;
    }
    if (cp < 0x80) {
      out.push(cp);
    } else if (cp < 0x800) {
      out.push(0xc0 | (cp >> 6));
      out.push(0x80 | (cp & 0x3f));
    } else if (cp < 0x10000) {
      out.push(0xe0 | (cp >> 12));
      out.push(0x80 | ((cp >> 6) & 0x3f));
      out.push(0x80 | (cp & 0x3f));
    } else {
      out.push(0xf0 | (cp >> 18));
      out.push(0x80 | ((cp >> 12) & 0x3f));
      out.push(0x80 | ((cp >> 6) & 0x3f));
      out.push(0x80 | (cp & 0x3f));
    }
  }
  return out;
}

export function base64UrlDecode(s: string): string {
  let t = s.replace(/-/g, '+').replace(/_/g, '/');
  while (t.length % 4 !== 0) {
    t += '=';
  }
  return utf8Decode(base64DecodeToBytes(t));
}

export function base64DecodeToBytes(b64: string): number[] {
  const lut: number[] = [];
  for (let i = 0; i < 128; i++) {
    lut[i] = -1;
  }
  for (let i = 0; i < B64.length; i++) {
    lut[B64.charCodeAt(i)] = i;
  }
  const out: number[] = [];
  let acc = 0;
  let bits = 0;
  for (let i = 0; i < b64.length; i++) {
    const code = b64.charCodeAt(i);
    if (code === 61) {
      break; // '='
    }
    const v = code < 128 ? lut[code] : -1;
    if (v < 0) {
      continue;
    }
    acc = (acc << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((acc >> bits) & 0xff);
    }
  }
  return out;
}

export function utf8Decode(bytes: number[]): string {
  let out = '';
  let i = 0;
  while (i < bytes.length) {
    const b0 = bytes[i] & 0xff;
    let cp = 0;
    let extra = 0;
    // 注意：必须用掩码取出低位，否则 cp 会带上前导字节的高位
    if (b0 < 0x80) {
      cp = b0;
      extra = 0;
    } else if ((b0 & 0xe0) === 0xc0) {
      cp = b0 & 0x1f;
      extra = 1;
    } else if ((b0 & 0xf0) === 0xe0) {
      cp = b0 & 0x0f;
      extra = 2;
    } else {
      cp = b0 & 0x07;
      extra = 3;
    }
    i++;
    for (let k = 0; k < extra && i < bytes.length; k++, i++) {
      cp = (cp << 6) | (bytes[i] & 0x3f);
    }
    if (cp > 0xffff) {
      const c = cp - 0x10000;
      out += String.fromCharCode(0xd800 + (c >> 10), 0xdc00 + (c & 0x3ff));
    } else {
      out += String.fromCharCode(cp);
    }
  }
  return out;
}

export function decodeJwtPayload(token: string): JwtClaims | null {
  const parts = token.split('.');
  if (parts.length < 2) {
    return null;
  }
  try {
    const json = base64UrlDecode(parts[1]);
    return JSON.parse(json) as JwtClaims;
  } catch (e) {
    return null;
  }
}

export function jwtRole(token: string): string {
  const p = decodeJwtPayload(token);
  return p !== null ? p.role : '';
}

export function jwtUsername(token: string): string {
  const p = decodeJwtPayload(token);
  return p !== null ? p.username : '';
}

export function jwtUserId(token: string): number {
  const p = decodeJwtPayload(token);
  if (p === null) {
    return 0;
  }
  const n = Number(p.sub);
  return isFinite(n) && n > 0 ? Math.floor(n) : 0;
}

export function isTokenExpired(token: string, nowSec: number): boolean {
  const p = decodeJwtPayload(token);
  if (p === null || p.exp <= 0) {
    return true;
  }
  return p.exp - 60 <= nowSec;
}

// ───────────────────────── SSE 解析 ─────────────────────────

export interface SseChunk {
  events: string[];
  rest: string;
}

/**
 * 从一段 SSE 文本里抽出完整事件的 data。
 *
 * data 的值可能跨网络分片到达，单次调用只处理缓冲区里"完整"的事件，
 * 残缺的尾巴必须留在 rest 等下一片 —— 这是最容易写错的地方。
 */
export function parseSseChunk(buffer: string): SseChunk {
  const events: string[] = [];
  let rest = buffer;
  for (;;) {
    const b = findEventBoundary(rest);
    if (b < 0) {
      break;
    }
    const rawEvent = rest.slice(0, b);
    rest = rest.slice(b);
    const payload = extractDataLines(rawEvent);
    if (payload !== null) {
      events.push(payload);
    }
  }
  const out: SseChunk = { events: events, rest: rest };
  return out;
}

/** 返回事件边界长度；-1 表示还没攒够 */
function findEventBoundary(s: string): number {
  const a = s.indexOf('\n\n');
  const b = s.indexOf('\r\n\r\n');
  if (a >= 0) {
    if (b >= 0 && b < a) {
      return b + 4;
    }
    return a + 2;
  }
  if (b >= 0) {
    return b + 4;
  }
  return -1;
}

function extractDataLines(rawEvent: string): string | null {
  const lines = rawEvent.split(/\r?\n/);
  const parts: string[] = [];
  for (const line of lines) {
    if (line.startsWith(':')) {
      continue; // SSE 注释/心跳
    }
    if (line.startsWith('data:')) {
      let v = line.slice(5);
      if (v.startsWith(' ')) {
        v = v.slice(1);
      }
      parts.push(v);
    }
  }
  if (parts.length === 0) {
    return null;
  }
  return parts.join('\n');
}

export function isSseDone(eventData: string): boolean {
  return eventData.trim() === '[DONE]';
}

// OpenAI 兼容 chunk 的显式结构（禁止用 any / 动态键）
interface SseDelta {
  role: string;
  content: string;
  reasoning_content: string;
}

interface SseChoice {
  index: number;
  text: string;
  finish_reason: string;
  delta: SseDelta | null;
}

interface SseUsage {
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
}

interface SseError {
  message: string;
  type: string;
}

interface SseChunkBody {
  id: string;
  model: string;
  choices: SseChoice[];
  usage: SseUsage | null;
  error: SseError | null;
}

function emptyDelta(): SseDelta {
  return { role: '', content: '', reasoning_content: '' };
}

function emptySseBody(): SseChunkBody {
  return {
    id: '',
    model: '',
    choices: [],
    usage: null,
    error: null
  };
}

/**
 * 解析 SSE 载荷。真实流里字段经常缺失（delta 可能整个不存在，
 * usage 只在末帧出现），所以每层都要兜住，缺字段一律补默认值。
 * 这里「必须做防御」不是风格问题 —— 缺一个判空就会在真机上崩。
 */
export function parseSseBody(eventData: string): SseChunkBody {
  const body = emptySseBody();
  if (isSseDone(eventData)) {
    return body;
  }
  let raw: SseChunkBody | null = null;
  try {
    raw = JSON.parse(eventData) as SseChunkBody;
  } catch (e) {
    return emptySseBody();
  }
  if (raw === null) {
    return emptySseBody();
  }

  if (typeof raw.id === 'string') {
    body.id = raw.id;
  }
  if (typeof raw.model === 'string') {
    body.model = raw.model;
  }
  if (raw.error !== undefined && raw.error !== null) {
    body.error = raw.error;
  }
  if (raw.usage !== undefined && raw.usage !== null) {
    body.usage = raw.usage;
  }
  if (raw.choices !== undefined && raw.choices !== null && raw.choices.length > 0) {
    const c = raw.choices[0];
    // delta 可能是 null（OpenAI 的 finish 帧就是 {"delta":{}}）
    if (c !== undefined && c !== null) {
      body.choices.push(c);
    }
  }
  return body;
}

/** 取choice.delta，缺字段时给一个空壳 */
function deltaOf(choice: SseChoice | null): SseDelta {
  if (choice === null || choice === undefined) {
    return emptyDelta();
  }
  const d = choice.delta;
  if (d === undefined || d === null) {
    return emptyDelta();
  }
  const out = emptyDelta();
  if (typeof d.role === 'string') {
    out.role = d.role;
  }
  if (typeof d.content === 'string') {
    out.content = d.content;
  }
  if (typeof d.reasoning_content === 'string') {
    out.reasoning_content = d.reasoning_content;
  }
  return out;
}

/** 取 choice.text，兼容部分服务商的 completions 形态 */
function textOf(choice: SseChoice | null): string {
  if (choice === null || choice === undefined) {
    return '';
  }
  return typeof choice.text === 'string' ? choice.text : '';
}

/** 取增量文本；无内容返回空串（调用方保持原状态） */
export function extractDelta(eventData: string): string {
  if (isSseDone(eventData)) {
    return '';
  }
  const body = parseSseBody(eventData);
  if (body.error !== null && body.error.message.length > 0) {
    return '';
  }
  if (body.choices.length === 0) {
    return '';
  }
  const choice = body.choices[0];
  const d = deltaOf(choice);
  // reasoning_content 是部分服务商的思考字段，优先
  if (d.reasoning_content.length > 0) {
    return d.reasoning_content;
  }
  if (d.content.length > 0) {
    return d.content;
  }
  return textOf(choice);
}

export function extractUsage(eventData: string): UsageLite {
  const u: UsageLite = {
    inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, contextTokens: 0, costUsd: 0
  };
  if (isSseDone(eventData)) {
    return u;
  }
  const body = parseSseBody(eventData);
  const raw = body.usage;
  if (raw !== null) {
    u.inputTokens = typeof raw.prompt_tokens === 'number' ? raw.prompt_tokens : 0;
    u.outputTokens = typeof raw.completion_tokens === 'number' ? raw.completion_tokens : 0;
  }
  return u;
}

/** SSE 是否带 usage（末帧） */
export function hasUsage(eventData: string): boolean {
  if (isSseDone(eventData)) {
    return false;
  }
  const body = parseSseBody(eventData);
  const raw = body.usage;
  return raw !== null && (raw.prompt_tokens > 0 || raw.completion_tokens > 0);
}

/** 从 SSE 错误体里取文案 */
export function extractSseError(eventData: string): string {
  if (isSseDone(eventData)) {
    return '';
  }
  const body = parseSseBody(eventData);
  if (body.error === null) {
    return '';
  }
  return typeof body.error.message === 'string' ? body.error.message : '';
}

export function arrayBufferToString(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf);
  const arr: number[] = [];
  for (let i = 0; i < bytes.length; i++) {
    arr.push(bytes[i]);
  }
  return utf8Decode(arr);
}

// ───────────────────────── 排序 / 分组 ─────────────────────────

export interface SortableSession {
  pinned: boolean;
  active: boolean;
  updatedAt: number;
}

/** 置顶 > 活跃 > 最近更新。用显式比较，避免泛型 + 对象字面量类型。 */
export function sortSessionIndexes(list: SessionSortItem[]): number[] {
  const idx: number[] = [];
  for (let i = 0; i < list.length; i++) {
    idx.push(i);
  }
  idx.sort((a: number, b: number): number => {
    const x = list[a];
    const y = list[b];
    const px = x.pinned ? 1 : 0;
    const py = y.pinned ? 1 : 0;
    if (px !== py) {
      return py - px;
    }
    const ax = x.active ? 1 : 0;
    const ay = y.active ? 1 : 0;
    if (ax !== ay) {
      return ay - ax;
    }
    return y.updatedAt - x.updatedAt;
  });
  return idx;
}

export interface SessionSortItem {
  id: string;
  pinned: boolean;
  active: boolean;
  updatedAt: number;
}

export interface StringGroup<T> {
  key: string;
  items: T[];
}

export function groupBySource<T>(list: T[], keyOf: (t: T) => string): Array<StringGroup<T>> {
  const keys: string[] = [];
  const groups: Array<StringGroup<T>> = [];
  for (const item of list) {
    const k = keyOf(item);
    let gi = -1;
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] === k) {
        gi = i;
        break;
      }
    }
    if (gi < 0) {
      keys.push(k);
      const g: StringGroup<T> = { key: k, items: [] };
      g.items.push(item);
      groups.push(g);
    } else {
      groups[gi].items.push(item);
    }
  }
  groups.sort((a: StringGroup<T>, b: StringGroup<T>): number => b.items.length - a.items.length);
  return groups;
}

// ───────────────────────── 响应式断点 ─────────────────────────

/**
 * 断点阈值（可用窗口宽度，单位 vp）。
 *
 * 关键：判定必须用**窗口**宽度而非屏幕宽度 ——
 * PC 上窗口能被自由拉伸，物理屏宽不变但布局必须跟着变。
 * 折叠屏展开同理。
 */
export const BP_MEDIUM: number = 600;
export const BP_EXPANDED: number = 900;

export function breakpointOf(widthVp: number): string {
  if (!isFinite(widthVp) || widthVp <= 0) {
    return 'compact';
  }
  if (widthVp >= BP_EXPANDED) {
    return 'expanded';
  }
  if (widthVp >= BP_MEDIUM) {
    return 'medium';
  }
  return 'compact';
}

export function isWide(bp: string): boolean {
  return bp === 'expanded';
}

/** 是否显示左栏。折叠态永远不显示。 */
export function showSidebar(bp: string, collapsed: boolean): boolean {
  if (collapsed) {
    return false;
  }
  return bp === 'expanded' || bp === 'medium';
}

/**
 * 双栏比例夹取。
 * 下限防左栏被拖没（会话列表消失，用户找不到入口），
 * 上限防右栏被挤成一条缝（消息看不了）。
 */
export function clampRatio(r: number): number {
  if (!isFinite(r)) {
    return 0.28;
  }
  if (r < 0.18) {
    return 0.18;
  }
  if (r > 0.46) {
    return 0.46;
  }
  return r;
}

/** 正文舒适行长（vp）。PC 宽屏铺满会导致行长 200+ 字符，不可读。 */
export function readableWidth(bp: string, sidebarRatio: number): number {
  if (bp === 'expanded') {
    return 760;
  }
  if (bp === 'medium') {
    return 680;
  }
  return 0; // compact 铺满
}

/** 布局密度：宽屏行高可以松一点，手机要紧凑 */
export function rowPadding(bp: string): number {
  return bp === 'expanded' ? 14 : 12;
}

// ───────────────────────── Cron 解析与调度 ─────────────────────────

/** 解析结果：合法则为 5 段数组，不合法时 error 有值 */
export interface CronParsed {
  minute: number[];
  hour: number[];
  dayOfMonth: number[];
  month: number[];
  dayOfWeek: number[];
  valid: boolean;
  error: string;
}

export function emptyCron(): CronParsed {
  return {
    minute: [], hour: [], dayOfMonth: [], month: [], dayOfWeek: [],
    valid: false, error: ''
  };
}

/** 把单个 cron 字段展开成取值列表：星号 / a-b / a,b,c / 步长形式 */
export function expandCronField(field: string, min: number, max: number): number[] {
  const out: number[] = [];
  const parts = field.split(',');
  for (const raw of parts) {
    const p = raw.trim();
    if (p.length === 0) {
      continue;
    }
    if (p === '*') {
      for (let v = min; v <= max; v++) {
        pushUnique(out, v);
      }
      continue;
    }
    const slash = p.indexOf('/');
    if (slash >= 0) {
      const base = p.slice(0, slash).trim();
      const stepStr = p.slice(slash + 1).trim();
      const step = Number(stepStr);
      if (!isFinite(step) || step <= 0 || step !== Math.floor(step)) {
        continue;
      }
      let lo = min;
      let hi = max;
      if (base.length > 0) {
        if (base === '*') {
          lo = min;
        } else {
          const dash = base.indexOf('-');
          if (dash > 0) {
            const a = Number(base.slice(0, dash).trim());
            const b = Number(base.slice(dash + 1).trim());
            if (!inRange(a, min, max) || !inRange(b, min, max) || a > b) {
              continue;
            }
            lo = a;
            hi = b;
          } else {
            const a = Number(base.trim());
            if (!inRange(a, min, max)) {
              continue;
            }
            lo = a;
            hi = max;
          }
        }
      }
      for (let v = lo; v <= hi; v += step) {
        pushUnique(out, v);
      }
      continue;
    }
    const dash = p.indexOf('-');
    if (dash > 0) {
      const a = Number(p.slice(0, dash).trim());
      const b = Number(p.slice(dash + 1).trim());
      if (!inRange(a, min, max) || !inRange(b, min, max) || a > b) {
        continue;
      }
      for (let v = a; v <= b; v++) {
        pushUnique(out, v);
      }
      continue;
    }
    const n = Number(p);
    if (inRange(n, min, max)) {
      pushUnique(out, n);
    }
  }
  out.sort((a: number, b: number): number => a - b);
  return out;
}

function pushUnique(list: number[], v: number): void {
  if (list.indexOf(v) === -1) {
    list.push(v);
  }
}

function inRange(n: number, min: number, max: number): boolean {
  return isFinite(n) && n === Math.floor(n) && n >= min && n <= max;
}

/** 解析 5 段 cron：分 时 日 月 周 */
export function parseCron(expr: string): CronParsed {
  const res = emptyCron();
  const fields = expr.trim().split(/\s+/).filter((s: string) => s.length > 0);
  if (fields.length !== 5) {
    res.error = `需要 5 段（分 时 日月 周），当前 ${fields.length} 段`;
    return res;
  }
  const minute = expandCronField(fields[0], 0, 59);
  const hour = expandCronField(fields[1], 0, 23);
  const dom = expandCronField(fields[2], 1, 31);
  const month = expandCronField(fields[3], 1, 12);
  // 周字段取0..7：cron 约定 0 与 7 都是周日
  const dow = expandCronField(fields[4], 0, 7);
  if (minute.length === 0 || hour.length === 0 || dom.length === 0 ||
      month.length === 0 || dow.length === 0) {
    res.error = '存在无法解析的字段';
    return res;
  }
  res.minute = minute;
  res.hour = hour;
  res.dayOfMonth = dom;
  res.month = month;
  // 7 归一到 0，两者都是周日
  const dowOut = dow.slice();
  if (dowOut.indexOf(7) >= 0) {
    const at = dowOut.indexOf(7);
    dowOut[at] = 0;
  }
  res.dayOfWeek = dowOut.sort((a: number, b: number): number => a - b);
  res.valid = true;
  return res;
}

/** 某时刻是否命中 cron */
export function cronMatches(p: CronParsed, ts: number): boolean {
  if (!p.valid) {
    return false;
  }
  const d = new Date(ts);
  if (p.minute.indexOf(d.getMinutes()) === -1) {
    return false;
  }
  if (p.hour.indexOf(d.getHours()) === -1) {
    return false;
  }
  if (p.month.indexOf(d.getMonth() + 1) === -1) {
    return false;
  }
  // 标准 cron 语义：日与周任一命中即可（都写 * 时才要求同时）
  const domHit = p.dayOfMonth.indexOf(d.getDate()) >= 0;
  const dowHit = p.dayOfWeek.indexOf(d.getDay()) >= 0;
  const domStar = p.dayOfMonth.length === 31;
  const dowStar = p.dayOfWeek.length >= 7;
  if (domStar && dowStar) {
    return true;
  }
  if (domStar) {
    return dowHit;
  }
  if (dowStar) {
    return domHit;
  }
  return domHit || dowHit;
}

/**
 * 从 fromMs 起找下一个命中时刻（毫秒）。
 * 最多往后找366 天，找不到返回 0。
 */
export function nextCronRun(p: CronParsed, fromMs: number): number {
  if (!p.valid) {
    return 0;
  }
  const step = 60000; // 1分钟
  // 对齐到分钟起点，避免秒/毫秒残留导致永不命中
  let t = Math.floor(fromMs / step) * step + step;
  const limit = fromMs + 366 * 86400000;
  // 每分钟检查，最多 527040 次；用跳日优化先粗筛
  while (t <= limit) {
    if (cronMatches(p, t)) {
      return t;
    }
    t += step;
  }
  return 0;
}

/** 常用预设（与原版 JobsView 的预设一致） */
export function cronPresets(): string[] {
  return [
    '*/5 * * * *',
    '0 * * * *',
    '0 9 * * *',
    '0 9 * * 1-5',
    '30 8 * * 1'
  ];
}

export function cronPresetLabel(expr: string): string {
  if (expr === '*/5 * * * *') {
    return '每 5 分钟';
  }
  if (expr === '0 * * * *') {
    return '每小时';
  }
  if (expr === '0 9 * * *') {
    return '每天 09:00';
  }
  if (expr === '0 9 * * 1-5') {
    return '工作日 09:00';
  }
  if (expr === '30 8 * * 1') {
    return '每周一 08:30';
  }
  return '自定义';
}

// ───────────────────────── 看板流转 ─────────────────────────

/** 看板列的默认顺序 */
export function kanbanDefaultColumns(): string[] {
  return ['待办', '进行中', '已完成'];
}

/** 优先级：0高 1中 2低 */
export function priorityLabel(p: number): string {
  if (p === 0) {
    return '高';
  }
  if (p === 2) {
    return '低';
  }
  return '中';
}

/**
 * WIP 限制下插入位置后的新位置。
 * 超限时插入返回 -1（调用方应拒绝这次移动并提示）。
 */
export function insertPosition(currentCount: number, wipLimit: number, desired: number): number {
  if (wipLimit > 0 && currentCount >= wipLimit) {
    return -1;
  }
  if (desired < 0) {
    return 0;
  }
  if (desired > currentCount) {
    return currentCount;
  }
  return desired;
}

/** 把一列的卡片按新位置重排（返回 id 顺序） */
export function reorderIds(ids: string[], fromIdx: number, toIdx: number): string[] {
  const out = ids.slice();
  if (fromIdx < 0 || fromIdx >= out.length) {
    return out;
  }
  const target = Math.max(0, Math.min(out.length - 1, toIdx));
  const moved = out.splice(fromIdx, 1)[0];
  out.splice(target, 0, moved);
  return out;
}

// ───────────────────────── 路径与文件名 ─────────────────────────

/** 文件扩展名（小写，含点），无扩展名返回空串 */
export function fileExt(path: string): string {
  const i = path.lastIndexOf('.');
  if (i < 0 || i === path.length - 1) {
    return '';
  }
  const slash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
  if (i < slash) {
    return '';
  }
  return path.slice(i).toLowerCase();
}

/** 文件名（去目录） */
export function baseName(path: string): string {
  let cut = -1;
  for (let i = 0; i < path.length; i++) {
    const c = path.charAt(i);
    if (c === '/' || c === '\\') {
      cut = i;
    }
  }
  return cut >= 0 ? path.slice(cut + 1) : path;
}

/** 父目录 */
export function dirName(path: string): string {
  let cut = -1;
  for (let i = 0; i < path.length; i++) {
    const c = path.charAt(i);
    if (c === '/' || c === '\\') {
      cut = i;
    }
  }
  if (cut < 0) {
    return '';
  }
  if (cut === 0) {
    return '/';
  }
  return path.slice(0, cut);
}

/**
 * 沙箱路径安全检查。
 *
 * 规则：路径**绝不能**向上逃出沙箱根。做法是先解析出最终的规范化形式，
 * 再判断它是否试图越过起点 —— 单纯「不能出现 ..」过严（`a/../b` 其实安全），
 * 而单纯「累计深度」会漏掉 `a/../../b`。
 */
export function isSafeRelativePath(p: string): boolean {
  if (p.length === 0) {
    return false;
  }
  if (p.indexOf('\u0000') >= 0) {
    return false;
  }
  // 绝对路径一律不接受（调用方应先拼接沙箱根）
  if (p.charAt(0) === '/' || p.charAt(0) === '\\') {
    return false;
  }
  const segs = p.split(/[\\/]+/);
  // 逐段解析深度：.. 减一，普通段加一，任何时刻 < 0 就是逃逸
  let depth = 0;
  for (const s of segs) {
    if (s.length === 0 || s === '.') {
      continue;
    }
    if (s === '..') {
      depth--;
      if (depth < 0) {
        return false;
      }
      continue;
    }
    depth++;
  }
  return true;
}

/** 按扩展名猜 MIME（覆盖预览需要的常见类型） */
export function guessMime(ext: string): string {
  if (ext === '.jpg' || ext === '.jpeg') {
    return 'image/jpeg';
  }
  if (ext === '.png' || ext === '.gif' || ext === '.webp' || ext === '.bmp') {
    return 'image/' + ext.slice(1);
  }
  if (ext === '.svg') {
    return 'image/svg+xml';
  }
  if (ext === '.json' || ext === '.jsonc') {
    return 'application/json';
  }
  if (ext === '.md') {
    return 'text/markdown';
  }
  if (ext === '.txt' || ext === '.log') {
    return 'text/plain';
  }
  if (ext === '.pdf') {
    return 'application/pdf';
  }
  if (ext === '.har') {
    return 'application/json';
  }
  if (ext === '.docx') {
    return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  }
  if (ext === '.xlsx') {
    return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  }
  if (ext === '.pptx') {
    return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
  }
  if (ext === '.csv') {
    return 'text/csv';
  }
  if (ext === '.mp4' || ext === '.mov' || ext === '.webm') {
    return 'video/' + ext.slice(1);
  }
  if (ext === '.mp3' || ext === '.wav' || ext === '.m4a') {
    return 'audio/' + ext.slice(1);
  }
  return 'application/octet-stream';
}

/** 人类可读体积 */
export function humanSize(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

export function shortId(nowMs: number, rand: number): string {
  return nowMs.toString(36) + Math.floor(rand * 0xffffff).toString(36);
}

export function isActivelyStreaming(lastDeltaAt: number, status: string, now: number): boolean {
  if (status !== 'streaming') {
    return false;
  }
  return now - lastDeltaAt < 2000;
}