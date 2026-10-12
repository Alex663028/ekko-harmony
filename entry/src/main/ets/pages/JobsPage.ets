/**
 * 定时任务页：按 cron 周期自动往会话里投一句提示词。
 * 对应原版 JobsView。
 *
 * 关键点：cron 只是表达式，不落 next_run_at 就永远不会被调度器捞到，
 * 所以保存时必须调 nextCronRun 算出下次时间一起写库。
 */

import { router, promptAction } from '@kit.ArkUI';
import { Job } from '../model/Extend';
import { JobRepo } from '../data/ExtendRepos';
import { newId } from '../data/Repos';
import { AppStore } from '../viewmodel/AppStore';
import { RemoteView } from '../viewmodel/RemoteView';
import {
  parseCron, cronPresets, cronPresetLabel, nextCronRun, relativeTime, previewOf
} from '../common/Core';
import {
  Card, SectionTitle, EmptyState, LabeledInput, PrimaryButton, SegmentedTabs
} from '../view/Common';
import { Tok } from '../view/Theme';

/** 预设的展示名：cronPresetLabel 只认固定 5 个，自定义的一律叫「自定义」 */
function presetName(expr: string): string {
  const label = cronPresetLabel(expr);
  return label.length > 0 ? label : expr;
}

@Entry
@Component
struct JobsPage {
  @StorageProp('themeDark') dark: boolean = false;
  @StorageLink('breakpoint') bp: string = 'compact';

  @State jobs: Job[] = [];
  @State now: number = Date.now();

  @State sheetOpen: boolean = false;
  @State isNew: boolean = true;
  @State fId: string = '';
  @State fName: string = '';
  @State fCron: string = '0 9 * * *';
  @State fPrompt: string = '';
  @State fEnabled: boolean = true;
  /** parseCron 的实时校验结果，合法时用它算下次运行 */
  @State cronError: string = '';
  @State cronValid: boolean = false;
  /** 缓存的下次运行时间（ms）。0 表示一年内无命中。 */
  @State cronNextAt: number = 0;
  /** 缓存的下次运行文案，避免在 build 里重算 nextCronRun */
  @State cronNextText: string = '';
  /** cron 合法但一年内不会触发 */
  @State cronNeverFires: boolean = false;

  aboutToAppear() {
    this.reload();
    this.timer = setInterval((): void => {
      this.now = Date.now();
    }, 30000);
  }

  aboutToDisappear() {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private timer: number = -1;

  private async reload(): Promise<void> {
    try {
      this.jobs = await RemoteView.jobs(AppStore.db());
    } catch (e) {
      this.jobs = [];
      promptAction.showToast({ message: `加载失败: ${(e as Error).message}` });
    }
  }

  // ───────── 表单 ─────────

  /** 每次改动 cron 都重算校验结果，error 直接显示在输入框下方 */
  private revalidateCron(): void {
    const p = parseCron(this.fCron);
    this.cronValid = p.valid;
    this.cronError = p.valid ? '' : p.error;

    // 下次运行时间必须在这里算一次并缓存。
    //
    // 反面教材：直接在 build() 里写
    //   Text(`下次 ${relativeTime(nextCronRun(parseCron(this.fCron), Date.now()), …)}`)
    // 而 nextCronRun 对「一年内无命中」的 cron（如 0 9 30 2 *，2 月 30 日）
    // 要逐分钟扫 527040 次。build 每次重渲染都跑一遍，
    // 输入框每敲一个字符就卡一次 → sheet 明显掉帧甚至假死。
    if (p.valid) {
      this.cronNextAt = nextCronRun(p, Date.now());
      this.cronNeverFires = this.cronNextAt <= 0;
      this.cronNextText = this.cronNeverFires
        ? '一年内不会触发，请检查日期/月份字段'
        : `下次 ${relativeTime(this.cronNextAt, Date.now())}`;
    } else {
      this.cronNextAt = 0;
      this.cronNeverFires = false;
      this.cronNextText = '';
    }
  }

  private openNew(): void {
    this.isNew = true;
    this.fId = newId(Date.now());
    this.fName = '';
    this.fCron = '0 9 * * *';
    this.fPrompt = '';
    this.fEnabled = true;
    this.revalidateCron();
    this.sheetOpen = true;
  }

  private openEdit(j: Job): void {
    this.isNew = false;
    this.fId = j.id;
    this.fName = j.name;
    this.fCron = j.cron;
    this.fPrompt = j.prompt;
    this.fEnabled = j.enabled;
    this.revalidateCron();
    this.sheetOpen = true;
  }

  private onCronChange(v: string): void {
    this.fCron = v;
    this.revalidateCron();
  }

  private applyPreset(expr: string): void {
    this.fCron = expr;
    this.revalidateCron();
  }

  private async save(): Promise<void> {
    if (this.fName.trim().length === 0) {
      promptAction.showToast({ message: '任务名不能为空' });
      return;
    }
    const parsed = parseCron(this.fCron);
    if (!parsed.valid) {
      this.revalidateCron();
      promptAction.showToast({ message: parsed.error });
      return;
    }
    const nowTs = Date.now();
    // 复用 revalidateCron 已经算好的值（输入变化时算过一次），
    // 这里再算一遍纯属浪费 —— 病态 cron 每次要扫 50 万次。
    const next = this.fEnabled ? (this.cronNextAt > 0 ? this.cronNextAt : nextCronRun(parsed, nowTs)) : 0;

    // cron 合法但一年内无命中（例如 0 9 30 2 * 指 2 月 30 日）——
    // 这种任务启用后永远不会执行，属于坏状态，直接拒绝而不是静默保存。
    if (this.fEnabled && next <= 0) {
      promptAction.showToast({ message: '该 cron 一年内不会触发，请检查日期/月份字段' });
      return;
    }

    // upsert 是 INSERT OR REPLACE（整行覆盖），
    // 所以编辑时必须显式带回旧的运行历史，否则「上次运行/状态/创建时间」会被清零。
    const prev = this.findJob(this.fId);
    const job: Job = {
      id: this.fId,
      name: this.fName.trim(),
      cron: this.fCron.trim(),
      sessionId: prev !== null ? prev.sessionId : '',
      roomId: prev !== null ? prev.roomId : '',
      agentId: prev !== null ? prev.agentId : '',
      prompt: this.fPrompt,
      enabled: this.fEnabled,
      lastRunAt: prev !== null ? prev.lastRunAt : 0,
      lastStatus: prev !== null ? prev.lastStatus : '',
      nextRunAt: next,
      createdAt: prev !== null ? prev.createdAt : nowTs
    };
    await JobRepo.upsert(AppStore.db(), job);
    this.sheetOpen = false;
    await this.reload();
    promptAction.showToast({ message: this.fEnabled ? '已保存' : '已保存（未启用）' });
  }

  /** 按 id 找当前列表里的任务；新建时返回 null */
  private findJob(id: string): Job | null {
    for (const j of this.jobs) {
      if (j.id === id) {
        return j;
      }
    }
    return null;
  }

  private async toggle(j: Job): Promise<void> {
    const job: Job = {
      id: j.id,
      name: j.name,
      cron: j.cron,
      sessionId: j.sessionId,
      roomId: j.roomId,
      agentId: j.agentId,
      prompt: j.prompt,
      enabled: !j.enabled,
      lastRunAt: j.lastRunAt,
      lastStatus: j.lastStatus,
      // 重新启用时必须重算下次运行，停用则清零让 due() 扫不到
      nextRunAt: !j.enabled ? nextCronRun(parseCron(j.cron), Date.now()) : 0,
      createdAt: j.createdAt
    };
    await JobRepo.upsert(AppStore.db(), job);
    await this.reload();
  }

  private async removeJob(j: Job): Promise<void> {
    const res = await promptAction.showDialog({
      title: '删除任务',
      message: `确定删除「${j.name}」？`,
      buttons: [{ text: '取消', color: '#61666E' }, { text: '删除', color: '#F53F3F' }]
    });
    if (res.index !== 1) {
      return;
    }
    await JobRepo.remove(AppStore.db(), j.id);
    await this.reload();
  }

  /** 手动标记一次执行结果，方便验证链路是否通 */
  private async markNow(j: Job, status: string): Promise<void> {
    await JobRepo.markRun(AppStore.db(), j.id, status, Date.now());
    const parsed = parseCron(j.cron);
    if (parsed.valid) {
      await JobRepo.setNextRun(AppStore.db(), j.id, nextCronRun(parsed, Date.now()));
    }
    await this.reload();
  }

  private statusColor(j: Job): string {
    if (j.lastStatus === 'ok') {
      return Tok.success;
    }
    if (j.lastStatus === 'failed') {
      return Tok.danger;
    }
    if (j.lastStatus === 'skipped') {
      return Tok.warn;
    }
    return Tok.text3(this.dark);
  }

  private statusText(j: Job): string {
    if (j.lastStatus.length === 0) {
      return '未运行';
    }
    return j.lastStatus;
  }

  private nextText(j: Job): string {
    if (!j.enabled) {
      return '已停用';
    }
    if (j.nextRunAt <= 0) {
      return '待调度';
    }
    return relativeTime(j.nextRunAt, this.now);
  }

  build() {
    Column() {
      // 顶栏
      Row({ space: 12 }) {
        Text('‹').fontSize(24).fontColor(Tok.text1(this.dark))
          .width(24)
          .onClick((): void => {
            router.back();
          })
        Text('定时任务')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.text1(this.dark))
          .layoutWeight(1)
        Text('＋').fontSize(22).fontColor(Tok.brand)
          .width(32)
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            this.openNew();
          })
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 10 })

      Scroll() {
        Column({ space: 10 }) {
          if (this.jobs.length === 0) {
            EmptyState({
              icon: '⏰',
              text: '还没有定时任务',
              hint: '让 Agent 在固定时间自动执行一句话，比如每天早上汇总昨日进展'
            })
          } else {
            SectionTitle({ text: `${this.jobs.length} 个任务`, trailing: this.bp })
            ForEach(this.jobs, (j: Job) => {
              Card({ pad: 12 }) {
                Column({ space: 8 }) {
                  Row({ space: 10 }) {
                    Column({ space: 3 }) {
                      Text(j.name)
                        .fontSize(15)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(Tok.text1(this.dark))
                      Text(`${cronPresetLabel(j.cron)} · ${j.cron}`)
                        .fontSize(11)
                        .fontColor(Tok.text3(this.dark))
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    Text(j.enabled ? '启用' : '停用')
                      .fontSize(11)
                      .fontColor(j.enabled ? Tok.success : Tok.text3(this.dark))
                      .padding({ left: 8, top: 4, bottom: 4 })
                      .onClick((): void => {
                        this.toggle(j);
                      })
                  }
                  .width('100%')

                  if (j.prompt.length > 0) {
                    Text(previewOf(j.prompt, 60))
                      .fontSize(12)
                      .fontColor(Tok.text2(this.dark))
                      .maxLines(2)
                      .width('100%')
                  }

                  Row({ space: 6 }) {
                    Text('下次')
                      .fontSize(11)
                      .fontColor(Tok.text3(this.dark))
                    Text(this.nextText(j))
                      .fontSize(11)
                      .fontColor(Tok.brand)
                    Text('·')
                      .fontSize(11)
                      .fontColor(Tok.text3(this.dark))
                    Text('上次')
                      .fontSize(11)
                      .fontColor(Tok.text3(this.dark))
                    Text(j.lastRunAt > 0 ? relativeTime(j.lastRunAt, this.now) : '—')
                      .fontSize(11)
                      .fontColor(Tok.text3(this.dark))
                    Blank()
                    Text(this.statusText(j))
                      .fontSize(11)
                      .fontColor(this.statusColor(j))
                  }
                  .width('100%')

                  Row({ space: 8 }) {
                    Button('编辑')
                      .layoutWeight(1)
                      .height(34)
                      .fontSize(13)
                      .fontColor(Tok.brand)
                      .backgroundColor(Tok.brandSoft)
                      .borderRadius(Tok.radiusSmall)
                      .onClick((): void => {
                        this.openEdit(j);
                      })
                    Button('跑一次')
                      .layoutWeight(1)
                      .height(34)
                      .fontSize(13)
                      .fontColor(Tok.success)
                      .backgroundColor(Color.Transparent)
                      .border({ width: 1, color: Tok.success })
                      .borderRadius(Tok.radiusSmall)
                      .onClick((): void => {
                        this.markNow(j, 'ok');
                      })
                    Button('删除')
                      .layoutWeight(1)
                      .height(34)
                      .fontSize(13)
                      .fontColor(Tok.danger)
                      .backgroundColor(Color.Transparent)
                      .border({ width: 1, color: Tok.danger })
                      .borderRadius(Tok.radiusSmall)
                      .onClick((): void => {
                        this.removeJob(j);
                      })
                  }
                  .width('100%')
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
              }
            }, (j: Job) => j.id)
          }
        }
        .width('100%')
        .padding({ left: Tok.pagePad, right: Tok.pagePad, bottom: 30 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tok.pageBg(this.dark))
    .bindSheet($$this.sheetOpen, this.jobEditor(), {
      height: SheetSize.LARGE,
      dragBar: true
    })
  }

  @Builder
  jobEditor() {
    Scroll() {
      Column({ space: 14 }) {
        SectionTitle({ text: this.isNew ? '新建任务' : '编辑任务' })

        LabeledInput({
          label: '任务名',
          placeholder: '如 每日晨报',
          value: this.fName,
          onChange: (v: string): void => {
            this.fName = v;
          }
        })

        Column({ space: 6 }) {
          Text('cron 表达式')
            .fontSize(12)
            .fontColor(Tok.text2(this.dark))
            .width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(cronPresets(), (expr: string) => {
              Text(presetName(expr))
                .fontSize(12)
                .fontColor(this.fCron === expr ? '#FFFFFF' : Tok.text2(this.dark))
                .backgroundColor(this.fCron === expr ? Tok.brand : Tok.cardBg(this.dark))
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .borderRadius(14)
                .margin({ right: 6, bottom: 6 })
                .onClick((): void => {
                  this.applyPreset(expr);
                })
            }, (expr: string) => expr)
          }
          .width('100%')
        }
        .width('100%')

        LabeledInput({
          label: '手动输入（分 时 日 月 周）',
          placeholder: '0 9 * * 1-5',
          value: this.fCron,
          onChange: (v: string): void => {
            this.onCronChange(v);
          }
        })

        if (this.cronError.length > 0) {
          Text(this.cronError)
            .fontSize(12)
            .fontColor(Tok.danger)
            .width('100%')
        } else if (this.cronValid) {
          // 直接用 revalidateCron 缓存的文案，不在渲染期重算 nextCronRun
          Text(`合法 · ${this.cronNextText}`)
            .fontSize(12)
            .fontColor(this.cronNeverFires ? Tok.warn : Tok.success)
            .width('100%')
        }

        LabeledInput({
          label: '提示词',
          placeholder: '到点后发给 Agent 的一句话',
          value: this.fPrompt,
          onChange: (v: string): void => {
            this.fPrompt = v;
          }
        })

        Row({ space: 10 }) {
          Button(this.fEnabled ? '已启用' : '已停用')
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontColor(this.fEnabled ? Tok.success : Tok.text3(this.dark))
            .backgroundColor(Color.Transparent)
            .border({ width: 1, color: this.fEnabled ? Tok.success : Tok.text3(this.dark) })
            .borderRadius(Tok.radiusSmall)
            .onClick((): void => {
              this.fEnabled = !this.fEnabled;
            })
          PrimaryButton({
            label: '保存',
            busy: false,
            onTap: (): void => {
              this.save();
            }
          })
        }
        .width('100%')
      }
      .width('100%')
      .padding(20)
    }
    .width('100%')
  }
}
