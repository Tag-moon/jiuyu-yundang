/**
 * 九曲云档 —— 通用筛选条组件
 * 维度名 + 横向滚动的单选 chips
 */
import { Theme } from '../common/Theme';

@Component
export struct FilterChips {
  @Prop label: string = '';
  @Prop options: string[] = [];
  @Prop selected: string = '全部';
  onPick: (value: string) => void = (value: string) => {
  };

  build() {
    Row({ space: 6 }) {
      Text(this.label)
        .fontSize(13)
        .fontColor(Theme.textSub)
        .width(40)
        .textAlign(TextAlign.Start)
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.options, (opt: string) => {
            Text(opt)
              .fontSize(13)
              .fontColor(opt === this.selected ? Color.White : Theme.textMain)
              .backgroundColor(opt === this.selected ? Theme.primary : Theme.cardBg)
              .padding({ left: 12, right: 12, top: 5, bottom: 5 })
              .borderRadius(14)
              .onClick(() => {
                this.onPick(opt);
              })
          }, (opt: string) => opt)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 4 })
  }
}
