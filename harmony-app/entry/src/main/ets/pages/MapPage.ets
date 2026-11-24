/**
 * 九曲云档 —— 黄河文化地图页
 * 以手绘黄河长卷为底图，按原图比例叠加沿线九市遗址标记
 * 点击城市标记切换遗址列表，点击地图其他区域进入全屏放大查看
 */
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { Heritage, FavoriteItem } from '../model/Models';
import { HeritageRepository } from '../datasource/HeritageRepository';
import { LocalStore } from '../datasource/LocalStore';
import { Theme } from '../common/Theme';
import { HeritageCard } from '../components/HeritageCard';

/** 城市标记（坐标为 400 × 300 的长卷设计坐标，与底图 4:3 比例一致） */
class CityPoint {
  name: string = '';
  x: number = 0;
  y: number = 0;
  /** 标签是否画在标记上方，避免相邻城市标签压住别的标记 */
  labelAbove: boolean = false;

  constructor(name: string, x: number, y: number, labelAbove: boolean = false) {
    this.name = name;
    this.x = x;
    this.y = y;
    this.labelAbove = labelAbove;
  }
}

const MAP_W: number = 400;
const MAP_H: number = 300;
const MAP_RATIO: number = MAP_W / MAP_H;
const ZOOM_MIN: number = 1;
const ZOOM_MAX: number = 4;

@Entry
@Component
struct MapPage {
  @State selectedCity: string = '三门峡';
  @State list: Heritage[] = [];
  @State favIds: string[] = [];

  /** 全屏放大查看 */
  @State zoomOpen: boolean = false;
  @State zoomScale: number = 1;
  @State zoomStart: number = 1;
  @State panX: number = 0;
  @State panY: number = 0;
  @State panStartX: number = 0;
  @State panStartY: number = 0;

  private repo = HeritageRepository.getInstance();
  private store = LocalStore.getInstance();
  private all: Heritage[] = [];
  private points: CityPoint[] = [
    new CityPoint('三门峡', 112, 232, true),
    new CityPoint('洛阳', 158, 248, true),
    new CityPoint('济源', 185, 158),
    new CityPoint('焦作', 225, 150, true),
    new CityPoint('郑州', 215, 258, true),
    new CityPoint('新乡', 268, 185),
    new CityPoint('开封', 275, 245, true),
    new CityPoint('濮阳', 338, 152),
    new CityPoint('安阳', 300, 78)
  ];

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private zoomSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private zoomCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.zoomSettings);

  aboutToAppear(): void {
    this.init();
  }

  onPageShow(): void {
    if (this.all.length > 0) {
      this.refreshFav();
    }
  }

  async init(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await this.repo.load(ctx);
    await this.store.init(ctx);
    this.all = this.repo.getAll();
    this.selectedCity = this.pickDefaultCity();
    await this.refreshList();
    await this.refreshFav();
  }

  /** 默认选中收录遗址最多的城市 */
  pickDefaultCity(): string {
    let best: string = this.selectedCity;
    let bestCount: number = -1;
    for (const pt of this.points) {
      const n: number = this.countOf(pt.name);
      if (n > bestCount) {
        bestCount = n;
        best = pt.name;
      }
    }
    return best;
  }

  async refreshList(): Promise<void> {
    this.list = this.all.filter((h: Heritage) => h.city === this.selectedCity);
  }

  async refreshFav(): Promise<void> {
    try {
      const favs: FavoriteItem[] = await this.store.getFavorites();
      this.favIds = favs.map((f: FavoriteItem): string => f.itemId);
      this.drawMap();
    } catch (e) {
      // 数据层尚未就绪时跳过，初始化完成后会再次刷新
    }
  }

  countOf(city: string): number {
    let n: number = 0;
    for (const h of this.all) {
      if (h.city === city) {
        n++;
      }
    }
    return n;
  }

  favCountOf(city: string): number {
    let n: number = 0;
    for (const h of this.all) {
      if (h.city === city && this.favIds.includes(h.id)) {
        n++;
      }
    }
    return n;
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

  back(): void {
    router.back();
  }

  resetZoom(): void {
    this.zoomScale = ZOOM_MIN;
    this.zoomStart = ZOOM_MIN;
    this.panX = 0;
    this.panY = 0;
    this.panStartX = 0;
    this.panStartY = 0;
  }

  openZoom(): void {
    this.resetZoom();
    this.zoomOpen = true;
    // 内容层为懒加载，等布局完成后再补绘一次标记
    setTimeout(() => {
      this.paintOn(this.zoomCtx);
    }, 80);
  }

  /** 拖动、缩放后把画面限制在可视区域内 */
  clampPan(): void {
    const w: number = this.zoomCtx.width;
    const h: number = this.zoomCtx.height;
    if (!(w > 0) || !(h > 0)) {
      return;
    }
    const maxX: number = w * (this.zoomScale - 1) / 2;
    const maxY: number = h * (this.zoomScale - 1) / 2;
    this.panX = Math.min(maxX, Math.max(-maxX, this.panX));
    this.panY = Math.min(maxY, Math.max(-maxY, this.panY));
  }

  /** 圆角矩形路径 */
  private roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number,
    r: number): void {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
    ctx.lineTo(x + w, y + h - r);
    ctx.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
    ctx.lineTo(x + r, y + h);
    ctx.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
    ctx.lineTo(x, y + r);
    ctx.arc(x + r, y + r, r, Math.PI, Math.PI * 1.5);
    ctx.closePath();
  }

  /** 绘制城市标记与名称 */
  private drawCity(ctx: CanvasRenderingContext2D, pt: CityPoint, s: number, ox: number,
    oy: number): void {
    const x: number = ox + pt.x * s;
    const y: number = oy + pt.y * s;
    const count: number = this.countOf(pt.name);
    const favCount: number = this.favCountOf(pt.name);
    const r: number = (5.5 + Math.min(count, 10) * 0.5) * s;
    const isSel: boolean = pt.name === this.selectedCity;

    if (isSel) {
      ctx.fillStyle = 'rgba(255, 214, 120, 0.42)';
      ctx.beginPath();
      ctx.arc(x, y, r + 2.6 * s, 0, Math.PI * 2);
      ctx.fill();
      ctx.strokeStyle = 'rgba(198, 140, 48, 0.85)';
      ctx.lineWidth = 1.2 * s;
      ctx.beginPath();
      ctx.arc(x, y, r + 2.6 * s, 0, Math.PI * 2);
      ctx.stroke();
    }

    ctx.save();
    ctx.shadowColor = 'rgba(52, 32, 12, 0.3)';
    ctx.shadowBlur = 3 * s;
    ctx.shadowOffsetY = 1 * s;
    ctx.fillStyle = isSel ? '#A9631F' : '#7A4A22';
    ctx.beginPath();
    ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();

    ctx.fillStyle = 'rgba(255, 255, 255, 0.25)';
    ctx.beginPath();
    ctx.arc(x - r * 0.3, y - r * 0.34, r * 0.34, 0, Math.PI * 2);
    ctx.fill();

    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = '#FFFFFF';
    ctx.font = 'bold ' + Math.round(7.5 * s) + 'px sans-serif';
    ctx.fillText(count.toString(), x, y + 0.4 * s);

    if (favCount > 0) {
      ctx.fillStyle = '#F7D06B';
      ctx.font = Math.round(7 * s) + 'px sans-serif';
      ctx.fillText('★', x + r * 0.95, y - r * 0.95);
    }

    ctx.font = 'bold ' + Math.round(8.5 * s) + 'px sans-serif';
    const labelW: number = ctx.measureText(pt.name).width + 8 * s;
    const labelH: number = 12 * s;
    const gap: number = 5 * s;
    const labelY: number = pt.labelAbove ? y - r - gap - labelH / 2 : y + r + gap + labelH / 2;
    ctx.fillStyle = isSel ? 'rgba(255, 244, 214, 0.96)' : 'rgba(255, 251, 240, 0.9)';
    this.roundRect(ctx, x - labelW / 2, labelY - labelH / 2, labelW, labelH, 2.5 * s);
    ctx.fill();
    ctx.strokeStyle = isSel ? 'rgba(176, 126, 60, 0.8)' : 'rgba(120, 84, 38, 0.28)';
    ctx.lineWidth = 0.8 * s;
    ctx.stroke();
    ctx.fillStyle = isSel ? '#6F431F' : '#3A2E1F';
    ctx.fillText(pt.name, x, labelY + 0.3 * s);
  }

  /** 底图上的标题与图例，用白色描边保证在画面上可读 */
  private drawChrome(ctx: CanvasRenderingContext2D, s: number, ox: number, oy: number): void {
    ctx.save();
    ctx.textBaseline = 'middle';
    ctx.shadowColor = 'rgba(255, 252, 244, 0.95)';
    ctx.shadowBlur = 4 * s;

    ctx.textAlign = 'left';
    ctx.fillStyle = '#4E3318';
    ctx.font = 'bold ' + Math.round(12 * s) + 'px sans-serif';
    ctx.fillText('黄河河南段 · 九市分布', ox + 14 * s, oy + 20 * s);

    ctx.font = Math.round(10 * s) + 'px sans-serif';
    ctx.fillStyle = '#5C4529';
    ctx.fillText('数字为收录遗址数    ★ 为含收藏', ox + 14 * s, oy + 285 * s);
    ctx.restore();
  }

  /** 在给定画布上按底图比例绘制标记层 */
  private paintOn(ctx: CanvasRenderingContext2D): void {
    const w: number = ctx.width;
    const h: number = ctx.height;
    if (!(w > 0) || !(h > 0)) {
      return;
    }
    const s: number = Math.min(w / MAP_W, h / MAP_H);
    const ox: number = (w - MAP_W * s) / 2;
    const oy: number = (h - MAP_H * s) / 2;

    ctx.clearRect(0, 0, w, h);
    this.drawChrome(ctx, s, ox, oy);
    for (const pt of this.points) {
      this.drawCity(ctx, pt, s, ox, oy);
    }
  }

  drawMap(): void {
    this.paintOn(this.ctx);
  }

  /** 点击城市标记切换；点击其他区域放大查看 */
  handleTap(e: ClickEvent): void {
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    if (!(w > 0) || !(h > 0)) {
      return;
    }
    const s: number = Math.min(w / MAP_W, h / MAP_H);
    const ox: number = (w - MAP_W * s) / 2;
    const oy: number = (h - MAP_H * s) / 2;
    const x: number = (e.x - ox) / s;
    const y: number = (e.y - oy) / s;
    for (const pt of this.points) {
      const dx: number = x - pt.x;
      const dy: number = y - pt.y;
      if (dx * dx + dy * dy < 24 * 24) {
        if (this.selectedCity !== pt.name) {
          this.selectedCity = pt.name;
          this.refreshList();
          this.drawMap();
        }
        return;
      }
    }
    this.openZoom();
  }

  @Builder
  navBar() {
    Row() {
      Text('‹')
        .fontSize(30)
        .fontColor(Theme.textMain)
        .width(32)
        .textAlign(TextAlign.Start)
        .onClick(() => {
          this.back();
        })
      Text('黄河文化地图')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textMain)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
      Text('★ ' + this.favIds.length.toString())
        .fontSize(12)
        .fontColor(Theme.textSub)
        .width(56)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .padding({ left: 12, right: 16, top: 8, bottom: 4 })
  }

  @Builder
  mapCard() {
    Stack({ alignContent: Alignment.Center }) {
      Image($rawfile('images/qstyle_huanghe_map.jpg'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Contain)

      Canvas(this.ctx)
        .width('100%')
        .height('100%')
        .onReady(() => {
          this.drawMap();
        })
        .onClick((e: ClickEvent) => {
          this.handleTap(e);
        })

      Column() {
        Blank()
        Row() {
          Blank()
          Text('全屏查看')
            .fontSize(11)
            .fontColor('#5C4529')
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor('rgba(255, 250, 238, 0.9)')
            .border({ width: 1, color: 'rgba(176, 126, 60, 0.5)' })
            .borderRadius(14)
            .onClick(() => {
              this.openZoom();
            })
        }
        .width('100%')
        .padding({ right: 10, bottom: 10 })
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .aspectRatio(MAP_RATIO)
    .backgroundColor('#FBF3E4')
    .borderRadius(18)
    .clip(true)
    .border({ width: 1, color: '#E6D3AE' })
    .shadow({ radius: 12, color: 'rgba(120, 84, 38, 0.18)', offsetY: 4 })
  }

  @Builder
  cityTabBar() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.points, (pt: CityPoint) => {
          Text(pt.name + ' ' + this.countOf(pt.name).toString())
            .fontSize(12)
            .fontColor(pt.name === this.selectedCity ? Color.White : Theme.textMain)
            .backgroundColor(pt.name === this.selectedCity ? Theme.primary : Theme.cardBg)
            .border({
              width: pt.name === this.selectedCity ? 0 : 1,
              color: Theme.divider
            })
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .onClick(() => {
              if (this.selectedCity !== pt.name) {
                this.selectedCity = pt.name;
                this.refreshList();
                this.drawMap();
              }
            })
        }, (pt: CityPoint) => pt.name)
      }
      .padding({ left: 16, right: 16 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ top: 10 })
  }

  /** 全屏查看：双指缩放、单指拖动、双击切换倍数，标记层随底图一起缩放 */
  @Builder
  zoomView() {
    Column() {
      Row() {
        Text(Math.round(this.zoomScale * 100).toString() + '%')
          .fontSize(12)
          .fontColor('rgba(255, 255, 255, 0.85)')
          .backgroundColor('rgba(255, 255, 255, 0.14)')
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(12)

        Blank()

        Text('✕')
          .fontSize(18)
          .fontColor(Color.White)
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .backgroundColor('rgba(255, 255, 255, 0.16)')
          .borderRadius(17)
          .onClick(() => {
            this.zoomOpen = false;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 40, bottom: 8 })

      Stack() {
        Stack({ alignContent: Alignment.Center }) {
          Image($rawfile('images/qstyle_huanghe_map.jpg'))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)

          Canvas(this.zoomCtx)
            .width('100%')
            .height('100%')
            .onReady(() => {
              this.paintOn(this.zoomCtx);
            })
        }
        .width('100%')
        .aspectRatio(MAP_RATIO)
        .scale({ x: this.zoomScale, y: this.zoomScale })
        .translate({ x: this.panX, y: this.panY })
        .gesture(
          GestureGroup(GestureMode.Parallel,
            PinchGesture({ fingers: 2 })
              .onActionStart(() => {
                this.zoomStart = this.zoomScale;
              })
              .onActionUpdate((e: GestureEvent) => {
                const next: number = this.zoomStart * e.scale;
                this.zoomScale = next < ZOOM_MIN ? ZOOM_MIN : (next > ZOOM_MAX ? ZOOM_MAX : next);
                this.clampPan();
              })
              .onActionEnd(() => {
                this.zoomStart = this.zoomScale;
                if (this.zoomScale <= 1.02) {
                  this.zoomScale = ZOOM_MIN;
                  this.panX = 0;
                  this.panY = 0;
                } else {
                  this.clampPan();
                }
                this.panStartX = this.panX;
                this.panStartY = this.panY;
              }),
            PanGesture({ fingers: 1 })
              .onActionStart(() => {
                this.panStartX = this.panX;
                this.panStartY = this.panY;
              })
              .onActionUpdate((e: GestureEvent) => {
                this.panX = this.panStartX + e.offsetX;
                this.panY = this.panStartY + e.offsetY;
                this.clampPan();
              })
              .onActionEnd(() => {
                this.panStartX = this.panX;
                this.panStartY = this.panY;
              }),
            TapGesture({ count: 2 })
              .onAction(() => {
                animateTo({ duration: 200 }, () => {
                  if (this.zoomScale > 1.2) {
                    this.zoomScale = ZOOM_MIN;
                    this.panX = 0;
                    this.panY = 0;
                  } else {
                    this.zoomScale = 2.2;
                  }
                });
                this.zoomStart = this.zoomScale;
                this.panStartX = this.panX;
                this.panStartY = this.panY;
              })
          )
        )
      }
      .width('100%')
      .layoutWeight(1)
      .clip(true)

      Text('双指缩放 · 双击放大 · 拖动查看')
        .fontSize(11)
        .fontColor('rgba(255, 255, 255, 0.7)')
        .margin({ top: 6, bottom: 22 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#141210')
  }

  build() {
    Column() {
      this.navBar()

      Column() {
        this.mapCard()
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      this.cityTabBar()

      Row() {
        Text('📍 ' + this.selectedCity + ' · ' + this.list.length.toString() + ' 处文化遗址')
          .fontSize(13)
          .fontColor(Theme.textSub)
        Blank()
        Text('★ ' + this.favIds.length.toString() + ' 已收藏')
          .fontSize(11)
          .fontColor(Theme.textSub)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 6 })

      if (this.list.length > 0) {
        List({ space: 10 }) {
          ForEach(this.list, (h: Heritage) => {
            ListItem() {
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
            }
          }, (h: Heritage) => h.id)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ left: 16, right: 16, top: 4, bottom: 12 })
      } else {
        Column({ space: 8 }) {
          Text('🏺')
            .fontSize(40)
          Text('该城市暂无收录的文化遗址')
            .fontSize(13)
            .fontColor(Theme.textSub)
          Text('可切换上方其他城市，或前往「发现」页按年代浏览')
            .fontSize(11)
            .fontColor(Theme.textSub)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
    .bindContentCover(this.zoomOpen, this.zoomView(), {
      onDisappear: () => {
        this.zoomOpen = false;
        this.resetZoom();
      }
    })
  }
}
