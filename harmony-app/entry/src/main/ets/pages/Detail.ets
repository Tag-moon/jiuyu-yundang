/**
 * 九曲云档 —— 遗址详情页
 * 图文介绍 / 考古发现 / 历史事件 / 相关诗词 / 现代文旅 多层级内容
 * 收藏（标签管理）+ 个人笔记 + 关联推荐
 */
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import {
  Heritage, EventItem, PoemItem, RelicItem, NoteItem, FavoriteItem, EMPTY_HERITAGE,
  DEFAULT_TAGS, formatTime, relicKey
} from '../model/Models';
import { HeritageRepository } from '../datasource/HeritageRepository';
import { LocalStore } from '../datasource/LocalStore';
import { Theme, eraColor } from '../common/Theme';
import { TagDialog } from '../components/TagDialog';
import { HeritageCover } from '../components/HeritageCover';

interface DetailRouteParams {
  id: string;
}

/** 笔记编辑共享状态（对话框打开时读取） */
class NoteEditState {
  id: number = 0;
  content: string = '';
}

/** 添加/编辑笔记对话框 */
@CustomDialog
struct NoteDialog {
  controller?: CustomDialogController;
  @State content: string = '';
  editState: NoteEditState = new NoteEditState();
  onSave: (content: string, id: number) => void = (content: string, id: number) => {
  };

  aboutToAppear(): void {
    this.content = this.editState.content;
  }

  build() {
    Column({ space: 12 }) {
      Text(this.editState.id > 0 ? '编辑笔记' : '添加笔记')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textMain)
      TextArea({ placeholder: '记录你的考古发现、学习感想或探访计划…', text: this.content })
        .onChange((v: string) => {
          this.content = v;
        })
        .height(150)
        .backgroundColor(Theme.cardBg)
        .borderRadius(10)
        .fontSize(14)
        .padding(10)
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(38)
          .fontSize(14)
          .backgroundColor('#EAE3D3')
          .fontColor(Theme.textMain)
          .onClick(() => {
            if (this.controller) {
              this.controller.close();
            }
          })
        Button('保存')
          .layoutWeight(1)
          .height(38)
          .fontSize(14)
          .backgroundColor(Theme.primary)
          .onClick(() => {
            this.onSave(this.content, this.editState.id);
            this.content = '';
            if (this.controller) {
              this.controller.close();
            }
          })
      }
      .width('100%')
    }
    .padding(20)
    .backgroundColor(Theme.bg)
    .borderRadius(16)
  }
}

@Entry
@Component
struct Detail {
  @State heritage: Heritage = EMPTY_HERITAGE;
  @State isFav: boolean = false;
  @State favTags: string[] = [];
  @State notes: NoteItem[] = [];
  /** 笔记排序方向：false=最新在前（默认），true=最早在前 */
  @State noteAsc: boolean = false;
  @State recommends: Heritage[] = [];
  @State loaded: boolean = false;
  /** 文物条目收藏状态（与 heritage.relics 下标一一对应） */
  @State relicFavs: boolean[] = [];
  /** 推荐是否叠加了用户行为权重 */
  @State personalized: boolean = false;

  private detailId: string = '';
  private store = LocalStore.getInstance();
  private repo = HeritageRepository.getInstance();
  private editState: NoteEditState = new NoteEditState();
  /** 标签弹窗持有的数组引用：打开前原地更新，避免重建数组导致弹窗读不到已选标签 */
  private editingTags: string[] = [];
  /** 标签栏目的可变引用，供弹窗展示预置与自定义标签 */
  private tagOptions: string[] = [...DEFAULT_TAGS];

  noteDialog: CustomDialogController = new CustomDialogController({
    builder: NoteDialog({
      editState: this.editState,
      onSave: (content: string, id: number) => {
        this.saveNote(content, id);
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });

  tagDialog: CustomDialogController = new CustomDialogController({
    builder: TagDialog({
      initialTags: this.editingTags,
      presetTags: this.tagOptions,
      onNewTag: (tag: string) => {
        this.addTagOption(tag);
      },
      onConfirm: (tags: string[]) => {
        this.saveTags(tags);
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });

  aboutToAppear(): void {
    const params = router.getParams() as DetailRouteParams;
    this.detailId = params.id !== undefined ? params.id : '';
    this.init();
  }

  async init(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await this.repo.load(ctx);
    await this.store.init(ctx);
    const cols: string[] = await this.store.getAllTagList();
    this.tagOptions.splice(0, this.tagOptions.length, ...cols);
    const h = this.repo.getById(this.detailId);
    if (h) {
      this.heritage = h;
      // 记录浏览足迹（学习进度统计的分子；同一条目重复打开只更新时间）
      await this.store.recordView(h.id, h.name);
    }
    // 用户偏好：已收藏条目的年代/城市分布 → 作为推荐权重
    const favs = await this.store.getFavorites();
    const eras: string[] = [];
    const cities: string[] = [];
    for (const f of favs) {
      if (f.itemEra.length > 0 && eras.indexOf(f.itemEra) < 0) {
        eras.push(f.itemEra);
      }
      if (f.itemCity.length > 0 && cities.indexOf(f.itemCity) < 0) {
        cities.push(f.itemCity);
      }
    }
    this.personalized = favs.length > 0;
    if (h) {
      this.recommends = this.repo.recommendById(this.detailId, 8, eras, cities);
      // 文物收藏状态
      const flags: boolean[] = [];
      for (let i = 0; i < h.relics.length; i++) {
        flags.push(await this.store.isFavorite(relicKey(h.id, i)));
      }
      this.relicFavs = flags;
    }
    const fav = await this.store.getFavoriteByItemId(this.detailId);
    this.isFav = fav !== null;
    this.favTags = fav !== null ? fav.tags : [];
    this.notes = await this.store.getNotesByItem(this.detailId);
    this.loaded = true;
  }

  /** 收藏/取消收藏单个文物条目 */
  async toggleRelic(index: number): Promise<void> {
    const h = this.heritage;
    if (!this.loaded || index < 0 || index >= h.relics.length) {
      return;
    }
    const relic: RelicItem = h.relics[index];
    const key: string = relicKey(h.id, index);
    const on: boolean = this.relicFavs[index];
    if (on) {
      await this.store.removeFavorite(key);
    } else {
      const fav = new FavoriteItem();
      fav.itemId = key;
      fav.itemName = relic.name;
      fav.itemEra = h.era;
      fav.itemType = '文物';
      fav.itemCity = h.city;
      fav.itemCover = '🏺';
      fav.createdAt = Date.now();
      await this.store.addFavorite(fav);
    }
    let flags: boolean[] = [];
    for (let i = 0; i < this.relicFavs.length; i++) {
      flags.push(i === index ? !on : this.relicFavs[i]);
    }
    this.relicFavs = flags;
    AppStorage.setOrCreate('favVersion', Date.now());
  }

  /** 打开标签编辑器：先同步当前已选标签，再弹窗 */
  openTagEditor(): void {
    this.editingTags.splice(0, this.editingTags.length, ...this.favTags);
    this.tagDialog.open();
  }

  /** 新建自定义标签：写入栏目列表，并同步到弹窗持有的数组 */
  async addTagOption(tag: string): Promise<void> {
    const ok: boolean = await this.store.addTagColumn(tag);
    if (ok && !this.tagOptions.includes(tag)) {
      this.tagOptions.splice(this.tagOptions.length, 0, tag);
    }
  }

  async toggleFav(): Promise<void> {
    const h = this.heritage;
    if (!this.loaded || h.id.length === 0) {
      return;
    }
    if (this.isFav) {
      await this.store.removeFavorite(h.id);
      this.isFav = false;
      this.favTags = [];
      AppStorage.setOrCreate('favVersion', Date.now());
    } else {
      const fav = new FavoriteItem();
      fav.itemId = h.id;
      fav.itemName = h.name;
      fav.itemEra = h.era;
      fav.itemType = h.type;
      fav.itemCity = h.city;
      fav.itemCover = h.cover;
      fav.createdAt = Date.now();
      await this.store.addFavorite(fav);
      this.isFav = true;
      AppStorage.setOrCreate('favVersion', Date.now());
      this.openTagEditor();
    }
  }

  async saveTags(tags: string[]): Promise<void> {
    if (!this.isFav) {
      return;
    }
    await this.store.updateFavoriteTags(this.detailId, tags);
    this.favTags = tags;
    AppStorage.setOrCreate('favVersion', Date.now());
  }

  /** 打开笔记编辑器：note 为空则新增，否则编辑 */
  openNoteEditor(note: NoteItem | null): void {
    if (note) {
      this.editState.id = note.id;
      this.editState.content = note.content;
    } else {
      this.editState.id = 0;
      this.editState.content = '';
    }
    this.noteDialog.open();
  }

  async saveNote(content: string, id: number): Promise<void> {
    const h = this.heritage;
    if (!this.loaded || h.id.length === 0 || content.trim().length === 0) {
      return;
    }
    if (id > 0) {
      await this.store.updateNote(id, content.trim());
    } else {
      await this.store.addNote(h.id, h.name, content.trim());
    }
    await this.refreshNotes();
  }

  async refreshNotes(): Promise<void> {
    const list = await this.store.getNotesByItem(this.detailId);
    this.notes = this.noteAsc ? this.sortNotesAsc(list) : list;
    AppStorage.setOrCreate('favVersion', Date.now());
  }

  /** 笔记按更新时间升序（最早在前） */
  private sortNotesAsc(list: NoteItem[]): NoteItem[] {
    const arr = list.slice();
    arr.sort((a: NoteItem, b: NoteItem) => a.updatedAt - b.updatedAt);
    return arr;
  }

  /** 切换笔记排序方向 */
  toggleNoteOrder(): void {
    this.noteAsc = !this.noteAsc;
    const arr = this.notes.slice();
    if (this.noteAsc) {
      arr.sort((a: NoteItem, b: NoteItem) => a.updatedAt - b.updatedAt);
    } else {
      arr.sort((a: NoteItem, b: NoteItem) => b.updatedAt - a.updatedAt);
    }
    this.notes = arr;
  }

  async deleteNote(id: number): Promise<void> {
    await this.store.deleteNote(id);
    await this.refreshNotes();
  }

  back(): void {
    router.back();
  }

  /** 推荐跳转用 replaceUrl，避免详情页反复堆叠导致返回困难 */
  openRecommend(id: string): void {
    router.replaceUrl({
      url: 'pages/Detail',
      params: { id: id }
    });
  }

  @Builder
  navBar() {
    Row() {
      Text('‹')
        .fontSize(30)
        .fontColor(Theme.textMain)
        .onClick(() => {
          this.back();
        })
      Text('遗址档案')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textMain)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
      Text('  ')
        .fontSize(22)
        .width(30)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 4 })
  }

  /** 顶部大图区：预置实景图 / 年代配色回退，标题压在渐变遮罩上保证可读 */
  @Builder
  coverSection() {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.heritage.image.length > 0) {
        Image($rawfile('images/' + this.heritage.image))
          .width('100%')
          .height(210)
          .objectFit(ImageFit.Cover)
      } else {
        Column() {
          Text(this.heritage.cover)
            .fontSize(72)
        }
        .width('100%')
        .height(210)
        .justifyContent(FlexAlign.Center)
        .linearGradient({
          angle: 135,
          colors: [[eraColor(this.heritage.era), 0], ['#3A2E1F', 1]]
        })
      }

      // 底部遮罩
      Column()
        .width('100%')
        .height(130)
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0], ['#99000000', 1]]
        })

      Column({ space: 6 }) {
        Text(this.heritage.name)
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
        Text(this.heritage.dynasty)
          .fontSize(12)
          .fontColor('rgba(255,255,255,0.85)')
        Row({ space: 8 }) {
          Text(this.heritage.city)
            .fontSize(11)
            .fontColor(Color.White)
            .backgroundColor('#4D000000')
            .padding({ left: 10, right: 10, top: 3, bottom: 3 })
            .borderRadius(10)
          Text(this.heritage.era)
            .fontSize(11)
            .fontColor(Color.White)
            .backgroundColor('#4D000000')
            .padding({ left: 10, right: 10, top: 3, bottom: 3 })
            .borderRadius(10)
          Text(this.heritage.type)
            .fontSize(11)
            .fontColor(Color.White)
            .backgroundColor('#4D000000')
            .padding({ left: 10, right: 10, top: 3, bottom: 3 })
            .borderRadius(10)
        }
        .margin({ top: 4 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .height(210)
    .clip(true)
  }

  @Builder
  introBlock() {
    Text(this.heritage.intro)
      .fontSize(14)
      .fontColor(Theme.textMain)
      .lineHeight(22)
      .width('100%')
      .padding(14)
      .backgroundColor(Theme.cardBg)
      .borderRadius(12)
  }

  @Builder
  archaeologyBlock() {
    Text(this.heritage.archaeology)
      .fontSize(14)
      .fontColor(Theme.textMain)
      .lineHeight(22)
      .width('100%')
      .padding(14)
      .backgroundColor(Theme.cardBg)
      .borderRadius(12)
  }

  /** 代表性文物条目：可单独收藏 */
  @Builder
  relicBlock() {
    Column({ space: 8 }) {
      if (this.heritage.relics.length === 0) {
        Text('该遗址暂无单列文物条目')
          .fontSize(12)
          .fontColor(Theme.textSub)
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.cardBg)
          .borderRadius(12)
      } else {
        ForEach(this.heritage.relics, (relic: RelicItem, idx: number) => {
          Row({ space: 10 }) {
            Column({ space: 4 }) {
              Text(relic.name)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textMain)
              Text(relic.desc)
                .fontSize(12)
                .fontColor(Theme.textSub)
                .lineHeight(18)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text(this.relicFavs[idx] ? '★' : '☆')
              .fontSize(22)
              .fontColor(this.relicFavs[idx] ? Theme.accent : Theme.textSub)
              .onClick(() => {
                this.toggleRelic(idx);
              })
          }
          .width('100%')
          .padding(12)
          .backgroundColor(Theme.cardBg)
          .borderRadius(12)
        }, (relic: RelicItem, idx: number) => this.heritage.id + '#' + idx.toString())
      }
    }
    .width('100%')
  }

  @Builder
  infoChip(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor(Theme.primary)
      .backgroundColor('#F3E7D3')
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .borderRadius(10)
  }

  @Builder
  actionBar() {
    Row({ space: 10 }) {
        Button(this.isFav ? '⭐ 已收藏' : '☆ 收藏')
        .layoutWeight(1)
        .height(38)
        .fontSize(14)
        .backgroundColor(this.isFav ? Theme.accent : Theme.primary)
        .onClick(() => {
          this.toggleFav();
        })
      Button('📝 添加笔记')
        .layoutWeight(1)
        .height(38)
        .fontSize(14)
        .backgroundColor(Theme.primaryLight)
        .onClick(() => {
          this.openNoteEditor(null);
        })
      if (this.isFav) {
        Button('🏷 标签')
          .layoutWeight(1)
          .height(38)
          .fontSize(14)
          .backgroundColor(Theme.online)
          .onClick(() => {
            this.openTagEditor();
          })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 8 })
  }

  @Builder
  sectionTitle(title: string, icon: string) {
    Row({ space: 6 }) {
      Text(icon)
        .fontSize(16)
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textMain)
      Blank()
    }
    .width('100%')
    .padding({ top: 10, bottom: 6 })
  }

  @Builder
  eventCard(ev: EventItem) {
    Row({ space: 10 }) {
      Text(ev.time)
        .fontSize(11)
        .fontColor(Color.White)
        .backgroundColor(Theme.primary)
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(8)
      Column({ space: 4 }) {
        Text(ev.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMain)
        Text(ev.desc)
          .fontSize(12)
          .fontColor(Theme.textSub)
          .lineHeight(18)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.cardBg)
    .borderRadius(12)
  }

  @Builder
  poemCard(poem: PoemItem) {
    Column({ space: 6 }) {
      Text(poem.content)
        .fontSize(14)
        .fontColor(Theme.textMain)
        .lineHeight(24)
        .fontStyle(FontStyle.Italic)
        .width('100%')
      Row({ space: 6 }) {
        Blank()
        Text('—— ' + poem.author + '《' + poem.title + '》')
          .fontSize(12)
          .fontColor(Theme.textSub)
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#FBF6EA')
    .border({ width: 1, color: Theme.divider })
    .borderRadius(12)
  }

  @Builder
  tourismBlock() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('📍')
          .fontSize(14)
        Text('地址：')
          .fontSize(13)
          .fontColor(Theme.textSub)
        Text(this.heritage.tourism.address)
          .fontSize(13)
          .fontColor(Theme.textMain)
          .layoutWeight(1)
          .lineHeight(19)
      }
      .width('100%')
      Row({ space: 8 }) {
        Text('🕰')
          .fontSize(14)
        Text('开放：')
          .fontSize(13)
          .fontColor(Theme.textSub)
        Text(this.heritage.tourism.openTime)
          .fontSize(13)
          .fontColor(Theme.textMain)
          .layoutWeight(1)
          .lineHeight(19)
      }
      .width('100%')
      Row({ space: 8 }) {
        Text('🎫')
          .fontSize(14)
        Text('门票：')
          .fontSize(13)
          .fontColor(Theme.textSub)
        Text(this.heritage.tourism.ticket)
          .fontSize(13)
          .fontColor(Theme.textMain)
          .layoutWeight(1)
          .lineHeight(19)
      }
      .width('100%')
      Row({ space: 8 }) {
        Text('💡')
          .fontSize(14)
        Text('贴士：')
          .fontSize(13)
          .fontColor(Theme.textSub)
        Text(this.heritage.tourism.tips)
          .fontSize(13)
          .fontColor(Theme.textMain)
          .layoutWeight(1)
          .lineHeight(19)
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.cardBg)
    .borderRadius(12)
  }

  @Builder
  recommendItem(h: Heritage) {
    Column({ space: 6 }) {
      HeritageCover({ item: h, coverSize: 88, coverHeight: 56, radius: 10, showEra: false })
      Text(h.name)
        .fontSize(12)
        .fontColor(Theme.textMain)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(88)
        .textAlign(TextAlign.Center)
      Text(h.city + ' · ' + h.era)
        .fontSize(10)
        .fontColor(Theme.textSub)
        .width(88)
        .textAlign(TextAlign.Center)
    }
    .onClick(() => {
      this.openRecommend(h.id);
    })
  }

  @Builder
  noteBlock() {
    Column({ space: 10 }) {
      if (this.notes.length > 1) {
        // 笔记按时间正序 / 倒序整理
        Row({ space: 8 }) {
        Text('共 ' + this.notes.length + ' 条笔记')
            .fontSize(11)
            .fontColor(Theme.textSub)
          Blank()
        Text('排序：' + (this.noteAsc ? '最早在前' : '最新在前'))
            .fontSize(11)
            .fontColor(Theme.primary)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor('#F3E7D3')
            .borderRadius(9)
            .onClick(() => {
              this.toggleNoteOrder();
            })
        }
        .width('100%')
      }
      if (this.notes.length === 0) {
          Text('还没有笔记，点击上方「添加笔记」记录你的思考…')
          .fontSize(12)
          .fontColor(Theme.textSub)
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.cardBg)
          .borderRadius(12)
      } else {
        ForEach(this.notes, (note: NoteItem) => {
          Column({ space: 6 }) {
            Row({ space: 6 }) {
              Text(formatTime(note.updatedAt))
                .fontSize(10)
                .fontColor(Theme.textSub)
              Blank()
              Text('✎ 编辑')
                .fontSize(11)
                .fontColor(Theme.primary)
                .onClick(() => {
                  this.openNoteEditor(note);
                })
              Text('🗑 删除')
                .fontSize(11)
                .fontColor(Theme.danger)
                .onClick(() => {
                  this.deleteNote(note.id);
                })
            }
            .width('100%')
            Text(note.content)
              .fontSize(13)
              .fontColor(Theme.textMain)
              .lineHeight(20)
              .width('100%')
          }
          .width('100%')
          .padding(12)
          .backgroundColor(Theme.cardBg)
          .borderRadius(12)
        }, (note: NoteItem) => note.id.toString())
      }
    }
    .width('100%')
  }

  build() {
    Column() {
      this.navBar()
      Scroll() {
        Column({ space: 4 }) {
          this.coverSection()
          this.actionBar()

          Column({ space: 6 }) {
            this.sectionTitle('图文介绍', '📜')
            this.introBlock()

            this.sectionTitle('考古发现', '🔍')
            this.archaeologyBlock()

            this.sectionTitle('代表性文物', '🏺')
            Text('可单独收藏感兴趣的文物条目，纳入个人文化记忆库')
              .fontSize(11)
              .fontColor(Theme.textSub)
              .width('100%')
            this.relicBlock()

            this.sectionTitle('历史事件', '📜')
            Column({ space: 8 }) {
              ForEach(this.heritage.events, (ev: EventItem) => {
                this.eventCard(ev)
              }, (ev: EventItem) => ev.time + ev.title)
            }
            .width('100%')

            this.sectionTitle('相关诗词', '🖋')
            Column({ space: 8 }) {
              ForEach(this.heritage.poems, (poem: PoemItem) => {
                this.poemCard(poem)
              }, (poem: PoemItem) => poem.title)
            }
            .width('100%')

            this.sectionTitle('现代文旅', '🚌')
            this.tourismBlock()

            this.sectionTitle('相关推荐', '🔗')
            Text(this.personalized
              ? '结合内容相似度（同年代 / 同城市 / 同类型）与你的收藏偏好推荐'
              : '按内容相似度（同年代 > 同城市 > 同类型）推荐')
              .fontSize(11)
              .fontColor(Theme.textSub)
              .width('100%')
            Scroll() {
              Row({ space: 10 }) {
                ForEach(this.recommends, (h: Heritage) => {
                  this.recommendItem(h)
                }, (h: Heritage) => h.id)
              }
              .padding({ top: 4, bottom: 8 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')

            this.sectionTitle('我的笔记', '📝')
            this.noteBlock()

        Text('数据来源：公开考古资料与文博机构公开信息，仅供学习研究使用')
              .fontSize(10)
              .fontColor(Theme.textSub)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 16, bottom: 24 })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
        }
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }
}
