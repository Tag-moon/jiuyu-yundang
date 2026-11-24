/**
 * 九曲云档 —— 发现页（文化资源展示与检索）
 * 关键词搜索 + 年代/类型/城市 三维度筛选 + 遗址卡片列表
 */
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { Heritage, FavoriteItem, ERA_LIST, TYPE_LIST, CITY_LIST } from '../model/Models';
import { HeritageRepository } from '../datasource/HeritageRepository';
import { LocalStore } from '../datasource/LocalStore';
import { Theme } from '../common/Theme';
import { CulturalRoute, CULTURAL_ROUTES } from '../common/CulturalRoutes';
import { FilterChips } from './FilterChips';
import { HeritageCard } from './HeritageCard';
import { HeritageCover } from './HeritageCover';

/** 结果排序方式 */
const SORT_OPTIONS: string[] = ['推荐排序', '年代由早到晚', '年代由晚到早', '名称'];

@Component
export struct IndexContent {
  @State heritages: Heritage[] = [];
  @State keyword: string = '';
  @State era: string = '全部';
  @State type: string = '全部';
  @State city: string = '全部';
  @State favIds: string[] = [];
  @State totalCount: number = 0;
  @State loaded: boolean = false;
  @State siteCount: number = 0;
  @State cityCount: number = 0;
  /** 收藏变更全局版本号：详情页/收藏页任意处改动，三个 Tab 同步刷新 */
  @StorageLink('favVersion') @Watch('onFavVersion') favVersion: number = 0;
  /** 搜索历史（持久化于 meta 表，最多 8 条，最近使用在前） */
  @State searchHistory: string[] = [];
  /** 推荐结果 */
  @State recommends: Heritage[] = [];
  /** 推荐候选池（12 条）与当前展示窗口偏移，支持「换一批」 */
  @State recAll: Heritage[] = [];
  @State recOffset: number = 0;
  @State recReason: string = '';
  /** 结果排序方式（默认「推荐排序」= 检索相关度 / 原始数据顺序） */
  @State sortKey: string = SORT_OPTIONS[0];
  /** 当前主题研学路线 */
  @State activeRouteId: string = '';
  @State activeRouteDesc: string = '';
  @State activeRouteHighlight: string = '';

  /** 热门搜索词：高频检索的遗址名 / 年代 / 城市 / 文物类别 */
  private hotWords: string[] = ['仰韶', '龙山', '龙门石窟', '唐三彩', '都城遗址', '洛阳', '夏商'];

  private repo = HeritageRepository.getInstance();
  private store = LocalStore.getInstance();

  onFavVersion(): void {
    this.refreshFav();
    this.loadRecommend();
  }

  aboutToAppear(): void {
    this.init();
  }

  async init(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await this.repo.load(ctx);
    await this.store.init(ctx);
    this.siteCount = this.repo.getAll().length;
    this.cityCount = Math.max(0, this.repo.getCities().length - 1);
    await this.refreshFav();
    await this.loadSearchHistory();
    this.applyFilter();
    await this.loadRecommend();
    this.loaded = true;
  }

  /**
   * 推荐：以「收藏 + 浏览足迹」构成用户偏好（年代 / 城市），本地打分排序；
   * 全程离线；没有任何偏好数据时改为跨年代「热门精选」，保证冷启动也有内容。
   */
  async loadRecommend(): Promise<void> {
    const profile: FavoriteItem[] = [];
    const favs = await this.store.getFavorites();
    for (const f of favs) {
      profile.push(f);
    }
    // 浏览足迹同样参与偏好统计：历史条目只有 id/name，需回表补齐年代与城市
    const hist = await this.store.getHistory(30);
    for (const h of hist) {
      let dup: boolean = false;
      for (const p of profile) {
        if (p.itemId === h.itemId) {
          dup = true;
          break;
        }
      }
      if (dup) {
        continue;
      }
      const item = this.repo.getById(h.itemId);
      if (item === undefined) {
        continue;
      }
      const f = new FavoriteItem();
      f.itemId = item.id;
      f.itemName = item.name;
      f.itemEra = item.era;
      f.itemType = item.type;
      f.itemCity = item.city;
      f.itemCover = item.cover;
      f.createdAt = h.viewedAt;
      profile.push(f);
    }

    if (profile.length === 0) {
      this.recAll = this.pickHot(12);
    this.recReason = '尚无收藏与浏览记录，先为你精选不同年代的代表性遗产';
    } else {
      this.recAll = this.repo.recommendByProfile(profile, 12);
      const citySet: string[] = [];
      for (const p of profile) {
        if (p.itemCity.length > 0 && citySet.indexOf(p.itemCity) < 0) {
          citySet.push(p.itemCity);
        }
      }
      const cityText: string = citySet.length > 0 ? citySet.slice(0, 3).join('、') : '暂未形成';
      this.recReason = '基于你的 ' + profile.length.toString() + ' 条收藏/浏览足迹（偏好城市：' + cityText + '）';
    }
    this.recOffset = 0;
    this.applyRecWindow();
  }

  /** 冷启动热门精选：每个年代取 1 条，保证年代分布均衡 */
  private pickHot(limit: number): Heritage[] {
    const out: Heritage[] = [];
    const seenEra: string[] = [];
    const all = this.repo.getAll();
    for (const h of all) {
      if (seenEra.indexOf(h.era) >= 0) {
        continue;
      }
      seenEra.push(h.era);
      out.push(h);
      if (out.length >= limit) {
        return out;
      }
    }
    // 年代不足时按原顺序补齐
    for (const h of all) {
      let has: boolean = false;
      for (const o of out) {
        if (o.id === h.id) {
          has = true;
          break;
        }
      }
      if (!has) {
        out.push(h);
        if (out.length >= limit) {
          break;
        }
      }
    }
    return out;
  }

  /** 读取搜索历史 */
  async loadSearchHistory(): Promise<void> {
    const raw = await this.store.getMeta('search_history');
    if (raw.length === 0) {
      this.searchHistory = [];
      return;
    }
    const arr: string[] = raw.split('|');
    const list: string[] = [];
    for (let i = 0; i < arr.length; i++) {
      if (arr[i].length > 0) {
        list.push(arr[i]);
      }
    }
    this.searchHistory = list;
  }

  /** 写入一条搜索历史（去重后置顶，截断至 8 条） */
  async pushHistory(kw: string): Promise<void> {
    const key = kw.trim();
    if (key.length === 0) {
      return;
    }
    const list: string[] = [];
    list.push(key);
    for (let i = 0; i < this.searchHistory.length; i++) {
      if (this.searchHistory[i] !== key && list.length < 8) {
        list.push(this.searchHistory[i]);
      }
    }
    this.searchHistory = list;
    await this.store.setMeta('search_history', list.join('|'));
  }

  async clearHistory(): Promise<void> {
    this.searchHistory = [];
    await this.store.setMeta('search_history', '');
  }

  /** 点击历史词 / 热门词：填入搜索框并立即检索 */
  applyKeyword(kw: string): void {
    this.keyword = kw;
    this.applyFilter();
    this.pushHistory(kw);
  }

  /** 一键清除全部筛选条件 */
  resetFilter(): void {
    this.keyword = '';
    this.era = '全部';
    this.type = '全部';
    this.city = '全部';
    this.applyFilter();
  }

  /** 当前是否处于筛选状态 */
  isFiltering(): boolean {
    return this.keyword.length > 0 || this.era !== '全部' || this.type !== '全部' || this.city !== '全部';
  }

  async refreshFav(): Promise<void> {
    const favs = await this.store.getFavorites();
    this.favIds = favs.map((f: FavoriteItem) => f.itemId);
  }

  applyFilter(): void {
    this.activeRouteId = '';
    const list = this.repo.search(this.keyword, this.era, this.type, this.city);
    this.heritages = this.sortList(list);
    this.totalCount = list.length;
  }

  /** 按主题研学路线组织遗址列表 */
  applyRoute(route: CulturalRoute): void {
    this.activeRouteId = route.id;
    this.activeRouteDesc = route.desc;
    this.activeRouteHighlight = route.highlight;
    const list: Heritage[] = [];
    for (const id of route.siteIds) {
      const h = this.repo.getById(id);
      if (h) {
        list.push(h);
      }
    }
    this.heritages = list;
    this.totalCount = list.length;
  }

  /** 退出研学路线，恢复筛选结果 */
  exitRoute(): void {
    this.activeRouteId = '';
    this.activeRouteDesc = '';
    this.activeRouteHighlight = '';
    this.applyFilter();
  }

  /** 获取当前路线说明 */
  activeRoute(): CulturalRoute | null {
    for (const route of CULTURAL_ROUTES) {
      if (route.id === this.activeRouteId) {
        return route;
      }
    }
    return null;
  }

  /** 按当前排序方式排序：推荐排序保持检索相关度 / 原始顺序 */
  private sortList(list: Heritage[]): Heritage[] {
    if (this.sortKey === SORT_OPTIONS[0]) {
      return list;
    }
    const arr: Heritage[] = list.slice();
    if (this.sortKey === SORT_OPTIONS[1] || this.sortKey === SORT_OPTIONS[2]) {
      const asc: boolean = this.sortKey === SORT_OPTIONS[1];
      arr.sort((a: Heritage, b: Heritage) => {
        const ia: number = ERA_LIST.indexOf(a.era);
        const ib: number = ERA_LIST.indexOf(b.era);
        return asc ? ia - ib : ib - ia;
      });
    } else if (this.sortKey === SORT_OPTIONS[3]) {
      arr.sort((a: Heritage, b: Heritage) => {
        if (a.name > b.name) {
          return 1;
        }
        if (a.name < b.name) {
          return -1;
        }
        return 0;
      });
    }
    return arr;
  }

  /** 切换排序方式 */
  pickSort(key: string): void {
    this.sortKey = key;
    this.applyFilter();
  }

  /** 推荐换一批：在候选池中平移窗口（循环） */
  rotateRecommend(): void {
    if (this.recAll.length === 0) {
      return;
    }
    this.recOffset = (this.recOffset + 6) % this.recAll.length;
    this.applyRecWindow();
  }

  /** 按当前窗口截取 6 条推荐（到尾部时从头循环，保证永远有内容） */
  private applyRecWindow(): void {
    if (this.recAll.length === 0) {
      this.recommends = [];
      return;
    }
    const out: Heritage[] = [];
    for (let i: number = 0; i < 6; i++) {
      const idx: number = (this.recOffset + i) % this.recAll.length;
      out.push(this.recAll[idx]);
    }
    this.recommends = out;
  }

  async toggleFav(id: string): Promise<void> {
    if (this.favIds.includes(id)) {
      await this.store.removeFavorite(id);
    } else {
      const h = this.repo.getById(id);
      if (h) {
        const fav = new FavoriteItem();
        fav.itemId = h.id;
        fav.itemName = h.name;
        fav.itemEra = h.era;
        fav.itemType = h.type;
        fav.itemCity = h.city;
        fav.itemCover = h.cover;
        fav.createdAt = Date.now();
        await this.store.addFavorite(fav);
      }
    }
    await this.refreshFav();
    AppStorage.setOrCreate('favVersion', Date.now());
  }

  openDetail(id: string): void {
    router.pushUrl({
      url: 'pages/Detail',
      params: { id: id }
    });
  }

  openMap(): void {
    router.pushUrl({
      url: 'pages/MapPage'
    });
  }

  openGuardian(): void {
    router.pushUrl({
      url: 'pages/Guardian'
    });
  }

  /** 首页地图横幅下方的守护灵入口 */
  @Builder
  guardianEntry() {
    Row({ space: 12 }) {
      Stack() {
        Text('灵')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F6E3B4')
      }
      .width(40)
      .height(40)
      .borderRadius(20)
      .backgroundColor(Theme.primary)
      .border({ width: 1, color: 'rgba(217, 164, 65, 0.75)' })

      Column({ space: 3 }) {
        Text('黄河守护灵')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMain)
        Text('问遗址来历 · 排一条能走的路线')
          .fontSize(11)
          .fontColor(Theme.textSub)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('去问 ›')
        .fontSize(12)
        .fontColor(Color.White)
        .backgroundColor(Theme.primary)
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .borderRadius(14)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .margin({ left: 16, right: 16, bottom: 8 })
    .linearGradient({
      angle: 100,
      colors: [['#FFF9EC', 0.0], ['#F7E6C4', 1.0]]
    })
    .borderRadius(14)
    .border({ width: 1, color: '#E2C58E' })
    .shadow({ radius: 10, color: 'rgba(120, 84, 38, 0.16)', offsetY: 3 })
    .onClick(() => {
      this.openGuardian();
    })
  }

  @Builder
  banner() {
    Row({ space: 12 }) {
      Column({ space: 6 }) {
        Text('黄河万里 · 文明寻踪')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
        Text('沿河南黄河，探访 ' + this.siteCount.toString() + ' 处文化遗产 · ' +
          (ERA_LIST.length - 1).toString() + ' 个年代 · ' + this.cityCount.toString() + ' 座城市')
          .fontSize(11)
          .fontColor('#FFF3DC')
        Row({ space: 6 }) {
          Text('🗺 打开黄河文化地图')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#8A5A2B')
            .backgroundColor('#FFF7E8')
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(12)
        Text('按城市探索')
            .fontSize(11)
            .fontColor('#FFF3DC')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('🌊')
        .fontSize(42)
        .opacity(0.9)
    }
    .width('100%')
    .padding(16)
    .margin({ left: 16, right: 16, bottom: 8 })
    .linearGradient({
      angle: 120,
      colors: [['#C08A4D', 0.0], ['#8A5A2B', 1.0]]
    })
    .borderRadius(14)
    .onClick(() => {
      this.openMap();
    })
  }

  @Builder
  header() {
    Column({ space: 6 }) {
      Text('九曲云档')
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.primary)
        Text('河南段黄河文化数字档案')
        .fontSize(13)
        .fontColor(Theme.textSub)
    }
    .width('100%')
    .padding({ top: 16, bottom: 8 })
  }

  @Builder
  searchBar() {
    Row({ space: 8 }) {
      Text('🔍')
        .fontSize(15)
        TextInput({ placeholder: '搜索遗址 / 城市 / 关键词…', text: this.keyword })
        .onChange((v: string) => {
          this.keyword = v;
          this.applyFilter();
        })
        .onSubmit(() => {
          this.pushHistory(this.keyword);
        })
        .layoutWeight(1)
        .height(38)
        .backgroundColor(Theme.cardBg)
        .borderRadius(18)
        .fontSize(14)
        .padding({ left: 12, right: 12 })

      if (this.keyword.length > 0) {
        Text('✓')
          .fontSize(14)
          .fontColor(Theme.textSub)
          .padding({ left: 4, right: 4 })
          .onClick(() => {
            this.keyword = '';
            this.applyFilter();
          })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 6 })
  }

  /** 搜索历史 + 热门搜索：无关键词时展示，降低冷启动检索成本 */
  @Builder
  hotSearch() {
    if (this.keyword.length === 0) {
      Column({ space: 8 }) {
        if (this.searchHistory.length > 0) {
          Row() {
            Text('搜索历史')
              .fontSize(12)
              .fontColor(Theme.textSub)
            Blank()
            Text('清空')
              .fontSize(12)
              .fontColor(Theme.accent)
              .onClick(() => {
                this.clearHistory();
              })
          }
          .width('100%')

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.searchHistory, (kw: string) => {
              Text(kw)
                .fontSize(12)
                .fontColor(Theme.textMain)
                .backgroundColor(Theme.cardBg)
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .borderRadius(12)
                .margin({ right: 8, bottom: 8 })
                .onClick(() => {
                  this.applyKeyword(kw);
                })
            }, (kw: string) => kw)
          }
          .width('100%')
        }

        Text('热门搜索')
          .fontSize(12)
          .fontColor(Theme.textSub)
          .width('100%')

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.hotWords, (kw: string) => {
            Text(kw)
              .fontSize(12)
              .fontColor(Theme.accent)
              .backgroundColor('#FBF3E4')
              .padding({ left: 12, right: 12, top: 5, bottom: 5 })
              .borderRadius(12)
              .margin({ right: 8, bottom: 8 })
              .onClick(() => {
                this.applyKeyword(kw);
              })
          }, (kw: string) => kw)
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 6 })
    }
  }

  @Builder
  resultBar() {
    Row() {
        Text('共 ' + this.totalCount + ' 处文化遗产')
        .fontSize(12)
        .fontColor(Theme.textSub)
      Blank()
      if (this.isFiltering()) {
        Text('清除筛选')
          .fontSize(12)
          .fontColor(Theme.accent)
          .padding({ left: 4, right: 4 })
          .margin({ right: 12 })
          .onClick(() => {
            this.resetFilter();
          })
      }
        Text('按年代/类型/城市浏览')
        .fontSize(12)
        .fontColor(Theme.textSub)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
  }

  /** 结果排序：推荐 / 年代 / 名称 */
  @Builder
  sortBar() {
    Row() {
      Text('排序')
        .fontSize(12)
        .fontColor(Theme.textSub)
      ForEach(SORT_OPTIONS, (opt: string) => {
        Text(opt)
          .fontSize(12)
          .fontColor(this.sortKey === opt ? '#FFFFFF' : Theme.textMain)
          .backgroundColor(this.sortKey === opt ? Theme.primary : Theme.cardBg)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(12)
          .margin({ left: 8 })
          .onClick(() => {
            this.pickSort(opt);
          })
      }, (opt: string) => opt)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 2, bottom: 4 })
  }

  /** 推荐：基于本地偏好打分，仅在未筛选时展示 */
  @Builder
  recommend() {
    if (!this.isFiltering() && this.recommends.length > 0) {
      Column({ space: 8 }) {
        Row() {
          Text('为你推荐')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textMain)
          Blank()
        Text('换一批')
            .fontSize(12)
            .fontColor(Theme.accent)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .onClick(() => {
              this.rotateRecommend();
            })
        }
        .width('100%')

        Text(this.recReason)
          .fontSize(11)
          .fontColor(Theme.textSub)
          .width('100%')

        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.recommends, (h: Heritage) => {
              Column({ space: 6 }) {
                HeritageCover({ item: h, coverSize: 96, coverHeight: 72, radius: 10, showEra: true })
                Text(h.name)
                  .fontSize(12)
                  .fontColor(Theme.textMain)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(h.city + ' · ' + h.type)
                  .fontSize(10)
                  .fontColor(Theme.textSub)
              }
              .width(96)
              .alignItems(HorizontalAlign.Start)
              .onClick(() => {
                this.openDetail(h.id);
              })
            }, (h: Heritage) => h.id)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 10 })
    }
  }

  /** 主题研学路线 */
  @Builder
  routePanel() {
    Column({ space: 9 }) {
      Row({ space: 8 }) {
        Text('🧭 主题研学路线')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textMain)
        Blank()
        if (this.activeRouteId.length > 0) {
          Text('退出路线')
            .fontSize(11)
            .fontColor(Theme.accent)
            .onClick(() => {
              this.exitRoute();
            })
        }
      }
      .width('100%')

      Text('把分散遗址组织成可执行的研学路径；路线内可继续打开详情、收藏遗址、记录笔记。')
        .fontSize(11)
        .fontColor(Theme.textSub)
        .width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(CULTURAL_ROUTES, (route: CulturalRoute) => {
          Text(route.icon + ' ' + route.title)
            .fontSize(12)
            .fontColor(this.activeRouteId === route.id ? Color.White : Theme.primary)
            .backgroundColor(this.activeRouteId === route.id ? Theme.primary : '#F3E7D3')
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .borderRadius(12)
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.applyRoute(route);
            })
        }, (route: CulturalRoute) => route.id)
      }
      .width('100%')

      if (this.activeRouteId.length > 0) {
        Text(this.activeRouteDesc)
          .fontSize(12)
          .fontColor(Theme.textMain)
          .lineHeight(18)
          .width('100%')
        Text('路线看点：' + this.activeRouteHighlight)
          .fontSize(11)
          .fontColor(Theme.primary)
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.cardBg)
    .borderRadius(12)
  }

  @Builder
  emptyView() {
    Column({ space: 10 }) {
      Text('🏺')
        .fontSize(48)
      Text('未找到匹配的文化遗存')
        .fontSize(15)
        .fontColor(Theme.textMain)
        Text('试试更换关键词或清除筛选条件')
        .fontSize(12)
        .fontColor(Theme.textSub)
      if (this.isFiltering()) {
        Button('清除筛选条件')
          .fontSize(13)
          .height(38)
          .backgroundColor(Theme.primary)
          .padding({ left: 20, right: 20 })
          .margin({ top: 6 })
          .onClick(() => {
            this.resetFilter();
          })
      }
    }
    .width('100%')
    .padding({ top: 80, bottom: 80 })
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Scroll() {
      Column() {
      this.header()
      this.banner()
      this.guardianEntry()
      this.searchBar()

      FilterChips({
        label: '年代',
        options: ERA_LIST,
        selected: this.era,
        onPick: (v: string) => {
          this.era = v;
          this.applyFilter();
        }
      })
      FilterChips({
        label: '类型',
        options: TYPE_LIST,
        selected: this.type,
        onPick: (v: string) => {
          this.type = v;
          this.applyFilter();
        }
      })
      FilterChips({
        label: '城市',
        options: CITY_LIST,
        selected: this.city,
        onPick: (v: string) => {
          this.city = v;
          this.applyFilter();
        }
      })

      this.resultBar()
      this.sortBar()
      this.recommend()
      this.routePanel()
      if (this.activeRouteId.length === 0) {
        this.hotSearch()
      }

      if (this.heritages.length > 0) {
        Column({ space: 10 }) {
          ForEach(this.heritages, (h: Heritage) => {
            HeritageCard({
              item: h,
              isFav: this.favIds.includes(h.id),
              onOpen: (id: string) => {
                this.openDetail(id);
              },
              onFav: (id: string) => {
                this.toggleFav(id);
              }
            })
          }, (h: Heritage) => h.id)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
      } else {
        this.emptyView()
      }
    }
    .width('100%')
    .backgroundColor(Theme.bg)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .backgroundColor(Theme.bg)
    .edgeEffect(EdgeEffect.Spring)
  }
}
