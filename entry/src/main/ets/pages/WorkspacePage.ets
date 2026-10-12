/**
 * 电脑工作区页：浏览并预览**电脑上**的工作区文件。
 *
 * ## 为什么单独一页（部署形态决定）
 *
 * 老板的用法是「**台式机跑服务端 + 手机远程控制**」。Agent 干活的工作区在 PC 上，
 * 手机端要看「Agent 到底改了哪些文件」，就必须读 PC 的磁盘 ——
 * 现有的 FilesPage 是**手机沙箱**浏览（filesDir 内），两者完全不同的数据源。
 *
 * ⚠ 安全约定（和 FilesPage 一致的原则）：
 *  - path 一律是**相对 PC 工作区根**的，不传绝对路径。
 *    服务端的 workspace 根由它自己管，手机端只发相对路径，
 *    这样即使手机端有 bug 也读不到工作区外。
 *  - 文本预览只读前 200KB：ArkUI 的 Text 渲染大字符串会掉帧，
 *    一个几十 MB 的日志足以让页面看起来卡死。
 *
 * ⚠ 已知限制：目前只做了「读文件夹 + 读文件」。
 *   服务端有 /api/studio/files/write，但**故意不在手机端暴露** ——
 *   手机上误触一次就可能覆盖 PC 上的工作文件，风险不对称。
 *   要写文件请去电脑上。
 */

import { router, promptAction } from '@kit.ArkUI';
import { StudioApi, RemoteFolder } from '../net/StudioApi';
import { NetConfig } from '../net/Http';
import { fileExt, baseName, humanSize, previewOf } from '../common/Core';
import { MdText, EmptyState, Card, SectionTitle } from '../view/Common';
import { Tok } from '../view/Theme';

/** 文本预览上限：与本地 FilesPage 保持一致 */
const TEXT_PREVIEW_LIMIT: number = 200 * 1024;

@Entry
@Component
struct WorkspacePage {
  @StorageProp('themeDark') dark: boolean = false;

  /** 当前目录（相对工作区根，'' = 根） */
  @State rel: string = '';
  @State folders: RemoteFolder[] = [];
  @State loading: boolean = false;
  @State errorText: string = '';

  // 文件预览
  @State fileName: string = '';
  // P1-3：当前打开文件的完整路径。刷新时必须用文件路径而不是目录 rel，
  // 否则 openFile({ path: this.rel }) 会把目录当文件读。
  @State openedPath: string = '';
  @State fileBody: string = '';
  @State fileTooBig: boolean = false;
  @State previewing: boolean = false;

  aboutToAppear() {
    this.loadFolders();
  }

  private serverMode(): boolean {
    return (AppStorage.get<string>('dataSource') ?? 'local') === 'server';
  }

  private token(): string {
    return NetConfig.getToken();
  }

  private async loadFolders(): Promise<void> {
    if (!this.serverMode()) {
      this.errorText = '需要先在「设置 → 服务端」连上电脑';
      return;
    }
    this.loading = true;
    this.errorText = '';
    try {
      this.folders = await StudioApi.listRemoteFolders(this.token(), this.rel);
    } catch (e) {
      this.folders = [];
      this.errorText = '加载失败：' + ((e as Error).message ?? '未知错误');
    }
    this.loading = false;
  }

  private async openFolder(f: RemoteFolder): Promise<void> {
    // 服务端给了 path 就用它；没给就自己拼（相对根）
    const next: string = f.path.length > 0 ? f.path
      : (this.rel.length > 0 ? `${this.rel}/${f.name}` : f.name);
    this.rel = next;
    this.closePreview();
    await this.loadFolders();
  }

  private async goUp(): Promise<void> {
    if (this.rel.length === 0) {
      return;
    }
    const i = this.rel.lastIndexOf('/');
    this.rel = i > 0 ? this.rel.substring(0, i) : '';
    this.closePreview();
    await this.loadFolders();
  }

  private async openFile(f: RemoteFolder): Promise<void> {
    const full: string = f.path.length > 0 ? f.path
      : (this.rel.length > 0 ? `${this.rel}/${f.name}` : f.name);
    this.previewing = true;
    this.fileName = f.name;
    // P1-3：记录本次打开的完整文件路径，供「刷新」复用
    this.openedPath = full;
    this.fileBody = '';
    this.fileTooBig = false;
    try {
      const text = await StudioApi.readRemoteFile(this.token(), full);
      // 截断：ArkUI 渲染超长文本会掉帧
      this.fileTooBig = text.length > TEXT_PREVIEW_LIMIT;
      this.fileBody = this.fileTooBig ? text.slice(0, TEXT_PREVIEW_LIMIT) : text;
    } catch (e) {
      this.fileBody = '读取失败：' + ((e as Error).message ?? '未知错误');
    }
  }

  private closePreview(): void {
    this.previewing = false;
    this.fileName = '';
    this.openedPath = '';
    this.fileBody = '';
    this.fileTooBig = false;
  }

  /** 文件夹列表只返回目录，文件名从 name 里剥扩展名显示 */
  private displayName(f: RemoteFolder): string {
    return f.name.length > 0 ? f.name : baseName(f.path);
  }

  build() {
    Column() {
      // 顶栏
      Row({ space: 12 }) {
        Text('‹').fontSize(24).fontColor(Tok.text1(this.dark))
          .width(28)
          .onClick(() => {
            if (this.previewing) {
              this.closePreview();
              return;
            }
            router.back();
          })
        Column({ space: 2 }) {
          Text(this.previewing ? this.fileName : '电脑工作区')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tok.text1(this.dark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.rel.length > 0 ? this.rel : '根目录')
            .fontSize(11)
            .fontColor(Tok.text3(this.dark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Blank()
        if (!this.previewing && this.rel.length > 0) {
          Text('上一级')
            .fontSize(12)
            .fontColor(Tok.brand)
            .width(44)
            .textAlign(TextAlign.End)
            .onClick(() => {
              this.goUp();
            })
        }
        if (this.previewing) {
          Text('刷新')
            .fontSize(12)
            .fontColor(Tok.brand)
            .width(30)
            .textAlign(TextAlign.End)
            .onClick(() => {
              // P1-3：刷新必须用当前打开文件的完整路径 openedPath，
              // 不能再传目录 rel（否则 full 直接取 f.path=目录，读取失败）。
              this.openFile({ name: this.fileName, path: this.openedPath });
            })
        }
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 10 })
      .backgroundColor(Tok.pageBg(this.dark))

      if (this.previewing) {
        // 文件预览
        Scroll() {
          Column({ space: 8 }) {
            if (this.fileTooBig) {
              Text(`文件很大，只显示前 ${Math.floor(TEXT_PREVIEW_LIMIT / 1024)}KB`)
                .fontSize(11)
                .fontColor(Tok.danger)
                .width('100%')
            }
            if (fileExt(this.fileName).length > 0) {
              Text(fileExt(this.fileName).toUpperCase())
                .fontSize(10)
                .fontColor(Tok.brand)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor(Tok.brandSoft)
                .borderRadius(4)
            }
            MdText({ source: this.fileBody, fontSize: 14 })
          }
          .width('100%')
          .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 10, bottom: 24 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      } else {
        // 目录列表
        if (this.loading) {
          Text('加载中…')
            .fontSize(13)
            .fontColor(Tok.text3(this.dark))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 40, bottom: 40 })
        } else if (this.errorText.length > 0) {
          EmptyState({ icon: '⚠', text: this.errorText, hint: '检查是否已连接电脑' })
        } else if (this.folders.length === 0) {
          EmptyState({ icon: '○', text: '这里没有文件夹', hint: 'Agent 的工作文件在 PC 上生成' })
        } else {
          List({ space: 8 }) {
            ForEach(this.folders, (f: RemoteFolder) => {
              ListItem() {
                this.folderRow(f)
              }
            }, (f: RemoteFolder) => (f.path.length > 0 ? f.path : f.name))
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 8 })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tok.pageBg(this.dark))
  }

  @Builder
  folderRow(f: RemoteFolder) {
    Row({ space: 10 }) {
      Text('📁')
        .fontSize(16)
      Text(this.displayName(f))
        .fontSize(14)
        .fontColor(Tok.text1(this.dark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('›')
        .fontSize(15)
        .fontColor(Tok.text3(this.dark))
    }
    .width('100%')
    .padding({ top: 12, bottom: 12, left: 12, right: 8 })
    .backgroundColor(Tok.cardBg(this.dark))
    .borderRadius(Tok.radius)
    .onClick(() => {
      this.openFolder(f);
    })
  }
}