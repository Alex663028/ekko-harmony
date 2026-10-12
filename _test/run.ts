/**
 * Core.ets 纯逻辑回归测试（ArkTS 改造后）。
 * 运行：node --experimental-transform-types --no-warnings run.ts
 *
 * 断言分两类：
 *  - 业务不变量（该等于什么）
 *  - ArkTS 改造防线（确认接口形态没被改回TS 风格）
 */
import {
  displayWidth, padDisplay, formatNumber, compactNumber, relativeTime,
  extractMentionNames, resolveMentions, matchAgentIndex, validateGroupMessage,
  reduceRunEvent, emptyStream, emptyRunEvent, previewOf, parseInlineMd, detectLang,
  sqlEscape, buildInsert, buildUpdate, whereEq, base64UrlEncode, base64UrlDecode,
  decodeJwtPayload, jwtRole, jwtUsername, jwtUserId, isTokenExpired, shortId,
  sortSessionIndexes, utf8Bytes, utf8Decode, groupBySource,
  type MentionCandidate, type TraceLite, type StreamState, type UsageLite,
} from './Core.ts';

let pass = 0;
let fail = 0;
const failures: string[] = [];

function check(name: string, actual: unknown, expected: unknown): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) { pass++; } else {
    fail++;
    failures.push(`  ✗ ${name}\n     实际 ${a}\n     期望 ${e}`);
  }
}

function ok(name: string, cond: boolean, detail: string = ''): void {
  if (cond) { pass++; } else {
    fail++;
    failures.push(`  ✗ ${name}${detail ? ' — ' + detail : ''}`);
  }
}

const NOW = 1767225600000;

// ───── 格式化 ─────
check('formatNumber 千分位', formatNumber(1234.5), '1,234.50');
check('formatNumber 负数', formatNumber(-9876.5), '-9,876.50');
check('formatNumber 0', formatNumber(0), '0.00');
check('formatNumber Infinity 兜底', formatNumber(Infinity), '0');
check('formatNumber 七位数', formatNumber(12345678.9), '12,345,678.90');
check('compactNumber K', compactNumber(12345), '12.3K');
check('compactNumber M', compactNumber(2500000), '2.5M');
check('compactNumber B', compactNumber(3000000000), '3B');
check('compactNumber 小值', compactNumber(999), '999');
check('displayWidth 纯ASCII', displayWidth('abc'), 3);
check('displayWidth 中文', displayWidth('你好'), 4);
check('displayWidth emoji', displayWidth('🎉'), 2);
check('padDisplay 左对齐按显示宽度补齐', displayWidth(padDisplay('你好', 6)), 6);
check('padDisplay 右对齐', padDisplay('ab', 5, false), '   ab');
check('padDisplay 已超宽不截断', padDisplay('abcdef', 3), 'abcdef');
check('relativeTime 分钟', relativeTime(NOW - 3 * 60000, NOW), '3分钟前');
check('relativeTime 刚刚', relativeTime(NOW - 20000, NOW), '刚刚');
check('relativeTime 小时', relativeTime(NOW - 5 * 3600000, NOW), '5小时前');
check('relativeTime 昨天', relativeTime(NOW - 26 * 3600000, NOW), '昨天');

// ───── @ 提及 ─────
check('extractMentionNames 基础',
  extractMentionNames('@codex 帮我看下这个 bug'), ['codex']);
check('extractMentionNames 多个',
  extractMentionNames('@codex 和 @Claude 都来'), ['codex', 'Claude']);
check('extractMentionNames 中文标点截断',
  extractMentionNames('@codex，帮我修'), ['codex']);
check('extractMentionNames 去重',
  extractMentionNames('@a @a @b'), ['a', 'b']);
check('extractMentionNames 无提及',
  extractMentionNames('没有提及任何人'), []);

function agent(agentId: string, name: string, removedAt: number = 0, canMentionAll: boolean = false): MentionCandidate {
  return { agentId, recordId: 'rec-' + agentId, name, removedAt, canMentionAll };
}

const AGENTS: MentionCandidate[] = [
  agent('mudc2v075brr6f', 'codex'),
  agent('ag-claude-1', 'Claude Code'),
  agent('ag-grok', 'Grok'),
  agent('ag-old', 'Legacy', 1),
];

check('matchAgentIndex 精确', matchAgentIndex('codex', AGENTS), 0);
check('matchAgentIndex 去空格+忽略大小写', matchAgentIndex('claudecode', AGENTS), 1);
check('matchAgentIndex 带空格原名', matchAgentIndex('Claude Code', AGENTS), 1);
check('matchAgentIndex 前缀', matchAgentIndex('cod', AGENTS), 0);
check('matchAgentIndex 忽略已移除', matchAgentIndex('Legacy', AGENTS), -1);
check('matchAgentIndex 未知', matchAgentIndex('nope', AGENTS), -1);

const refs = resolveMentions('@codex 请处理 @Legacy 和 @unknown', AGENTS);
check('resolveMentions 只保留真实 Agent', refs.length, 1);
check('resolveMentions 用 agentId 而非记录 id', refs[0].participantId, 'mudc2v075brr6f');
check('resolveMentions 携带显示名', refs[0].displayName, 'codex');

const refs2 = resolveMentions('@claudecode 上', AGENTS);
check('resolveMentions 无空格也能命中', refs2[0].participantId, 'ag-claude-1');
check('resolveMentions 无权限时 all 丢弃',
  resolveMentions('@all 汇报', AGENTS).length, 0);

const refsAll = resolveMentions('@all 汇报',
  [agent('a1', 'x', 0, true)]);
check('resolveMentions 有权限时 all 命中', refsAll[0].type, 'all');

check('validateGroupMessage 空消息', validateGroupMessage('  ', refs), '消息不能为空');
ok('validateGroupMessage 未@提示', validateGroupMessage('随便说句', []).indexOf('@') >= 0);
check('validateGroupMessage 正常', validateGroupMessage('@codex 干活', refs), '');

// ───── 流式事件归约 ─────
function ev(event: string): ReturnType<typeof emptyRunEvent> {
  return emptyRunEvent(event);
}

let st: StreamState = emptyStream();
ok('初始 idle', st.status === 'idle' && st.text === '');
st = reduceRunEvent(st, (() => { const e = ev('run.started'); e.run_id = 'r1'; return e; })());
ok('run.started → streaming', st.status === 'streaming');

st = reduceRunEvent(st, (() => { const e = ev('message.delta'); e.delta = '你好'; return e; })());
st = reduceRunEvent(st, (() => { const e = ev('message.delta'); e.delta = '，世界'; return e; })());
check('message.delta 累加', st.text, '你好，世界');

st = reduceRunEvent(st, (() => { const e = ev('reasoning.delta'); e.text = '想一下'; return e; })());
st = reduceRunEvent(st, (() => { const e = ev('thinking.delta'); e.text = '再想'; return e; })());
check('reasoning+thinking 累加', st.reasoning, '想一下再想');

st = reduceRunEvent(st, (() => { const e = ev('reasoning.available'); e.text = '最终思考'; return e; })());
check('reasoning.available 替换', st.reasoning, '最终思考');

st = reduceRunEvent(st, (() => { const e = ev('tool.started'); e.name = 'read_file'; e.argsJson = '{"path":"a.ts"}'; return e; })());
check('tool.started running', st.tools[0].status, 'running');
check('tool.started 记参数', st.tools[0].args, '{"path":"a.ts"}');

st = reduceRunEvent(st, (() => { const e = ev('tool.completed'); e.name = 'read_file'; e.argsJson = '{"ok":true}'; return e; })());
check('tool.completed → ok', st.tools[0].status, 'ok');
check('tool.completed 记结果', st.tools[0].result, '{"ok":true}');

st = reduceRunEvent(st, (() => { const e = ev('tool.started'); e.name = 'read_file'; e.argsJson = '{"path":"b.ts"}'; return e; })());
st = reduceRunEvent(st, (() => { const e = ev('tool.failed'); e.name = 'read_file'; e.error = 'EACCES'; return e; })());
check('同名工具多次调用分别结算', st.tools.length, 2);
check('第二次失败标记', st.tools[1].status, 'failed');
check('failed 无 argsJson 时回落 error', st.tools[1].result, 'EACCES');

st = reduceRunEvent(st, (() => {
  const e = ev('run.usage.updated');
  e.usage.input_tokens = 100; e.usage.output_tokens = 50;
  e.usage.cache_read_tokens = 20; e.usage.cost_usd = 0.02;
  return e;
})());
check('usage 合并 input', st.usage.inputTokens, 100);
check('usage 合并 cache', st.usage.cacheReadTokens, 20);
check('usage 合并 cost', st.usage.costUsd, 0.02);

st = reduceRunEvent(st, (() => { const e = ev('session.title.updated'); e.title = '修 bug'; return e; })());
check('标题更新', st.title, '修 bug');

st = reduceRunEvent(st, (() => { const e = ev('run.completed'); e.output = '最终答案'; return e; })());
check('run.completed 用 output 覆盖', st.text, '最终答案');
check('run.completed → done', st.status, 'done');

let st2 = reduceRunEvent(emptyStream(), (() => { const e = ev('run.failed'); e.error = '配额耗尽'; return e; })());
check('run.failed → failed', st2.status, 'failed');
check('run.failed 带错误', st2.error, '配额耗尽');

check('abort.completed → aborted',
  reduceRunEvent(emptyStream(), ev('abort.completed')).status, 'aborted');
check('未知事件不崩', reduceRunEvent(emptyStream(), ev('x.y')).status, 'idle');

// 归约不修改传入的state（ArkUI 依赖这个性质）
const before: StreamState = emptyStream();
const snapshot = before.text;
reduceRunEvent(before, (() => { const e = ev('message.delta'); e.delta = '不改我'; return e; })());
check('归约不改原对象', before.text, snapshot);

check('previewOf 截断', previewOf('a'.repeat(100), 10), `${'a'.repeat(10)}…`);
check('previewOf 去换行', previewOf('a\n  b'), 'a b');

// ───── Markdown ─────
const segs = parseInlineMd('前**粗**中`code`后');
check('分段数量', segs.length, 5);
check('粗体段类型', segs[1].kind, 'bold');
check('粗体内容', segs[1].value, '粗');
check('行内代码类型', segs[3].kind, 'code');
check('行内代码内容', segs[3].value, 'code');

const cb = parseInlineMd('```typescript\nconst a=1;\n```');
check('代码块段数', cb.length, 1);
check('代码块类型', cb[0].kind, 'codeblock');
check('代码块语言', cb[0].lang, 'typescript');
check('代码块内容（去尾换行）', cb[0].value, 'const a=1;');
check('无语言代码块', parseInlineMd('```\nplain\n```')[0].lang, '');
check('detectLang ts', detectLang('ts'), 'typescript');
check('detectLang python', detectLang('python'), 'python');
check('detectLang 未知', detectLang('rust'), 'text');

// ───── SQL ─────
check('sqlEscape 单引号', sqlEscape("it's"), "it''s");
check('sqlEscape 无引号', sqlEscape('abc'), 'abc');
check('buildInsert', buildInsert('sessions', ['id', 'title']),
  'INSERT INTO sessions (id, title) VALUES (?, ?)');
check('buildInsert 单列', buildInsert('t', ['a']), 'INSERT INTO t (a) VALUES (?)');
const u = buildUpdate('sessions', ['title', 'model'], 'id = ?');
check('buildUpdate SQL', u.sql, 'UPDATE sessions SET title = ?, model = ? WHERE id = ?');
const w = whereEq('category_id', 5);
check('whereEq 数字', w.clause, 'category_id = ?');
check('whereEq 数字参数', w.args, ['5']);
check('whereEq null', whereEq('category_id', null).clause, 'category_id IS NULL');

// ───── JWT / base64 ─────
const b64 = base64UrlEncode('{"alg":"HS256","typ":"JWT"}');
ok('base64url 无 padding', b64.indexOf('=') === -1);
ok('base64url 无 + /', b64.indexOf('+') === -1 && b64.indexOf('/') === -1);
check('base64url 往返', base64UrlDecode(b64), '{"alg":"HS256","typ":"JWT"}');
check('utf8 中文往返', utf8Decode(utf8Bytes('中文测试')), '中文测试');
check('utf8 emoji 往返', utf8Decode(utf8Bytes('🎉ok')), '🎉ok');
check('utf8 emoji 字节数', utf8Bytes('🎉').length, 4);
ok('utf8 空格往返', utf8Decode(utf8Bytes('a b')) === 'a b');

const token = [
  base64UrlEncode(JSON.stringify({ alg: 'HS256', typ: 'JWT' })),
  base64UrlEncode(JSON.stringify({ sub: '1', username: 'ALEX', role: 'super_admin', exp: 1767225600 + 3600 })),
  base64UrlEncode('sig')
].join('.');
check('jwtRole', jwtRole(token), 'super_admin');
check('jwtUsername', jwtUsername(token), 'ALEX');
check('jwtUserId', jwtUserId(token), 1);
ok('未过期', isTokenExpired(token, 1767225600) === false);
ok('已过期', isTokenExpired(token, 1767225600 + 3600) === true);
check('垃圾 token 不崩', decodeJwtPayload('not.a.jwt'), null);
check('空 token userId', jwtUserId('xxx'), 0);

// ───── 排序 / 分组 / id ─────
const SESS = [
  { id: 'a', updatedAt: 100, pinned: false, active: false },
  { id: 'b', updatedAt: 300, pinned: true, active: false },
  { id: 'c', updatedAt: 200, pinned: false, active: true },
  { id: 'd', updatedAt: 50, pinned: false, active: false },
];
const order = sortSessionIndexes(SESS).map((i) => SESS[i].id);
check('排序：置顶 > 活跃 > 最近', order, ['b', 'c', 'a', 'd']);
ok('shortId 长度', shortId(1767225600000, 0.5).length > 6);

const groups = groupBySource(
  [{ s: 'local' }, { s: 'tg' }, { s: 'local' }, { s: 'slack' }],
  (x) => x.s);
check('分组数', groups.length, 3);
check('按数量降序', groups[0].items.length, 2);

console.log('─'.repeat(56));
console.log(`Core.ets 回归：  通过 ${pass} · 失败 ${fail}`);
console.log('─'.repeat(56));
if (fail > 0) {
  console.log('\n失败详情：');
  failures.forEach((f) => console.log(f));
  process.exit(1);
}
console.log('\n>>> 全部通过');