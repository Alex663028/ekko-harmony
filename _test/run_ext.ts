/**
 * 第二批纯逻辑回归：响应式断点 + Cron + 看板 + 路径安全。
 * 运行：node --experimental-transform-types --no-warnings run_ext.ts
 */
import {
  breakpointOf, isWide, showSidebar, clampRatio, readableWidth, rowPadding,
  expandCronField, parseCron, cronMatches, nextCronRun, cronPresetLabel, cronPresets,
  kanbanDefaultColumns, priorityLabel, insertPosition, reorderIds,
  fileExt, baseName, dirName, isSafeRelativePath, guessMime, humanSize,
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

// ───── 响应式断点 ─────
check('手机竖屏 → compact', breakpointOf(360), 'compact');
check('平板 800 → medium', breakpointOf(800), 'medium');
check('PC 1440 → expanded', breakpointOf(1440), 'expanded');
check('PC 最小双栏 900 边界', breakpointOf(900), 'expanded');
check('900-1 落medium', breakpointOf(899), 'medium');
check('600 边界 → medium', breakpointOf(600), 'medium');
check('599 → compact', breakpointOf(599), 'compact');
check('0 宽度兜底', breakpointOf(0), 'compact');
check('负宽度兜底', breakpointOf(-100), 'compact');
check('NaN 兜底', breakpointOf(NaN), 'compact');

check('isWide', isWide('expanded'), true);
check('isWide medium', isWide('medium'), false);
check('compact 不显示侧栏', showSidebar('compact', false), false);
check('medium 显示侧栏', showSidebar('medium', false), true);
check('expanded 显示侧栏', showSidebar('expanded', false), true);
check('折叠时永不显示', showSidebar('expanded', true), false);
check('折叠时 medium 也不显示', showSidebar('medium', true), false);

check('比例夹取下限', clampRatio(0.05), 0.18);
check('比例夹取上限', clampRatio(0.9), 0.46);
check('比例正常值', clampRatio(0.3), 0.3);
check('比例 NaN 兜底', clampRatio(NaN), 0.28);
check('可读宽度 expanded', readableWidth('expanded', 0.28), 760);
check('可读宽度 compact 铺满', readableWidth('compact', 0.28), 0);
check('行高宽屏更松', rowPadding('expanded') > rowPadding('compact'), true);

// ───── Cron 字段展开 ─────
check('* 展开分钟', expandCronField('*', 0, 59).length, 60);
check('单值', expandCronField('30', 0, 59), [30]);
check('区间', expandCronField('1-5', 0, 59), [1, 2, 3, 4, 5]);
check('列表', expandCronField('0,15,30', 0, 59), [0, 15, 30]);
check('步长', expandCronField('*/15', 0, 59), [0, 15, 30, 45]);
check('区间+步长', expandCronField('0-30/10', 0, 59), [0, 10, 20, 30]);
check('起点+步长', expandCronField('5/20', 0, 59), [5, 25, 45]);
check('周字段 7 合法（cron 约定周日）', expandCronField('7', 0, 7), [7]);
check('越界丢弃', expandCronField('99', 0, 59), []);
check('非数字丢弃', expandCronField('abc', 0, 59), []);
check('步长 0 丢弃', expandCronField('*/0', 0, 59), []);
check('区间反了丢弃', expandCronField('5-1', 0, 59), []);

// ───── Cron 解析 ─────
let c = parseCron('*/5 * * * *');
ok('标准 cron 合法', c.valid);
check('分钟步长', c.minute, [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55]);
check('小时全展开', c.hour.length, 24);

c = parseCron('0 9 * * 1-5');
ok('工作日 cron 合法', c.valid);
check('周取值', c.dayOfWeek, [1, 2, 3, 4, 5]);

check('段数不对报错', parseCron('0 9 * *').valid, false);
ok('段数不对有 error', parseCron('0 9 * *').error.length > 0);
check('6 段无效', parseCron('0 9 * * * *').valid, false);
check('空串无效', parseCron('').valid, false);
ok('非法字段有 error', parseCron('99 9 * * *').error.length > 0);

// 周日双写
c = parseCron('0 9 * * 7');
check('周7 在解析后归一到 0', c.dayOfWeek.indexOf(0) >= 0, true);

// ───── Cron 匹配 ─────
const every5 = parseCron('*/5 * * * *');
// 2026-01-01T00:00:00 本地时间
const base = new Date(2026, 0, 1, 10, 0, 0).getTime();
ok('整点命中 */5', cronMatches(every5, base));
ok('非 5 倍数不命中', cronMatches(every5, base + 3 * 60000) === false);

const workday9 = parseCron('0 9 * * 1-5');
// 2026-01-01 是周四
const thu9 = new Date(2026, 0, 1, 9, 0, 0).getTime();
ok('周四 9 点命中', cronMatches(workday9, thu9));
ok('周四 10 点不命中', cronMatches(workday9, new Date(2026, 0, 1, 10, 0, 0).getTime()) === false);
// 2026-01-03 是周六
const sat9 = new Date(2026, 0, 3, 9, 0, 0).getTime();
ok('周六不命中工作日', cronMatches(workday9, sat9) === false);
ok('非法 cron 不命中', cronMatches(parseCron('bad'), base) === false);

// 全星：每天任意时刻都命中
const always = parseCron('* * * * *');
ok('全星命中任意分钟', cronMatches(always, base));
ok('全星命中任意秒', cronMatches(always, new Date(2026, 5, 15, 3, 7, 45).getTime()));

// ───── 下次运行 ─────
let n = nextCronRun(every5, base);
ok('下次 */5 在 5 分钟内', n > base && n - base <= 5 * 60000);
check('下次运行秒/毫秒归零', n % 1000, 0);

const at930 = new Date(2026, 0, 1, 9, 30, 0).getTime();
n = nextCronRun(parseCron('0 9 * * *'), at930);
const nx = new Date(n);
check('每天9点的下次是次日9点', nx.getHours(), 9);
check('次日是1月2日', nx.getDate(), 2);
check('次日月', nx.getMonth(), 0);

check('非法 cron 无下次', nextCronRun(parseCron('x'), base), 0);
// 10:04:30 的下一个 */5 时点是 10:05:00，差 30000ms
check('分钟中间起算对齐到下一个 5 分', nextCronRun(every5, new Date(2026, 0, 1, 10, 4, 30).getTime()) -
  new Date(2026, 0, 1, 10, 4, 30).getTime(), 30000);

check('预设数量', cronPresets().length, 5);
check('预设标签', cronPresetLabel('0 9 * * *'), '每天 09:00');
check('自定义标签', cronPresetLabel('1 1 1 1 1'), '自定义');

// ───── 看板 ─────
check('默认列', kanbanDefaultColumns(), ['待办', '进行中', '已完成']);
check('优先级 高', priorityLabel(0), '高');
check('优先级 中', priorityLabel(1), '中');
check('优先级 低', priorityLabel(2), '低');

check('未超限插入到指定位置', insertPosition(3, 0, 1), 1);
check('未超限插到末尾', insertPosition(3, 0, 99), 3);
check('未超限插到最前', insertPosition(3, 0, -5), 0);
check('超限拒绝', insertPosition(3, 3, 1), -1);
check('未到限允许', insertPosition(2, 3, 1), 1);

check('下移', reorderIds(['a', 'b', 'c'], 0, 2), ['b', 'c', 'a']);
check('上移', reorderIds(['a', 'b', 'c'], 2, 0), ['c', 'a', 'b']);
check('原位', reorderIds(['a', 'b', 'c'], 1, 1), ['a', 'b', 'c']);
check('越界下标不动', reorderIds(['a', 'b'], 9, 0), ['a', 'b']);
check('超出末尾夹取', reorderIds(['a', 'b'], 0, 99), ['b', 'a']);

// ───── 路径 ─────
check('扩展名', fileExt('/a/b/c.PNG'), '.png');
check('无扩展名', fileExt('/a/b/c'), '');
check('点结尾无扩展名', fileExt('x.'), '');
check('目录里的点不算扩展名', fileExt('/a.b/c'), '');
check('文件名', baseName('/a/b/c.txt'), 'c.txt');
check('文件名无目录', baseName('c.txt'), 'c.txt');
check('父目录', dirName('/a/b/c.txt'), '/a/b');
check('父目录根', dirName('/c'), '/');
check('无目录父目录为空', dirName('c'), '');

ok('正常相对路径安全', isSafeRelativePath('a/b.txt'));
ok('父级不出沙箱安全', isSafeRelativePath('a/../b.txt'));
ok('穿越到根不安全', isSafeRelativePath('../secret') === false);
ok('多层穿越不安全', isSafeRelativePath('a/../../secret') === false);
ok('空路径不安全', isSafeRelativePath('') === false);
ok('含空字节不安全', isSafeRelativePath('a\u0000b') === false);

check('MIME png', guessMime('.png'), 'image/png');
check('MIME jpg', guessMime('.jpg'), 'image/jpeg');
check('MIME json', guessMime('.json'), 'application/json');
check('MIME 未知', guessMime('.zzz'), 'application/octet-stream');
check('人类体积 B', humanSize(512), '512 B');
check('人类体积 KB', humanSize(2048), '2.0 KB');
check('人类体积 MB', humanSize(5 * 1024 * 1024), '5.0 MB');

console.log('─'.repeat(56));
console.log(`扩展纯逻辑回归：  通过 ${pass} · 失败 ${fail}`);
console.log('─'.repeat(56));
if (fail > 0) {
  console.log('\n失败详情：');
  failures.forEach((f) => console.log(f));
  process.exit(1);
}
console.log('\n>>> 全部通过');