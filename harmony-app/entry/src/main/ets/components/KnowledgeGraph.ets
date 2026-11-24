/**
 * 九曲云档 —— 个人文化知识图谱
 * 双维度梳理：
 *  时间脉络 —— 按仰韶→龙山→夏商→周→汉唐→宋的年代演进串联，组内按收藏（探索）时间先后排列；
 *  主题归类 —— 按个人标签聚合，未标签的遗址归入「未分类」。
 * 每个分组可展开查看明细，点击条目直达遗址详情。
 */
import { router } from '@kit.ArkUI';
import { eraColor, tagColor } from '../common/Theme';
import { relicHeritageId } from '../model/Models';

/** 知识条目（一次收藏：遗址或文物） */
export class KnowledgeEntry {
  itemId: string = '';
  name: string = '';
  city: string = '';
  cover: string = '';
  era: string = '';
  createdAt: number = 0;
  isRelic: boolean = false;
}

/** 知识分组（一个年代或一个标签） */
export class KnowledgeGroup {
  title: string = '';
  entries: KnowledgeEntry[] = [];

  constructor(title: string, entries: KnowledgeEntry[]) {
    this.title = title;
    this.entries = entries;
  }
}

interface GroupCardParam {
  group: KnowledgeGroup;
  color: string;
  expandedKey: string;
}

interface EntryRowParam {
  entry: KnowledgeEntry;
}

@Component
export struct KnowledgeGraph {
  @Prop eraGroups: KnowledgeGroup[] = [];
  @Prop tagGroups: KnowledgeGroup[] = [];
  @State mode: number = 0;
  @State expandedKey: string = '';

  private eras: string[] = ['仰韶', '龙山', '夏商', '周', '汉唐', '宋'];

  groupColor(title: string): string {
    return this.eras.includes(title) ? eraColor(title) : tagColor(title);
  }

  toggle(key: string): void {
    this.expandedKey = this.expandedKey === key ? '' : key;
  }

  openDetail(entry: KnowledgeEntry): void {
    const id: string = entry.isRelic ? relicHeritageId(entry.itemId) : entry.itemId;
    router.pushUrl({ url: 'pages/Detail', params: { id: id } });
  }

  @Builder
  entryRow(params: EntryRowParam) {
    Row({ space: 8 }) {
      Text(params.entry.cover)
        .fontSize(18)
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .backgroundColor('#F3E7D3')
        .borderRadius(8)
      Column({ space: 2 }) {
        Row({ space: 5 }) {
          if (params.entry.isRelic) {
            Text('文物')
              .fontSize(8)
              .fontColor(Color.White)
              .backgroundColor(tagColor('文物'))
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .borderRadius(5)
          }
          Text(params.entry.name)
            .fontSize(13)
            .fontColor('#3A2E1F')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        Text((params.entry.city.length > 0 ? params.entry.city + ' · ' : '') + this.fmtTime(params.entry.createdAt))
          .fontSize(10)
          .fontColor('#9A8C78')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('›')
        .fontSize(16)
        .fontColor('#B7A98F')
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(9)
    .onClick(() => {
      this.openDetail(params.entry);
    })
  }

  @Builder
  groupCard(params: GroupCardParam) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text('')
          .width(10)
          .height(10)
          .borderRadius(5)
          .backgroundColor(params.color)
        Text(params.group.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#3A2E1F')
        Text(params.group.entries.length.toString())
          .fontSize(10)
          .fontColor(Color.White)
          .backgroundColor(params.color)
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .borderRadius(8)
        Blank()
        Text(this.expandedKey === params.expandedKey ? '收起 ▲' : '展开 ▼')
          .fontSize(11)
          .fontColor('#8A5A2B')
      }
      .width('100%')

      if (this.expandedKey === params.expandedKey) {
        Column({ space: 4 }) {
          ForEach(params.group.entries, (entry: KnowledgeEntry) => {
            this.entryRow({ entry: entry })
          }, (entry: KnowledgeEntry) => entry.itemId)
        }
        .width('100%')
        .padding(6)
        .backgroundColor('#FBF6EA')
        .borderRadius(10)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Color.White)
    .borderRadius(12)
    .onClick(() => {
      this.toggle(params.expandedKey);
    })
  }

  /** 时间脉络：竖向时间轴串联各年代分组 */
  @Builder
  timelineView() {
    Column({ space: 10 }) {
      if (this.eraGroups.length === 0) {
        this.hintView()
      } else {
        ForEach(this.eraGroups, (group: KnowledgeGroup, index?: number) => {
          Row({ space: 10 }) {
            // 左侧时间轴：圆点 + 向下连线
            Column() {
              Text('')
                .width(12)
                .height(12)
                .borderRadius(6)
                .backgroundColor(this.groupColor(group.title))
                .border({ width: 2, color: Color.White })
              if (index === undefined || index + 1 < this.eraGroups.length) {
                Text('')
                  .width(2)
                  .layoutWeight(1)
                  .backgroundColor('#E2D6C0')
              }
            }
            .width(14)
            .height('100%')
            .alignItems(HorizontalAlign.Center)

            this.groupCard({
              group: group,
              color: this.groupColor(group.title),
              expandedKey: 'era_' + group.title
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }, (group: KnowledgeGroup) => 'era_' + group.title)
      }
    }
    .width('100%')
  }

  /** 主题归类：标签分组 */
  @Builder
  topicView() {
    Column({ space: 10 }) {
      if (this.tagGroups.length === 0) {
        this.hintView()
      } else {
        ForEach(this.tagGroups, (group: KnowledgeGroup) => {
          this.groupCard({
            group: group,
            color: this.groupColor(group.title),
            expandedKey: 'tag_' + group.title
          })
        }, (group: KnowledgeGroup) => 'tag_' + group.title)
      }
    }
    .width('100%')
  }

  @Builder
  hintView() {
    Column({ space: 6 }) {
      Text('🗺')
        .fontSize(34)
      Text('收藏遗址后，这里会按年代脉络和主题标签梳理你的知识网络')
        .fontSize(11)
        .fontColor('#9A8C78')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ top: 24, bottom: 24 })
  }

  fmtTime(ts: number): string {
    const d: Date = new Date(ts);
    const pad = (n: number): string => (n < 10 ? '0' + n : '' + n);
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
  }

  build() {
    Column({ space: 10 }) {
      // 视图切换
      Row({ space: 8 }) {
        Text('🕰 时间脉络')
          .fontSize(12)
          .fontColor(this.mode === 0 ? Color.White : '#5C4E3A')
          .backgroundColor(this.mode === 0 ? '#8A5A2B' : '#F1ECE1')
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .borderRadius(13)
          .onClick(() => {
            this.mode = 0;
          })
        Text('🏷 主题归类')
          .fontSize(12)
          .fontColor(this.mode === 1 ? Color.White : '#5C4E3A')
          .backgroundColor(this.mode === 1 ? '#8A5A2B' : '#F1ECE1')
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .borderRadius(13)
          .onClick(() => {
            this.mode = 1;
          })
      }
      .width('100%')

      if (this.mode === 0) {
        this.timelineView()
      } else {
        this.topicView()
      }
    }
    .width('100%')
  }
}
