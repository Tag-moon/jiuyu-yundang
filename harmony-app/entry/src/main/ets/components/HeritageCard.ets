/**
 * 九曲云档 —— 遗址卡片组件
 * 封面（年代配色 + 图标）+ 名称 + 维度标签 + 简介 + 收藏星标
 */
import { Heritage, EMPTY_HERITAGE } from '../model/Models';
import { Theme, cityColor } from '../common/Theme';
import { HeritageCover } from './HeritageCover';

@Component
export struct HeritageCard {
  @Prop item: Heritage = EMPTY_HERITAGE;
  @Prop isFav: boolean = false;
  onOpen: (id: string) => void = (id: string) => {
  };
  onFav: (id: string) => void = (id: string) => {
  };

  @Builder
  miniTag(text: string, color: string, bg: string) {
    Text(text)
      .fontSize(11)
      .fontColor(color)
      .backgroundColor(bg)
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .borderRadius(8)
      .maxLines(1)
  }

  build() {
    Row({ space: 12 }) {
      // 封面：预置实景图 / 年代配色回退
      HeritageCover({ item: this.item, coverSize: 78, radius: 12, showEra: true })

      // 文本区
      Column({ space: 5 }) {
        Row({ space: 6 }) {
          Text(this.item.name)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textMain)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.isFav ? '⭐' : '☆')
            .fontSize(20)
            .onClick(() => {
              this.onFav(this.item.id);
            })
        }
        .width('100%')

        Row({ space: 6 }) {
          this.miniTag(this.item.city, '#FFFFFF', cityColor(this.item.city))
          this.miniTag(this.item.era, Theme.primaryLight, '#F3E7D3')
          this.miniTag(this.item.type, Theme.textSub, '#F1ECE1')
        }
        .width('100%')

        Text(this.item.summary)
          .fontSize(12)
          .fontColor(Theme.textSub)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.cardBg)
    .borderRadius(14)
    .onClick(() => {
      this.onOpen(this.item.id);
    })
  }
}
