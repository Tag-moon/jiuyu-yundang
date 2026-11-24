/**
 * 九曲云档 —— 我的页
 * 个人数据统计、分布式双向同步与数据备份
 */
import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  FavoriteItem, NoteItem, HistoryItem, formatTime,
  buildBackupText, parseBackupText, BackupPayload, isRelicKey, relicHeritageId
} from '../model/Models';
import { HeritageRepository } from '../datasource/HeritageRepository';
import { LocalStore } from '../datasource/LocalStore';
import { DistributedSync, SyncStatus, SyncResult } from '../datasource/DistributedSync';
import { UserSession } from '../datasource/UserSession';
import { Theme } from '../common/Theme';
import { KnowledgeGraph, KnowledgeGroup, KnowledgeEntry } from './KnowledgeGraph';
import { AccountDialog, AccountSnapshot } from './AccountDialog';

/** 分布统计项 */
interface DistItem {
  label: string;
  count: number;
}

/** @Builder 按引用传参的包装接口（ArkTS 禁止无类型对象字面量，且值传递时状态变化不重绘） */
interface StatCardParam {
  label: string;
  value: number;
  icon: string;
}

@Component
export struct MineContent {
  @State favCount: number = 0;
  @State noteCount: number = 0;
  @State totalCount: number = 0;
  /** 当前登录账号（脱敏手机号） */
  @State phone: string = '';
  @State status: SyncStatus = new SyncStatus();
  @State restoring: boolean = false;
  @State tagDist: DistItem[] = [];
  /** 知识图谱分组：年代脉络 + 主题归类 */
  @State eraGroups: KnowledgeGroup[] = [];
  @State tagGroups: KnowledgeGroup[] = [];
  /** 浏览足迹与学习进度 */
  @State viewedCount: number = 0;
  @State historyCount: number = 0;
  @State history: HistoryItem[] = [];
  /** 收藏变更全局版本号，跨 Tab 自动刷新 */
  @StorageLink('favVersion') @Watch('onFavVersion') favVersion: number = 0;

  onFavVersion(): void {
    this.refresh();
  }

  private store = LocalStore.getInstance();
  private repo = HeritageRepository.getInstance();
  private sync = DistributedSync.getInstance();

  /** 账号详情弹窗数据：打开前原地刷新，保证展示当前账号与最新统计 */
  private accountSnapshot: AccountSnapshot = new AccountSnapshot();

  /** 账号详情弹窗控制器：必须作为组件成员定义，方法内临时创建会导致 close 失效 */
  accountDialog: CustomDialogController = new CustomDialogController({
    builder: AccountDialog({
      snapshot: this.accountSnapshot,
      onClose: () => {
        this.closeAccount();
      },
      onLogout: () => {
        this.closeAccount();
        this.confirmLogout();
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });

  closeAccount(): void {
    this.accountDialog.close();
  }

  aboutToAppear(): void {
    this.init();
  }

  async init(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await this.repo.load(ctx);
    await this.store.init(ctx);
    this.sync.init(ctx);
    this.sync.setStore(this.store);
    // 本机收藏 / 笔记 / 足迹变更后自动推送到分布式库
    this.store.setChangeListener(() => {
      this.sync.schedulePush();
    });
    this.sync.setChangeListener(() => {
      this.status = this.sync.getStatus().clone();
      // 远端合并会改变收藏 / 笔记 / 足迹，同步刷新本页统计
      this.refresh();
    });
    // 若用户此前已授权开启过，则自动恢复同步
    await this.sync.autoEnableIfPermitted();
    this.status = this.sync.getStatus().clone();
    await this.refresh();
  }

  async refresh(): Promise<void> {
    this.favCount = await this.store.getFavoriteCount();
    this.noteCount = await this.store.getNoteCount();
    this.totalCount = this.repo.getAll().length;
    this.phone = UserSession.getInstance().maskedPhone();
    this.sync.refreshDevices();
    this.status = this.sync.getStatus().clone();
    const favs = await this.store.getFavorites();
    this.tagDist = this.computeTagDist(favs);
    // 知识图谱：年代脉络分组（含文物）+ 主题标签分组（仅遗址）
    this.eraGroups = this.buildEraGroups(favs);
    this.tagGroups = this.buildTagGroups(favs);
    this.viewedCount = await this.store.getViewedCount();
    this.historyCount = this.viewedCount;
    this.history = await this.store.getHistory(8);
  }

  /** 登录时间文案（账号详情弹窗展示） */
  loginAtText(): string {
    const ts: number = UserSession.getInstance().getLoginAt();
    return ts > 0 ? formatTime(ts) : '';
  }

  /** FavoriteItem 转知识条目 */
  private toEntry(f: FavoriteItem): KnowledgeEntry {
    const e: KnowledgeEntry = new KnowledgeEntry();
    e.itemId = f.itemId;
    e.name = f.itemName;
    e.city = f.itemCity;
    e.cover = f.itemCover;
    e.era = f.itemEra;
    e.createdAt = f.createdAt;
    e.isRelic = isRelicKey(f.itemId);
    return e;
  }

  /** 年代脉络分组：按仰韶→宋演进顺序，组内按收藏（探索）时间先后 */
  private buildEraGroups(favs: FavoriteItem[]): KnowledgeGroup[] {
    const map = new Map<string, KnowledgeEntry[]>();
    for (const f of favs) {
      const era: string = f.itemEra.length > 0 ? f.itemEra : '其他';
      const list: KnowledgeEntry[] = map.get(era) ?? [];
      list.push(this.toEntry(f));
      map.set(era, list);
    }
    const order: string[] = ['仰韶', '龙山', '夏商', '周', '汉唐', '宋', '其他'];
    const out: KnowledgeGroup[] = [];
    for (const era of order) {
      const list: KnowledgeEntry[] | undefined = map.get(era);
      if (list !== undefined) {
        list.sort((a: KnowledgeEntry, b: KnowledgeEntry) => a.createdAt - b.createdAt);
        out.push(new KnowledgeGroup(era, list));
      }
    }
    return out;
  }

  /** 主题归类分组：遗址按标签聚合，无标签归未分类；文物不参与 */
  private buildTagGroups(favs: FavoriteItem[]): KnowledgeGroup[] {
    const map = new Map<string, KnowledgeEntry[]>();
    for (const f of favs) {
      if (isRelicKey(f.itemId)) {
        continue;
      }
      const put = (title: string): void => {
        const list: KnowledgeEntry[] = map.get(title) ?? [];
        list.push(this.toEntry(f));
        map.set(title, list);
      };
      if (f.tags.length === 0) {
        put('未分类');
      } else {
        for (const t of f.tags) {
          put(t);
        }
      }
    }
    const out: KnowledgeGroup[] = [];
    map.forEach((list: KnowledgeEntry[], title: string) => {
      list.sort((a: KnowledgeEntry, b: KnowledgeEntry) => a.createdAt - b.createdAt);
      out.push(new KnowledgeGroup(title, list));
    });
    out.sort((a: KnowledgeGroup, b: KnowledgeGroup) => {
      if (a.title === '未分类') {
        return 1;
      }
      if (b.title === '未分类') {
        return -1;
      }
      return b.entries.length - a.entries.length;
    });
    return out;
  }

  /** 学习进度百分比：已探索条目 / 全部遗址条目 */
  progressPercent(): number {
    if (this.totalCount <= 0) {
      return 0;
    }
    const p = Math.round((this.viewedCount / this.totalCount) * 100);
    return p > 100 ? 100 : p;
  }

  /** 学习等级：按探索比例给出称号 */
  progressLevel(): string {
    const p = this.progressPercent();
    if (p >= 100) {
      return '黄河文化通';
    }
    if (p >= 60) {
      return '资深探寻者';
    }
    if (p >= 30) {
      return '文化爱好者';
    }
    if (p > 0) {
      return '初识黄河';
    }
    return '尚未开始';
  }

  openDetail(itemId: string): void {
    if (isRelicKey(itemId)) {
      router.pushUrl({ url: 'pages/Detail', params: { id: relicHeritageId(itemId) } });
    } else {
      router.pushUrl({ url: 'pages/Detail', params: { id: itemId } });
    }
  }

  /** 按标签统计收藏分布（自定义主题标签 → 知识节点） */
  private computeTagDist(list: FavoriteItem[]): DistItem[] {
    const map = new Map<string, number>();
    for (const f of list) {
      if (f.tags.length === 0) {
        map.set('未分类', (map.get('未分类') ?? 0) + 1);
        continue;
      }
      for (const t of f.tags) {
        map.set(t, (map.get(t) ?? 0) + 1);
      }
    }
    const out: DistItem[] = [];
    map.forEach((v: number, k: string) => {
      out.push({ label: k, count: v });
    });
    out.sort((a: DistItem, b: DistItem) => b.count - a.count);
    return out;
  }

  goDiscover(): void {
    AppStorage.setOrCreate('mainTabIndex', 0);
  }

  /** 打开账号详情（未登录则直接回到登录页） */
  openAccount(): void {
    if (this.phone.length === 0) {
      router.replaceUrl({ url: 'pages/LoginPage' });
      return;
    }
    this.accountSnapshot.phone = this.phone;
    this.accountSnapshot.loginAtText = this.loginAtText();
    this.accountSnapshot.favCount = this.favCount;
    this.accountSnapshot.noteCount = this.noteCount;
    this.accountSnapshot.historyCount = this.historyCount;
    this.accountSnapshot.syncEnabled = this.status.enabled;
    this.accountSnapshot.deviceCount = this.status.deviceCount;
    this.accountDialog.open();
  }

  /** 退出登录：先弹出二次确认，避免误触直接退出（本机个人数据保留） */
  async confirmLogout(): Promise<void> {
    if (this.phone.length === 0) {
      this.showToast('当前未登录');
      return;
    }
    const res = await promptAction.showDialog({
      title: '确认退出登录？',
      message: '退出后需要重新登录才能继续使用，确定退出吗？',
      buttons: [
        { text: '取消', color: '#8A7F6D' },
        { text: '退出登录', color: '#B00020' }
      ]
    });
    if (res.index === 1) {
      await UserSession.getInstance().logout();
      this.phone = '';
      router.replaceUrl({ url: 'pages/LoginPage' });
    }
  }

  showToast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 2500 });
  }

  async onToggleSync(): Promise<void> {
    if (this.status.enabled) {
      await this.confirmDisableSync();
      return;
    }
    const ok: boolean = await this.sync.enable();
    if (ok) {
      const res: SyncResult = await this.sync.syncAll();
      this.showToast('同步已开启：推送 ' + res.pushed + ' 条，合并 ' + res.merged + ' 条');
    } else {
      this.showToast(this.sync.getStatus().message);
    }
    this.status = this.sync.getStatus().clone();
    await this.refresh();
  }

  /** 关闭分布式同步：二次确认后停止同步，本机数据完整保留 */
  async confirmDisableSync(): Promise<void> {
    const res = await promptAction.showDialog({
      title: '关闭分布式同步？',
      message: '关闭后本机收藏、笔记与足迹都会保留，只是不再与其他设备同步，可随时重新开启。',
      buttons: [
        { text: '取消', color: '#8A7F6D' },
        { text: '关闭', color: '#B00020' }
      ]
    });
    if (res.index !== 1) {
      return;
    }
    await this.sync.disable();
    this.status = this.sync.getStatus().clone();
    await this.refresh();
    this.showToast('已关闭分布式同步');
  }

  /** 双向同步：先拉取远端最新版本，再推送本机变更，最后再拉一次 */
  async onSyncNow(): Promise<void> {
    if (!this.status.enabled) {
      this.showToast('请先开启分布式同步');
      return;
    }
    const res: SyncResult = await this.sync.syncAll();
    this.status = this.sync.getStatus().clone();
    await this.refresh();
    this.showToast('同步完成：推送 ' + res.pushed + ' 条，合并 ' + res.merged + ' 条' +
      (res.removed > 0 ? '，删除 ' + res.removed + ' 条' : ''));
  }

  async onBackup(): Promise<void> {
    const favs = await this.store.getFavorites();
    const notes = await this.store.getAllNotes();
    const historyItems = await this.store.getHistory(100);
    const text = buildBackupText(favs, notes, historyItems);
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      this.showToast('备份已复制：' + favs.length + ' 条收藏 / ' + notes.length + ' 条笔记 / ' +
        historyItems.length + ' 条足迹');
    } catch (e) {
      this.showToast('备份失败：' + JSON.stringify(e as Error));
    }
  }

  /** 从剪贴板备份一键恢复（设备间完整迁移） */
  async onRestore(): Promise<void> {
    if (this.restoring) {
      return;
    }
    this.restoring = true;
    try {
      const pb = pasteboard.getSystemPasteboard();
      const data = await pb.getData();
      const text: string = data.getPrimaryText();
      if (text.length === 0) {
        this.showToast('剪贴板为空，请先复制备份内容');
        this.restoring = false;
        return;
      }
      const payload: BackupPayload | null = parseBackupText(text);
      if (payload === null) {
        this.showToast('剪贴板内容不是有效的备份数据');
        this.restoring = false;
        return;
      }
      let addedFav: number = 0;
      let addedNote: number = 0;
      let addedHistory: number = 0;
      for (const f of payload.favorites) {
        const ok: boolean = await this.store.mergeFavorite(f);
        if (ok) {
          addedFav++;
        }
      }
      for (const n of payload.notes) {
        const ok: boolean = await this.store.mergeNote(n);
        if (ok) {
          addedNote++;
        }
      }
      const historyItems: HistoryItem[] = payload.history !== undefined ? payload.history : [];
      for (const item of historyItems) {
        const ok: boolean = await this.store.mergeHistoryItem(item);
        if (ok) {
          addedHistory++;
        }
      }
      await this.refresh();
      this.showToast('恢复完成：收藏 ' + addedFav + ' 条、笔记 ' + addedNote + ' 条、足迹 ' +
        addedHistory + ' 条');
    } catch (e) {
      this.showToast('恢复失败：' + JSON.stringify(e as Error));
    }
    this.restoring = false;
  }

  @Builder
  header() {
    Row({ space: 14 }) {
      Text('🏺')
        .fontSize(44)
        .width(64)
        .height(64)
        .textAlign(TextAlign.Center)
        .backgroundColor('#F3E7D3')
        .borderRadius(32)
      Column({ space: 4 }) {
        Text(this.phone.length > 0 ? this.phone : '未登录')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textMain)
        Text('九曲云档 · 手机号登录账号')
          .fontSize(12)
          .fontColor(Theme.textSub)
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 18 })
  }

  @Builder
  statCard(params: StatCardParam) {
    Column({ space: 4 }) {
      Text(params.icon)
        .fontSize(20)
      Text(params.value.toString())
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.primary)
      Text(params.label)
        .fontSize(12)
        .fontColor(Theme.textSub)
    }
    .layoutWeight(1)
    .padding({ top: 14, bottom: 14 })
    .backgroundColor(Theme.cardBg)
    .borderRadius(12)
  }

  @Builder
  sectionTitle(title: string, sub: string) {
    Column({ space: 4 }) {
      Row() {
        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMain)
        Blank()
      }
      .width('100%')
      Text(sub)
        .fontSize(11)
        .fontColor(Theme.textSub)
        .width('100%')
    }
    .width('100%')
  }

  /** 探索进度 */
  @Builder
  progressCard() {
    Column({ space: 8 }) {
      Row() {
        Text('探索进度')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMain)
        Blank()
        Text(this.favCount + ' / ' + this.totalCount)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.primary)
      }
      .width('100%')

      Stack({ alignContent: Alignment.Start }) {
        Text('')
          .width('100%')
          .height(10)
          .backgroundColor('#F1ECE1')
          .borderRadius(5)
        Text('')
          .width(this.totalCount > 0 ? (this.favCount / this.totalCount * 100) + '%' : '0%')
          .height(10)
          .backgroundColor(Theme.accent)
          .borderRadius(5)
      }
      .width('100%')

      Text(this.favCount > 0 ? '已收藏 ' + this.favCount + ' 处，继续探索黄河文明' : '从「发现」页或「地图」页开始你的文化之旅吧')
        .fontSize(11)
        .fontColor(Theme.textSub)
        .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.cardBg)
    .borderRadius(12)
  }

  /**
   * 学习进度：基于浏览足迹统计已探索条目占比。
   * 与「探索进度（收藏数）」互补——看过但不一定要收藏，更贴近真实学习行为。
   */
  @Builder
  learnCard() {
    Column({ space: 8 }) {
      Row() {
        Text('学习进度')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMain)
        Blank()
        Text(this.progressLevel())
          .fontSize(12)
          .fontColor('#FFFFFF')
          .backgroundColor(Theme.accent)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(9)
      }
      .width('100%')

      Stack({ alignContent: Alignment.Start }) {
        Text('')
          .width('100%')
          .height(10)
          .backgroundColor('#F1ECE1')
          .borderRadius(5)
        Text('')
          .width(this.progressPercent() + '%')
          .height(10)
          .backgroundColor(Theme.primary)
          .borderRadius(5)
      }
      .width('100%')

      Text('已探索 ' + this.viewedCount + ' / ' + this.totalCount + ' 处（' + this.progressPercent() + '%）· ' +
        (this.viewedCount > 0 ? '继续深入，解锁「黄河文化通」' : '打开任意遗址详情页即可记录足迹'))
        .fontSize(11)
        .fontColor(Theme.textSub)
        .width('100%')

      if (this.history.length > 0) {
        Column({ space: 2 }) {
          Text('最近浏览')
            .fontSize(12)
            .fontColor(Theme.textSub)
            .width('100%')
            .margin({ top: 4, bottom: 2 })
          ForEach(this.history, (it: HistoryItem) => {
            Row({ space: 6 }) {
              Text('🕘')
                .fontSize(11)
              Text(it.itemName)
                .fontSize(12)
                .fontColor(Theme.textMain)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(formatTime(it.viewedAt))
                .fontSize(10)
                .fontColor(Theme.textSub)
            }
            .width('100%')
            .padding({ top: 5, bottom: 5 })
            .onClick(() => {
              this.openDetail(it.itemId);
            })
          }, (it: HistoryItem) => it.itemId)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.cardBg)
    .borderRadius(12)
  }

  @Builder
  syncPanel() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text(this.status.enabled ? '🟢' : '⚪')
          .fontSize(14)
        Text(this.status.message)
          .fontSize(13)
          .fontColor(this.status.enabled ? Theme.online : Theme.textSub)
          .layoutWeight(1)
      }
      .width('100%')

      Row({ space: 12 }) {
        Column({ space: 3 }) {
          Text('设备数')
            .fontSize(10)
            .fontColor(Theme.textSub)
          Text(this.status.deviceCount.toString())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textMain)
        }
        .layoutWeight(1)
        Column({ space: 3 }) {
          Text('最后同步')
            .fontSize(10)
            .fontColor(Theme.textSub)
          Text(this.status.lastSyncTime > 0 ? formatTime(this.status.lastSyncTime) : '--')
            .fontSize(11)
            .fontColor(Theme.textMain)
        }
        .layoutWeight(1)
        Column({ space: 3 }) {
          Text('冲突记录')
            .fontSize(10)
            .fontColor(Theme.textSub)
          Text(this.status.conflictCount.toString())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.status.conflictCount > 0 ? Theme.danger : Theme.textMain)
        }
        .layoutWeight(1)
      }
      .width('100%')

      // 同步进度可视化
      if (this.status.syncing) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(Theme.primary)
          Text('正在同步数据…')
            .fontSize(11)
            .fontColor(Theme.primary)
        }
        .width('100%')
        .padding({ top: 2, bottom: 2 })
      } else if (this.status.enabled) {
        Row({ space: 6 }) {
          Text('📱')
            .fontSize(12)
          Text('→')
            .fontSize(11)
            .fontColor(Theme.textSub)
          Text('📲')
            .fontSize(12)
          Text(this.status.deviceCount > 1
            ? this.status.deviceCount + ' 台设备已连接' +
              (this.status.deviceNames.length > 0 ? '：' + this.status.deviceNames.join('、') : '')
            : '等待其他设备上线')
            .fontSize(11)
            .fontColor(Theme.textSub)
        }
        .width('100%')
        .padding({ top: 2, bottom: 2 })
      }

      Row({ space: 10 }) {
        Button(this.status.enabled ? '关闭分布式同步' : '开启分布式同步')
          .layoutWeight(1)
          .height(36)
          .fontSize(13)
          .backgroundColor(this.status.enabled ? '#F3E7D3' : Theme.primary)
          .fontColor(this.status.enabled ? Theme.primary : Color.White)
          .borderWidth(this.status.enabled ? 1 : 0)
          .borderColor(Theme.accent)
          .onClick(() => {
            this.onToggleSync();
          })
        Button('双向同步')
          .layoutWeight(1)
          .height(36)
          .fontSize(13)
          .backgroundColor(Theme.accent)
          .onClick(() => {
            this.onSyncNow();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.cardBg)
    .borderRadius(12)
  }

  @Builder
  actionRow(icon: string, title: string, sub: string, action: () => void) {
    Row({ space: 12 }) {
      Text(icon)
        .fontSize(20)
      Column({ space: 3 }) {
        Text(title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMain)
        Text(sub)
          .fontSize(11)
          .fontColor(Theme.textSub)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('›')
        .fontSize(20)
        .fontColor(Theme.textSub)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.cardBg)
    .borderRadius(12)
    .onClick(() => {
      action();
    })
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 14 }) {
          this.header()

          Row({ space: 10 }) {
            this.statCard({ label: '已收藏遗址', value: this.favCount, icon: '⭐' })
            this.statCard({ label: '个人笔记', value: this.noteCount, icon: '📝' })
            this.statCard({ label: '档案库遗址', value: this.totalCount, icon: '🏛' })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          Column({ space: 8 }) {
            this.sectionTitle('我的文化足迹', '收藏统计与探索进度')
            this.progressCard()
            this.learnCard()
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          Column({ space: 8 }) {
            this.sectionTitle('分布式数据同步', '同一超级终端下的多设备数据双向同步')
            this.syncPanel()
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          Column({ space: 8 }) {
            this.sectionTitle('个人知识节点网络', '收藏主题归类与知识结构可视化')
            Column({ space: 10 }) {
              KnowledgeGraph({ eraGroups: this.eraGroups, tagGroups: this.tagGroups })
              if (this.favCount === 0) {
                Button('去发现页收藏遗址')
                  .width('100%')
                  .height(40)
                  .fontSize(14)
                  .backgroundColor(Theme.primary)
                  .onClick(() => {
                    this.goDiscover();
                  })
              }
              if (this.tagDist.length > 0) {
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.tagDist, (t: DistItem) => {
                    Text(t.label + ' · ' + t.count)
                      .fontSize(11)
                      .fontColor(Theme.primary)
                      .backgroundColor('#F3E7D3')
                      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                      .borderRadius(10)
                      .margin({ right: 6, bottom: 6 })
                  }, (t: DistItem) => t.label + t.count)
                }
                .width('100%')
              }
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.cardBg)
            .borderRadius(12)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          Column({ space: 8 }) {
            this.sectionTitle('账号管理', '')
            this.actionRow('📱', '手机号账号', this.phone.length > 0 ? this.phone : '未登录',
              () => {
                this.openAccount();
              })
            this.actionRow('🚪', '退出登录', '', () => {
              this.confirmLogout();
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          Column({ space: 8 }) {
            this.sectionTitle('数据管理', '本地存储，支持备份与恢复')
            this.actionRow('📤', '一键备份数据', '将收藏、笔记与浏览足迹导出为 JSON 复制到剪贴板', () => {
              this.onBackup();
            })
            this.actionRow('📥', this.restoring ? '正在恢复…' : '从备份一键恢复',
              '读取剪贴板中的备份数据，合并收藏、笔记与学习进度', () => {
              this.onRestore();
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          Column({ space: 8 }) {
            this.sectionTitle('关于', '')
            this.actionRow('🏺', '九曲云档', '黄河文化分布式数字档案 · 版本 1.0.0', () => {
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

        }
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }
}
