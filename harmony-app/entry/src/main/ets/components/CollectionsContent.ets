/**
 * 九曲云档 —— 收藏页（个人收藏与笔记系统）
 * 收藏夹（按标签分类管理）+ 全部笔记；支持编辑标签、删除收藏、删除笔记
 */
import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { FavoriteItem, NoteItem, formatTime, relicHeritageId, isRelicKey } from '../model/Models';
import { LocalStore } from '../datasource/LocalStore';
import { Theme, tagColor } from '../common/Theme';
import { TagDialog } from './TagDialog';
import { ManageTagsDialog } from './ManageTagsDialog';

/** @Builder 按引用传参的包装接口（ArkTS 禁止无类型对象字面量） */
interface FavItemParam {
  fav: FavoriteItem;
}
interface NoteItemParam {
  note: NoteItem;
}

@Component
export struct CollectionsContent {
  @State showNotes: boolean = false;
  @State favList: FavoriteItem[] = [];
  @State noteList: NoteItem[] = [];
  @State tagFilter: string = '全部';
  @State editingFavId: string = '';
  @State editingTags: string[] = [];
  /** 用户可管理的标签栏目（预置 + 自定义），从本地库读取；系统栏目 全部/文物/未分类 不包含在内 */
  @State tagColumns: string[] = [];
  /** 收藏变更全局版本号，跨 Tab 自动刷新 */
  @StorageLink('favVersion') @Watch('onFavVersion') favVersion: number = 0;

  private store = LocalStore.getInstance();

  onFavVersion(): void {
    this.refresh();
  }

  dialogController: CustomDialogController = new CustomDialogController({
    builder: TagDialog({
      initialTags: this.editingTags,
      presetTags: this.tagColumns,
      onNewTag: (tag: string) => {
        this.registerNewTag(tag);
      },
      onConfirm: (tags: string[]) => {
        this.saveTags(tags);
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });

  /** 标签栏目管理弹窗 */
  manageController: CustomDialogController = new CustomDialogController({
    builder: ManageTagsDialog({
      tagList: this.tagColumns,
      onAdd: (tag: string) => {
        this.addTagColumn(tag);
      },
      onRemove: (tag: string) => {
        this.confirmRemoveTagColumn(tag);
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });

  aboutToAppear(): void {
    this.init();
  }

  async init(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await this.store.init(ctx);
    await this.refresh();
  }

  async refresh(): Promise<void> {
    this.favList = await this.store.getFavorites();
    this.noteList = await this.store.getAllNotes();
    // 原地更新，保证两个弹窗 controller 持有的数组引用始终有效
    const cols: string[] = await this.store.getAllTagList();

    // 一致性自愈：遗址上若挂着已删除栏目的残留标签，自动摘除（文物不处理）
    let repaired: boolean = false;
    for (const f of this.favList) {
      if (!isRelicKey(f.itemId)) {
        const valid: string[] = f.tags.filter((t: string) => cols.includes(t));
        if (valid.length !== f.tags.length) {
          await this.store.updateFavoriteTags(f.itemId, valid);
          repaired = true;
        }
      }
    }
    if (repaired) {
      this.favList = await this.store.getFavorites();
    }

    this.tagColumns.splice(0, this.tagColumns.length, ...cols);
  }

  // ---------- 标签栏目管理 ----------

  /** 打标签弹窗中新建自定义标签：注册为全局栏目 */
  async registerNewTag(tag: string): Promise<void> {
    await this.store.addTagColumn(tag);
    await this.refresh();
  }

  /** 栏目管理弹窗中新增栏目 */
  async addTagColumn(tag: string): Promise<void> {
    const ok: boolean = await this.store.addTagColumn(tag);
    await this.refresh();
    if (!ok) {
      promptAction.showToast({ message: '栏目已存在或名称为空', duration: 2000 });
    }
  }

  /** 删除栏目前二次确认；确认后标签从所有收藏项摘除，收藏保留 */
  async confirmRemoveTagColumn(tag: string): Promise<void> {
    const res = await promptAction.showDialog({
      title: '删除标签栏目「' + tag + '」？',
      message: '该标签会从所有收藏遗址上移除，遗址本身保留并回到「未分类」。',
      buttons: [
        { text: '取消', color: '#8A7F6D' },
        { text: '删除', color: '#B00020' }
      ]
    });
    if (res.index === 1) {
      await this.store.removeTagColumn(tag);
      if (this.tagFilter === tag) {
        this.tagFilter = '全部';
      }
      await this.refresh();
      AppStorage.setOrCreate('favVersion', Date.now());
    }
  }

  getFilteredFavs(): FavoriteItem[] {
    if (this.tagFilter === '全部') {
      return this.favList;
    }
    // 文物统一归入「文物」栏，不再参与标签分类
    if (this.tagFilter === '文物') {
      return this.favList.filter((f: FavoriteItem) => isRelicKey(f.itemId));
    }
    if (this.tagFilter === '未分类') {
      return this.favList.filter((f: FavoriteItem) => !isRelicKey(f.itemId) && f.tags.length === 0);
    }
    return this.favList.filter((f: FavoriteItem) => !isRelicKey(f.itemId) && f.tags.includes(this.tagFilter));
  }

  openTagEditor(fav: FavoriteItem): void {
    this.editingFavId = fav.itemId;
    // 原地更新数组：弹窗 controller 构造时已持有该数组引用，重新赋值会导致引用失效、已有标签不回显
    this.editingTags.splice(0, this.editingTags.length, ...fav.tags);
    this.dialogController.open();
  }

  async saveTags(tags: string[]): Promise<void> {
    if (this.editingFavId.length === 0) {
      return;
    }
    await this.store.updateFavoriteTags(this.editingFavId, tags);
    this.editingFavId = '';
    await this.refresh();
    // 通知主框架/桌面卡片等感知收藏变更
    AppStorage.setOrCreate('favVersion', Date.now());
  }

  async removeFav(itemId: string): Promise<void> {
    await this.store.removeFavorite(itemId);
    await this.refresh();
    AppStorage.setOrCreate('favVersion', Date.now());
  }

  async removeNote(id: number): Promise<void> {
    await this.store.deleteNote(id);
    await this.refresh();
    AppStorage.setOrCreate('favVersion', Date.now());
  }

  openDetail(itemId: string): void {
    // 文物条目的 itemId 形如 "yinxu#0"，需还原为其所属遗址 id
    router.pushUrl({
      url: 'pages/Detail',
      params: { id: relicHeritageId(itemId) }
    });
  }

  @Builder
  segControl() {
    Row({ space: 8 }) {
      Text('⭐ 收藏夹')
        .fontSize(14)
        .fontWeight(!this.showNotes ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(!this.showNotes ? Color.White : Theme.textMain)
        .backgroundColor(!this.showNotes ? Theme.primary : Theme.cardBg)
        .padding({ left: 18, right: 18, top: 7, bottom: 7 })
        .borderRadius(16)
        .onClick(() => {
          this.showNotes = false;
        })
      Text('📝 笔记')
        .fontSize(14)
        .fontWeight(this.showNotes ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.showNotes ? Color.White : Theme.textMain)
        .backgroundColor(this.showNotes ? Theme.primary : Theme.cardBg)
        .padding({ left: 18, right: 18, top: 7, bottom: 7 })
        .borderRadius(16)
        .onClick(() => {
          this.showNotes = true;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 8 })
  }

  @Builder
  tagFilterBar() {
    Row({ space: 8 }) {
      Scroll() {
        Row({ space: 8 }) {
          // 系统栏目（全部/文物/未分类）+ 用户可管理的标签栏目
          ForEach(['全部', '文物', '未分类', ...this.tagColumns], (tag: string) => {
            Text(tag)
              .fontSize(12)
              .fontColor(tag === this.tagFilter ? Color.White : Theme.textMain)
              .backgroundColor(tag === this.tagFilter ? Theme.accent : Theme.cardBg)
              .padding({ left: 12, right: 12, top: 5, bottom: 5 })
              .borderRadius(12)
              .onClick(() => {
                this.tagFilter = tag;
              })
          }, (tag: string) => tag)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)

      // 栏目管理入口（新增 / 删除标签栏目）
      Text('⚙')
        .fontSize(14)
        .width(30)
        .height(28)
        .textAlign(TextAlign.Center)
        .backgroundColor(Theme.cardBg)
        .borderRadius(10)
        .onClick(() => {
          this.manageController.open();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  // 注意：@Builder 必须以对象形式「按引用」传参，直接传 fav 时值变化不会触发卡片重绘
  @Builder
  favItem(params: FavItemParam) {
    Row({ space: 10 }) {
      Text(params.fav.itemCover)
        .fontSize(28)
        .width(52)
        .height(52)
        .textAlign(TextAlign.Center)
        .backgroundColor('#F3E7D3')
        .borderRadius(10)

      Column({ space: 5 }) {
        Row({ space: 6 }) {
          if (isRelicKey(params.fav.itemId)) {
            Text('文物')
              .fontSize(9)
              .fontColor(Color.White)
              .backgroundColor(Theme.accent)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .borderRadius(6)
          }
          Text(params.fav.itemName)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textMain)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(formatTime(params.fav.createdAt))
            .fontSize(10)
            .fontColor(Theme.textSub)
        }
        .width('100%')

        Row({ space: 5 }) {
          if (isRelicKey(params.fav.itemId)) {
            // 文物不打标签：只保留移除按钮
            Blank()
            Text('🗑 移除')
              .fontSize(11)
              .fontColor(Theme.danger)
              .onClick(() => {
                this.removeFav(params.fav.itemId);
              })
          } else {
            if (params.fav.tags.length === 0) {
              Text('未分类')
                .fontSize(10)
                .fontColor(Theme.textSub)
                .backgroundColor('#F1ECE1')
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(6)
            } else {
              ForEach(params.fav.tags, (tag: string) => {
                Text(tag)
                  .fontSize(10)
                  .fontColor(Color.White)
                  .backgroundColor(tagColor(tag))
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(6)
              }, (tag: string) => tag)
            }
            Blank()
            Text('✎ 标签')
              .fontSize(11)
              .fontColor(Theme.primary)
              .onClick(() => {
                this.openTagEditor(params.fav);
              })
            Text('🗑 移除')
              .fontSize(11)
              .fontColor(Theme.danger)
              .onClick(() => {
                this.removeFav(params.fav.itemId);
              })
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.cardBg)
    .borderRadius(12)
    .onClick(() => {
      this.openDetail(params.fav.itemId);
    })
  }

  @Builder
  noteItem(params: NoteItemParam) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text('📝 ' + params.note.itemName)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMain)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(formatTime(params.note.updatedAt))
          .fontSize(10)
          .fontColor(Theme.textSub)
      }
      .width('100%')

      Text(params.note.content)
        .fontSize(13)
        .fontColor(Theme.textSub)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Row() {
        Blank()
        Text('🗑 删除')
          .fontSize(11)
          .fontColor(Theme.danger)
          .onClick(() => {
            this.removeNote(params.note.id);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.cardBg)
    .borderRadius(12)
    .onClick(() => {
      this.openDetail(params.note.itemId);
    })
  }

  @Builder
  emptyView(text: string) {
    Column({ space: 8 }) {
      Text('🗂')
        .fontSize(44)
      Text(text)
        .fontSize(13)
        .fontColor(Theme.textSub)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Column() {
      Text(this.showNotes ? '我的笔记' : '我的收藏')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.primary)
        .width('100%')
        .padding({ left: 16, top: 16 })

      this.segControl()

      if (!this.showNotes) {
        if (this.favList.length > 0) {
          this.tagFilterBar()
          List({ space: 10 }) {
            ForEach(this.getFilteredFavs(), (fav: FavoriteItem) => {
              ListItem() {
                this.favItem({ fav: fav })
              }
            }, (fav: FavoriteItem) => fav.itemId)
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        } else {
          this.emptyView('还没有收藏，去「发现」页探索黄河文化吧')
        }
      } else {
        if (this.noteList.length > 0) {
          List({ space: 10 }) {
            ForEach(this.noteList, (note: NoteItem) => {
              ListItem() {
                this.noteItem({ note: note })
              }
            }, (note: NoteItem) => note.id.toString())
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        } else {
          this.emptyView('还没有笔记，去遗址详情页添加一条吧')
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }
}
