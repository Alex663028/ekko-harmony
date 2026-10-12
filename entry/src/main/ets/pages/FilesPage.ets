/**
 * 本地文件浏览与预览页。
 *
 * 沙箱约定（这一页最要紧的地方）：
 *  - **一切 IO 都限定在应用沙箱 `filesDir` 内**。目录状态用「相对沙箱根的相对路径」
 *    `relPath` 表示，绝对路径只在真正调用 fileIo 的那一行拼出来，
 *    且拼接前必须过 `isSafeRelativePath`，拼不出就当非法路径拒绝。
 *    这样「路径栏里手输 ../..」这类输入在数据层就被挡掉，不依赖 UI 不校验。
 *  - 文本预览只读前 200KB：ArkUI 的 Text 渲染大字符串会明显掉帧，
 *    一个几十 MB 的日志文件足以让页面看起来卡死。
 *
 * 读文件的方式刻意用 `openSync + readSync + closeSync` 而不是 `readTextSync`：
 * 后者会把整个文件读进内存，没法限制长度。
 */

import { router, promptAction } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { Attachment, Breakpoint } from '../model/Extend';
import { AttachmentRepo } from '../data/ExtendRepos';
import { AppStore } from '../viewmodel/AppStore';
import {
  fileExt, baseName, dirName, isSafeRelativePath, guessMime, humanSize,
  previewOf, relativeTime
} from '../common/Core';
import {
  MdText, EmptyState, Card, SectionTitle, PrimaryButton, GhostButton,
  LabeledInput, SegmentedTabs, CodeBlock
} from '../view/Common';
import { AdaptiveGrid } from '../view/Responsive';
import { Tok } from '../view/Theme';

/** 文本预览上限：只读前 200KB */
const TEXT_PREVIEW_LIMIT: number = 200 * 1024;

/** 沙箱根，相对路径用它表示（'' 即 filesDir 本身） */
const ROOT_REL: string = '';

/** 目录列表单次最多渲染多少项，超出给提示而不是把内存吃光 */
const MAX_ENTRIES: number = 300;

// ───────────────────────── 路由参数 ─────────────────────────

interface FilesRouteParams {
  sessionId: string;
  roomId: string;
}

// ───────────────────────── 本地模型 ─────────────────────────

/** 预览类型。用具名类型而不是到处比字符串，避免拼错。 */
type PreviewKind = 'none' | 'image' | 'text' | 'unsupported';

interface FsEntry {
  /** 文件名（不含目录） */
  name: string;
  /** 相对沙箱根的路径，绝对路径由 root + '/' + rel 现场拼 */
  rel: string;
  isDir: boolean;
  bytes: number;
  mtimeMs: number;
  /** 扩展名，含点，小写 */
  ext: string;
  mime: string;
}

function newFsEntry(): FsEntry {
  return {
    name: '',
    rel: '',
    isDir: false,
    bytes: 0,
    mtimeMs: 0,
    ext: '',
    mime: ''
  };
}

// ───────────────────────── 具名工厂 / 纯函数 ─────────────────────────

/** 预览类型 → 中文标题 */
function previewTitle(kind: PreviewKind): string {
  if (kind === 'image') {
    return '图片预览';
  }
  if (kind === 'text') {
    return '文本预览';
  }
  if (kind === 'unsupported') {
    return '不支持预览';
  }
  return '预览';
}

/** 能否当文本读。SVG 虽是 image/* 但本质是 XML，交给文本分支更实用。 */
function isTextual(mime: string, ext: string): boolean {
  if (ext === '.svg') {
    return true;
  }
  if (mime.length === 0) {
    return false;
  }
  if (mime === 'application/json') {
    return true;
  }
  return mime.startsWith('text/');
}

/** 是否代码类扩展名 —— 决定用 CodeBlock 还是 MdText 渲染 */
function isCodeExt(ext: string): boolean {
  return ext === '.json' || ext === '.jsonc' || ext === '.ets' || ext === '.ts' ||
    ext === '.js' || ext === '.py' || ext === '.sh' || ext === '.yaml' ||
    ext === '.yml' || ext === '.toml' || ext === '.sql' || ext === '.xml' ||
    ext === '.html' || ext === '.css' || ext === '.csv' || ext === '.log' ||
    ext === '.ini' || ext === '.conf';
}

/** 异常 → 文案。统一在这里转一次，页面里就不用到处 (e as Error) */
function errText(e: Error, fallback: string): string {
  return e !== null && e.message.length > 0 ? e.message : fallback;
}

/**
 * 拼接「沙箱根 + 相对路径」，并做沙箱安全校验。
 *
 * 这是本页唯一的路径出口：任何要交给 fileIo 的路径都必须过这里。
 * 返回空串表示非法（逃出沙箱 / 含空字符 / 相对路径本身不合法）。
 */
function safeJoin(root: string, rel: string): string {
  if (rel === ROOT_REL) {
    return root;
  }
  if (!isSafeRelativePath(rel)) {
    return '';
  }
  return `${root}/${rel}`;
}

/** 由绝对路径反推相对路径；失败返回 null（说明它本来就不在沙箱里） */
function relOf(root: string, abs: string): string | null {
  if (abs === root) {
    return ROOT_REL;
  }
  if (!abs.startsWith(`${root}/`)) {
    return null;
  }
  const rel = abs.slice(root.length + 1);
  return isSafeRelativePath(rel) ? rel : null;
}

/** 类型图标：按 MIME 粗分类，不追求覆盖所有类型 */
function iconOf(isDir: boolean, mime: string, ext: string): string {
  if (isDir) {
    return '📁';
  }
  if (mime.startsWith('image/')) {
    return '🖼';
  }
  if (mime.startsWith('video/')) {
    return '🎬';
  }
  if (mime.startsWith('audio/')) {
    return '🎵';
  }
  if (mime === 'application/pdf') {
    return '📕';
  }
  if (mime === 'application/json') {
    return '🧾';
  }
  if (mime.startsWith('text/') || ext === '.md') {
    return '📄';
  }
  return '📦';
}

/** 文件类型描述，放在预览头部 */
function typeLabel(entry: FsEntry): string {
  const e = entry.ext.length > 0 ? entry.ext : '无扩展名';
  return `${e} · ${entry.mime}`;
}

@Entry
@Component
struct FilesPage {
  @StorageProp('themeDark') dark: boolean = false;
  @StorageLink('breakpoint') bp: string = 'compact';

  /** 沙箱根，绝对路径，只在拼 fileIo 参数时用 */
  private root: string = '';
  /** 路由带来的会话 / 群聊 id，用于列附件 */
  @State sessionId: string = '';
  @State roomId: string = '';

  @State ready: boolean = false;
  /** 当前目录，相对沙箱根 */
  @State rel: string = ROOT_REL;
  @State entries: FsEntry[] = [];
  @State loading: boolean = false;
  @State loadError: string = '';
  @State truncated: boolean = false;

  // 预览
  @State previewOpen: boolean = false;
  @State previewKind: PreviewKind = 'none';
  @State previewEntry: FsEntry = newFsEntry();
  @State previewText: string = '';
  @State previewCut: boolean = false;
  @State previewErr: string = '';

  // 新建文件
  @State newOpen: boolean = false;
  @State newName: string = '';

  // 附件
  @State attachments: Attachment[] = [];
  @State attachErr: string = '';

  aboutToAppear() {
    this.initRoot();
    this.readParams();
    this.loadDir(ROOT_REL);
    this.loadAttachments();
  }

  // ───────── 初始化 ─────────

  /**
   * 拿沙箱根。
   * SDK 的 fileIo 里**没有** getFilesDirSync（已核对 @ohos.file.fs.d.ts 的
   * namespace fileIo 导出清单），只有 AbilityContext.filesDir，所以走 getContext。
   */
  private initRoot(): void {
    try {
      const ctx = getContext(this);
      this.root = ctx.filesDir;
      this.ready = this.root.length > 0;
      if (!this.ready) {
        this.loadError = '拿不到应用沙箱目录，本页无法访问本地文件';
      }
    } catch (e) {
      this.ready = false;
      this.loadError = `初始化失败：${errText(e as Error, '未知错误')}`;
    }
  }

  private readParams(): void {
    try {
      const p = router.getParams() as FilesRouteParams;
      this.sessionId = p !== null && p !== undefined ? (p.sessionId ?? '') : '';
      this.roomId = p !== null && p !== undefined ? (p.roomId ?? '') : '';
    } catch (e) {
      // 没有传参进来是正常情况（从设置页直接进），不算错误
      this.sessionId = '';
      this.roomId = '';
    }
  }

  private gridBp(): Breakpoint {
    if (this.bp === 'expanded') {
      return 'expanded';
    }
    if (this.bp === 'medium') {
      return 'medium';
    }
    return 'compact';
  }

  private isWide(): boolean {
    return this.bp === 'expanded';
  }

  /** 当前目录绝对路径（已过安全校验） */
  private absOf(rel: string): string {
    return safeJoin(this.root, rel);
  }

  // ───────── 目录列举 ─────────

  private async loadDir(rel: string): Promise<void> {
    if (!this.ready) {
      return;
    }
    const abs = this.absOf(rel);
    if (abs.length === 0) {
      this.loadError = '路径不合法，已拒绝访问';
      this.entries = [];
      return;
    }
    this.loading = true;
    this.loadError = '';
    // truncated 必须一起复位：它是「粘滞」状态，
    // 进过一次 >300 项的目录后再进小目录，标题会一直错报「只显示前 300 项」，
    // 用户会以为文件丢了。
    this.truncated = false;
    try {
      // listFileSync 只返回名字，拿大小/时间要逐个 statSync
      const names: string[] = fileIo.listFileSync(abs);
      const list: FsEntry[] = [];
      for (const name of names) {
        if (list.length >= MAX_ENTRIES) {
          this.truncated = true;
          break;
        }
        // 目录项直接拼；跳过上层（.）与隐藏目录，避免树里出现自指
        if (name === '.' || name === '..') {
          continue;
        }
        const childRel = rel === ROOT_REL ? name : `${rel}/${name}`;
        if (!isSafeRelativePath(childRel)) {
          continue;
        }
        const childAbs = this.absOf(childRel);
        if (childAbs.length === 0) {
          continue;
        }
        const item = newFsEntry();
        item.name = name;
        item.rel = childRel;
        item.ext = fileExt(name);
        item.mime = guessMime(item.ext);
        try {
          const st = fileIo.statSync(childAbs);
          item.isDir = st.isDirectory();
          item.bytes = item.isDir ? 0 : st.size;
          item.mtimeMs = st.mtime;
        } catch (e) {
          // 单个 stat 失败（权限/竞态删除）不该让整个目录都打不开
          item.isDir = false;
          item.bytes = 0;
          item.mtimeMs = 0;
        }
        list.push(item);
      }
      sortEntries(list);
      // ArkUI 只在整体重新赋值时刷新数组
      this.entries = list;
      this.rel = rel;
    } catch (e) {
      this.entries = [];
      // 13900002 = 文件不存在；13900001 = 无权限
      this.loadError = `打不开目录：${errText(e as Error, '未知错误')}`;
    }
    this.loading = false;
  }

  private goUp(): void {
    if (this.rel === ROOT_REL) {
      promptAction.showToast({ message: '已经在沙箱根目录' });
      return;
    }
    const parent = dirName(this.rel);
    this.loadDir(parent.length > 0 ? parent : ROOT_REL);
  }

  private goRoot(): void {
    this.loadDir(ROOT_REL);
  }

  /** 进入目录 / 打开文件 */
  private onEntryTap(e: FsEntry): void {
    if (e.isDir) {
      this.loadDir(e.rel);
      return;
    }
    this.openPreview(e);
  }

  // ───────── 预览 ─────────

  private openPreview(e: FsEntry): void {
    this.previewEntry = e;
    this.previewText = '';
    this.previewCut = false;
    this.previewErr = '';
    if (isTextual(e.mime, e.ext)) {
      this.previewKind = 'text';
    } else if (e.mime.startsWith('image/')) {
      // 图片交给 Image(path) 渲染，不手动读二进制
      this.previewKind = 'image';
    } else {
      this.previewKind = 'unsupported';
    }
    this.previewOpen = true;
    if (this.previewKind === 'text') {
      this.readTextHead(e);
    }
  }

  /** 只读前 TEXT_PREVIEW_LIMIT 字节，避免大文件卡死 */
  private readTextHead(e: FsEntry): void {
    const abs = this.absOf(e.rel);
    if (abs.length === 0) {
      this.previewErr = '路径不合法，已拒绝读取';
      return;
    }
    try {
      const want = e.bytes > TEXT_PREVIEW_LIMIT ? TEXT_PREVIEW_LIMIT : e.bytes;
      const buf = new ArrayBuffer(want > 0 ? want : 1);
      // openSync 返回的 File 只暴露 fd，read/close 要走 fileIo 上的模块函数
      const f = fileIo.openSync(abs, fileIo.OpenMode.READ_ONLY);
      let read: number = 0;
      try {
        read = fileIo.readSync(f.fd, buf, { offset: 0, length: buf.byteLength });
      } finally {
        fileIo.closeSync(f.fd);
      }
      if (read <= 0) {
        this.previewText = '（空文件）';
        this.previewCut = e.bytes > 0;
        return;
      }
      // 只解码实际读到的长度，否则尾部残留的 0 字节会变成大量 NUL 字符
      this.previewText = utf8Decode(new Uint8Array(buf).slice(0, read));
      this.previewCut = e.bytes > read;
    } catch (e) {
      this.previewText = '';
      this.previewErr = `读取失败：${errText(e as Error, '未知错误')}`;
    }
  }

  // ───────── 删除 / 新建 ─────────

  private async removeEntry(e: FsEntry): Promise<void> {
    if (e.isDir) {
      promptAction.showToast({ message: '目录暂不支持删除，避免误删整棵子树' });
      return;
    }
    const res = await promptAction.showDialog({
      title: '删除文件',
      message: `确定删除「${e.name}」？此操作不可恢复。`,
      buttons: [{ text: '取消', color: '#61666E' }, { text: '删除', color: '#F53F3F' }]
    });
    if (res.index !== 1) {
      return;
    }
    const abs = this.absOf(e.rel);
    if (abs.length === 0) {
      promptAction.showToast({ message: '路径不合法，已拒绝删除' });
      return;
    }
    try {
      fileIo.unlinkSync(abs);
      this.previewOpen = false;
      await this.loadDir(this.rel);
      promptAction.showToast({ message: '已删除' });
    } catch (e) {
      promptAction.showToast({ message: `删除失败：${errText(e as Error, '未知错误')}` });
    }
  }

  private openNew(): void {
    this.newName = '';
    this.newOpen = true;
  }

  private async createFile(): Promise<void> {
    const name = this.newName.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: '文件名不能为空' });
      return;
    }
    // 用户输入的单个文件名同样要过沙箱校验：'a/b' 这类带分隔符的会被拦掉
    if (!isSafeRelativePath(name) || name.indexOf('/') >= 0 || name.indexOf('\\') >= 0) {
      promptAction.showToast({ message: '文件名不合法，不能包含路径分隔符' });
      return;
    }
    const rel = this.rel === ROOT_REL ? name : `${this.rel}/${name}`;
    const abs = this.absOf(rel);
    if (abs.length === 0) {
      promptAction.showToast({ message: '路径不合法，已拒绝创建' });
      return;
    }
    try {
      // 新建一个空文件：CREATE 配 TRUNC，文件已存在也不报错
      const f = fileIo.openSync(
        abs,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
      fileIo.closeSync(f.fd);
      this.newOpen = false;
      await this.loadDir(this.rel);
      promptAction.showToast({ message: `已创建 ${name}` });
    } catch (e) {
      promptAction.showToast({ message: `创建失败：${errText(e as Error, '未知错误')}` });
    }
  }

  // ───────── 会话附件 ─────────

  private async loadAttachments(): Promise<void> {
    if (this.sessionId.length === 0) {
      this.attachErr = '未传入会话 id';
      return;
    }
    try {
      this.attachments = await AttachmentRepo.bySession(AppStore.db(), this.sessionId);
      this.attachErr = '';
    } catch (e) {
      this.attachments = [];
      this.attachErr = `附件读取失败：${errText(e as Error, '未知错误')}`;
    }
  }

  /** 点附件：把它的绝对路径换算成沙箱相对路径，落在沙箱外的直接拒绝 */
  private openAttachment(a: Attachment): void {
    const rel = relOf(this.root, a.path);
    if (rel === null) {
      promptAction.showToast({ message: '该附件不在沙箱内，出于安全考虑不予打开' });
      return;
    }
    const item = newFsEntry();
    item.name = a.name.length > 0 ? a.name : baseName(a.path);
    item.rel = rel;
    item.ext = fileExt(item.name);
    item.mime = a.mediaType.length > 0 ? a.mediaType : guessMime(item.ext);
    item.bytes = a.size;
    item.mtimeMs = a.createdAt;
    this.openPreview(item);
  }

  private async removeAttachment(a: Attachment): Promise<void> {
    const res = await promptAction.showDialog({
      title: '删除附件记录',
      message: `只从附件列表移除「${a.name}」，不会删除磁盘文件。`,
      buttons: [{ text: '取消', color: '#61666E' }, { text: '移除', color: '#F53F3F' }]
    });
    if (res.index !== 1) {
      return;
    }
    try {
      await AttachmentRepo.remove(AppStore.db(), a.id);
      await this.loadAttachments();
      promptAction.showToast({ message: '已移除' });
    } catch (e) {
      promptAction.showToast({ message: `移除失败：${errText(e as Error, '未知错误')}` });
    }
  }

  // ───────── 布局 ─────────

  build() {
    Column() {
      this.topBar()

      if (!this.ready) {
        EmptyState({ icon: '⚠', text: '文件浏览不可用', hint: this.loadError })
        Blank()
      } else {
        if (this.isWide()) {
          // PC：左目录树 + 右文件列表
          Row() {
            Column() {
              this.dirTree()
            }
            .width(260)
            .height('100%')

            Column() {
              this.pathBar()
              this.filePane()
            }
            .layoutWeight(1)
            .height('100%')
          }
          .width('100%')
          .layoutWeight(1)
        } else {
          // compact / medium：单栏，目录树折叠成一行面包屑
          this.pathBar()
          Scroll() {
            Column() {
              this.fileList()
              this.attachmentSection()
              Blank()
            }
            .width('100%')
            .padding({ left: Tok.pagePad, right: Tok.pagePad, bottom: 30 })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          // P1-17 同形修复：一个组件节点只能挂一个 bindSheet。原本两个 sheet
          // 都挂在根 Column 上，后者覆盖前者 —— 前者对应的入口点了没反应。
          // 拆到两个宿主节点：本 sheet 挂 Scroll，另一个 sheet 挂根 Column。
          .bindSheet($$this.previewOpen, this.previewSheet(), {
            height: SheetSize.LARGE,
            dragBar: true
          })
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tok.pageBg(this.dark))
    .bindSheet($$this.newOpen, this.newFileSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true
    })
  }

  @Builder
  topBar() {
    Row({ space: 12 }) {
      Text('‹').fontSize(24).fontColor(Tok.text1(this.dark))
        .width(24)
        .onClick((): void => {
          router.back();
        })
      Text('本地文件')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tok.text1(this.dark))
        .layoutWeight(1)
      Text('刷新').fontSize(14).fontColor(Tok.brand)
        .padding({ left: 6, right: 4 })
        .onClick((): void => {
          this.loadDir(this.rel);
        })
      Text('＋新建').fontSize(14).fontColor(Tok.brand)
        .padding({ left: 6, right: 4 })
        .onClick((): void => {
          this.openNew();
        })
    }
    .width('100%')
    .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 8 })
  }

  /** 路径栏：根 / 当前路径 + 返回上级 */
  @Builder
  pathBar() {
    Row({ space: 8 }) {
      Text('‹ 上级')
        .fontSize(13)
        .fontColor(this.rel === ROOT_REL ? Tok.text3(this.dark) : Tok.brand)
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .backgroundColor(Tok.fieldBg(this.dark))
        .borderRadius(Tok.radiusSmall)
        .onClick((): void => {
          this.goUp();
        })

      Text(this.rel === ROOT_REL ? '沙箱根目录' : this.rel)
        .fontSize(12)
        .fontColor(Tok.text2(this.dark))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(`${this.entries.length} 项`)
        .fontSize(11)
        .fontColor(Tok.text3(this.dark))
    }
    .width('100%')
    .padding({ left: Tok.pagePad, right: Tok.pagePad, bottom: 8 })
  }

  /**
   * compact 单栏用的文件列表。
   *
   * 与宽屏的 AdaptiveGrid 不同：窄屏一行一个就够，套 9 格栅格反而把
   * 每项压得很矮、看起来像卡片流。这里直接用紧凑行式，扫起来更快。
   */
  @Builder
  fileList() {
    if (this.loading) {
      Text('读取中…')
        .fontSize(12)
        .fontColor(Tok.text3(this.dark))
        .width('100%')
    }

    if (this.loadError.length > 0) {
      Card({ pad: 12 }) {
        Row({ space: 8 }) {
          Text('⚠').fontSize(16).fontColor(Tok.danger)
          Text(this.loadError)
            .fontSize(12)
            .fontColor(Tok.text2(this.dark))
            .layoutWeight(1)
        }
        .width('100%')
      }
    }

    if (this.entries.length === 0 && !this.loading && this.loadError.length === 0) {
      EmptyState({ icon: '📂', text: '这个目录是空的', hint: '点右上角「＋新建」放个文件进来' })
    } else if (this.entries.length > 0) {
      SectionTitle({
        text: this.rel === ROOT_REL ? '沙箱根目录' : baseName(this.rel),
        trailing: this.truncated ? `只显示前 ${MAX_ENTRIES} 项` : `${this.entries.length} 项`
      })
      ForEach(this.entries, (e: FsEntry) => {
        this.entryRow(e)
      }, (e: FsEntry) => e.rel)
    }
  }

  /** 窄屏的一行：图标 + 名称 + 大小/时间，整行点击进入或预览 */
  @Builder
  entryRow(e: FsEntry) {
    Row({ space: 10 }) {
      Text(iconOf(e.isDir, e.mime, e.ext))
        .fontSize(18)
      Column({ space: 2 }) {
        Text(e.name)
          .fontSize(14)
          .fontColor(Tok.text1(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(e.isDir ? '目录' : `${humanSize(e.bytes)} · ${e.mtimeMs > 0 ?
          relativeTime(e.mtimeMs, Date.now()) : '时间未知'}`)
          .fontSize(11)
          .fontColor(Tok.text3(this.dark))
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(e.isDir ? '›' : '预览')
        .fontSize(12)
        .fontColor(Tok.brand)
        .padding({ left: 6, top: 4, bottom: 4 })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: Tok.cardPad, right: Tok.cardPad })
    .backgroundColor(Tok.cardBg(this.dark))
    .borderRadius(Tok.radius)
    .border({ width: 1, color: Tok.line(this.dark) })
    .onClick((): void => {
      this.onEntryTap(e);
    })
  }

  /** PC 左栏：面包屑树 + 当前目录的子目录 */
  @Builder
  dirTree() {
    Column() {
      Text('目录')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tok.text3(this.dark))
        .width('100%')
        .padding({ left: Tok.pagePad, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 2 }) {
          this.crumbRow('沙箱根', ROOT_REL, 0)
          ForEach(this.subDirEntries(), (e: FsEntry) => {
            this.dirNode(e, 1)
          }, (e: FsEntry) => `sub-${e.rel}`)

          SectionTitle({ text: '附件', trailing: `${this.attachments.length}` })
          this.attachSummary()
          Blank()
        }
        .width('100%')
        .padding({ left: 10, right: 10, bottom: 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Tok.cardBg(this.dark))
  }

  @Builder
  crumbRow(label: string, rel: string, depth: number) {
    Row({ space: 6 }) {
      Text(depth === 0 ? '🗂' : '📁')
        .fontSize(13)
      Text(label)
        .fontSize(13)
        .fontWeight(this.rel === rel ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.rel === rel ? Tok.brand : Tok.text1(this.dark))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 7, bottom: 7, left: 4, right: 6 })
    .borderRadius(Tok.radiusSmall)
    .backgroundColor(this.rel === rel ? Tok.brandSoft : Color.Transparent)
    .onClick((): void => {
      this.loadDir(rel);
    })
  }

  /** 当前目录下的子目录；当前在根时就显示根的子目录 */
  @Builder
  dirNode(e: FsEntry, depth: number) {
    Column() {
      this.crumbRow(e.name, e.rel, depth)
    }
    .width('100%')
  }

  @Builder
  attachSummary() {
    if (this.attachments.length === 0) {
      Text(this.attachErr.length > 0 ? this.attachErr : '当前会话没有附件')
        .fontSize(11)
        .fontColor(Tok.text3(this.dark))
        .width('100%')
        .padding({ left: 6, top: 4, bottom: 4 })
    } else {
      Column({ space: 2 }) {
        ForEach(this.attachments, (a: Attachment) => {
          Row({ space: 6 }) {
            Text('📎').fontSize(12)
            Text(a.name.length > 0 ? a.name : '未命名附件')
              .fontSize(12)
              .fontColor(Tok.text2(this.dark))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6, left: 6, right: 4 })
          .borderRadius(Tok.radiusSmall)
          .onClick((): void => {
            this.openAttachment(a);
          })
        }, (a: Attachment) => a.id)
      }
      .width('100%')
    }
  }

  /** 右栏：文件列表 + 附件。PC 宽屏用栅格，窄屏单列。 */
  @Builder
  filePane() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.loading) {
          Text('读取中…')
            .fontSize(12)
            .fontColor(Tok.text3(this.dark))
            .width('100%')
        }

        if (this.loadError.length > 0) {
          Card({ pad: 12 }) {
            Row({ space: 8 }) {
              Text('⚠').fontSize(16).fontColor(Tok.danger)
              Text(this.loadError)
                .fontSize(12)
                .fontColor(Tok.text2(this.dark))
                .layoutWeight(1)
            }
            .width('100%')
          }
        }

        if (this.entries.length === 0 && !this.loading && this.loadError.length === 0) {
          EmptyState({ icon: '📂', text: '这个目录是空的', hint: '点右上角「＋新建」放个文件进来' })
        } else {
          SectionTitle({
            text: this.rel === ROOT_REL ? '沙箱根目录' : baseName(this.rel),
            trailing: this.truncated ? `只显示前 ${MAX_ENTRIES} 项` : `${this.entries.length} 项`
          })
          AdaptiveGrid({
            count: this.entries.length,
            bp: this.gridBp(),
            items: (i: number): void => {
              this.entryAt(i);
            }
          })
        }

        this.attachmentSection()
        Blank()
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, bottom: 30 })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  /** AdaptiveGrid 固定 9 格，超出留空 */
  @Builder
  entryAt(i: number) {
    if (i < this.entries.length) {
      this.entryCard(this.entries[i])
    } else {
      Blank()
    }
  }

  @Builder
  entryCard(e: FsEntry) {
    Card({ pad: 10 }) {
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(iconOf(e.isDir, e.mime, e.ext)).fontSize(18)
          Column({ space: 2 }) {
            Text(e.name)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tok.text1(this.dark))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(e.isDir ? '目录' : `${humanSize(e.bytes)} · ${e.mtimeMs > 0 ?
              relativeTime(e.mtimeMs, Date.now()) : '时间未知'}`)
              .fontSize(11)
              .fontColor(Tok.text3(this.dark))
              .maxLines(1)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')

        Row({ space: 6 }) {
          Button(e.isDir ? '进入' : '预览')
            .layoutWeight(1)
            .height(30)
            .fontSize(12)
            .fontColor(Tok.brand)
            .backgroundColor(Tok.brandSoft)
            .borderRadius(Tok.radiusSmall)
            .onClick((): void => {
              this.onEntryTap(e);
            })
          if (!e.isDir) {
            Button('删除')
              .layoutWeight(1)
              .height(30)
              .fontSize(12)
              .fontColor(Tok.danger)
              .backgroundColor(Color.Transparent)
              .border({ width: 1, color: Tok.danger })
              .borderRadius(Tok.radiusSmall)
              .onClick((): void => {
                this.removeEntry(e);
              })
          }
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 会话附件区。单栏布局下直接跟在文件列表后面。 */
  @Builder
  attachmentSection() {
    Column({ space: 8 }) {
      SectionTitle({ text: '会话附件', trailing: `${this.attachments.length}` })

      if (this.attachErr.length > 0) {
        Text(this.attachErr)
          .fontSize(12)
          .fontColor(Tok.text3(this.dark))
          .width('100%')
      } else if (this.attachments.length === 0) {
        Text('当前会话没有附件记录。从聊天里发出的图片/文件会列在这里。')
          .fontSize(12)
          .fontColor(Tok.text3(this.dark))
          .width('100%')
      } else {
        ForEach(this.attachments, (a: Attachment) => {
          Card({ pad: 10 }) {
            Row({ space: 10 }) {
              Text('📎').fontSize(18)
              Column({ space: 3 }) {
                Text(a.name)
                  .fontSize(14)
                  .fontColor(Tok.text1(this.dark))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${a.mediaType.length > 0 ? a.mediaType : guessMime(fileExt(a.name))} · ` +
                  `${humanSize(a.size)} · ${relativeTime(a.createdAt, Date.now())}`)
                  .fontSize(11)
                  .fontColor(Tok.text3(this.dark))
                  .maxLines(1)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text('打开').fontSize(12).fontColor(Tok.brand)
                .padding({ left: 6, top: 4, bottom: 4 })
                .onClick((): void => {
                  this.openAttachment(a);
                })
              Text('移除').fontSize(12).fontColor(Tok.danger)
                .padding({ left: 6, top: 4, bottom: 4 })
                .onClick((): void => {
                  this.removeAttachment(a);
                })
            }
            .width('100%')
          }
        }, (a: Attachment) => a.id)
      }
    }
    .width('100%')
  }

  // ───────── Sheet ─────────

  @Builder
  previewSheet() {
    Scroll() {
      Column({ space: 14 }) {
        Row({ space: 10 }) {
          Text(iconOf(false, this.previewEntry.mime, this.previewEntry.ext)).fontSize(20)
          Column({ space: 3 }) {
            Text(this.previewEntry.name)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tok.text1(this.dark))
              .width('100%')
            Text(typeLabel(this.previewEntry))
              .fontSize(11)
              .fontColor(Tok.text3(this.dark))
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')

        if (this.previewKind === 'image') {
          Image(this.absOf(this.previewEntry.rel))
            .width('100%')
            .height(320)
            .objectFit(ImageFit.Contain)
            .backgroundColor(Tok.fieldBg(this.dark))
            .borderRadius(Tok.radiusSmall)
        } else if (this.previewKind === 'text') {
          if (this.previewErr.length > 0) {
            Text(this.previewErr)
              .fontSize(12)
              .fontColor(Tok.danger)
              .width('100%')
          } else {
            if (isCodeExt(this.previewEntry.ext)) {
              CodeBlock({
                body: this.previewText,
                lang: this.previewEntry.ext,
                dark: this.dark
              })
            } else {
              MdText({ source: this.previewText, fontSize: 13 })
            }
          }
        } else if (this.previewKind === 'unsupported') {
          Column({ space: 8 }) {
            Text('不支持预览')
              .fontSize(15)
              .fontColor(Tok.text2(this.dark))
              .width('100%')
            Text(`该文件类型为 ${this.previewEntry.mime}，本应用只内置了图片与文本的渲染能力。` +
              '可复制文件到系统相册/文件管理器后用其他应用打开。')
              .fontSize(12)
              .fontColor(Tok.text3(this.dark))
              .width('100%')
            Text('文件路径')
              .fontSize(11)
              .fontColor(Tok.text3(this.dark))
              .width('100%')
            CodeBlock({
              body: this.absOf(this.previewEntry.rel),
              lang: 'path',
              dark: this.dark
            })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        Row({ space: 8 }) {
          Button('复制路径')
            .layoutWeight(1)
            .height(40)
            .fontSize(13)
            .fontColor(Tok.text2(this.dark))
            .backgroundColor(Tok.fieldBg(this.dark))
            .borderRadius(Tok.radiusSmall)
            .onClick((): void => {
              promptAction.showToast({ message: previewOf(this.absOf(this.previewEntry.rel), 60) });
            })
          PrimaryButton({
            label: '关闭',
            busy: false,
            onTap: (): void => {
              this.previewOpen = false;
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

  @Builder
  newFileSheet() {
    Column({ space: 14 }) {
      SectionTitle({ text: '新建文本文件' })

      LabeledInput({
        label: '文件名',
        placeholder: 'notes.md',
        value: this.newName,
        onChange: (v: string): void => {
          this.newName = v;
        }
      })

      Text(`将创建在：${this.rel === ROOT_REL ? '沙箱根目录' : this.rel}`)
        .fontSize(11)
        .fontColor(Tok.text3(this.dark))
        .width('100%')

      Text('文件名不能包含路径分隔符，也不能超出沙箱目录。创建后点开即可用文本预览查看。')
        .fontSize(11)
        .fontColor(Tok.text3(this.dark))
        .width('100%')

      Row({ space: 8 }) {
        GhostButton({
          label: '取消',
          onTap: (): void => {
            this.newOpen = false;
          }
        })
        PrimaryButton({
          label: '创建',
          busy: false,
          onTap: (): void => {
            this.createFile();
          }
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding(20)
  }

  /** 当前目录下的子目录列表（PC 左栏用） */
  private subDirEntries(): FsEntry[] {
    const out: FsEntry[] = [];
    for (const e of this.entries) {
      if (e.isDir) {
        out.push(e);
      }
    }
    return out;
  }
}

/** 目录优先，同类按名称自然序 */
function sortEntries(list: FsEntry[]): void {
  list.sort((a: FsEntry, b: FsEntry): number => {
    if (a.isDir !== b.isDir) {
      return a.isDir ? -1 : 1;
    }
    return a.name.localeCompare(b.name);
  });
}

/** UTF-8 解码（ArkTS 侧不引 Core 的实现，避免页面与纯逻辑层耦合） */
function utf8Decode(bytes: Uint8Array): string {
  let out = '';
  let i = 0;
  while (i < bytes.length) {
    const b0 = bytes[i];
    let cp = b0;
    let extra = 0;
    if (b0 < 0x80) {
      extra = 0;
    } else if ((b0 & 0xe0) === 0xc0) {
      cp = b0 & 0x1f;
      extra = 1;
    } else if ((b0 & 0xf0) === 0xe0) {
      cp = b0 & 0x0f;
      extra = 2;
    } else if ((b0 & 0xf8) === 0xf0) {
      cp = b0 & 0x07;
      extra = 3;
    } else {
      // 非法首字节，跳过避免死循环
      i++;
      out += '�';
      continue;
    }
    i++;
    for (let k = 0; k < extra && i < bytes.length; k++, i++) {
      cp = (cp << 6) | (bytes[i] & 0x3f);
    }
    out += String.fromCodePoint(cp);
  }
  return out;
}
