/**
 * 九曲云档 —— 遗址封面组件
 * 优先展示 rawfile 预置实景图；无图时回退为「年代配色 + 文化图标」的版式化封面，
 * 保证 20 处遗址视觉风格统一，且全部离线可用。
 */
import { Heritage } from '../model/Models';
import { eraColor, cityColor } from '../common/Theme';

@Component
export struct HeritageCover {
  @Prop item: Heritage;
  @Prop coverSize: number = 78;
  /** 高度，0 表示与宽度一致（正方形） */
  @Prop coverHeight: number = 0;
  @Prop radius: number = 12;
  /** 是否显示右下角年代角标 */
  @Prop showEra: boolean = true;

  private isNewCity(): boolean {
    return this.item.city === '济源' || this.item.city === '焦作' || this.item.city === '新乡';
  }

  /** 新增城市封面使用城市色；原有城市继续使用年代色 */
  private fallbackColor(): string {
    return this.isNewCity() ? cityColor(this.item.city) : eraColor(this.item.era);
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.item.image.length > 0) {
        Image($rawfile('images/' + this.item.image))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .borderRadius(this.radius)
      } else {
        Column() {
          Text(this.item.cover)
            .fontSize(Math.round(this.coverSize * 0.4))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .borderRadius(this.radius)
        .linearGradient({
          angle: 135,
          colors: [[this.fallbackColor(), 0], ['#3A2E1F', 1]]
        })
      }

      // 底部渐变遮罩 + 年代角标，保证任何底色下文字都可读
      Column() {
        Row() {
          if (this.showEra) {
            Text(this.item.era)
              .fontSize(10)
              .fontColor(Color.White)
              .backgroundColor('#40000000')
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(8)
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height(this.showEra ? 22 : 0)
      .linearGradient({
        angle: 180,
        colors: [['#00000000', 0], ['#4D000000', 1]]
      })
      .borderRadius({ bottomLeft: this.radius, bottomRight: this.radius })
    }
    .width(this.coverSize)
    .height(this.coverHeight > 0 ? this.coverHeight : this.coverSize)
    .borderRadius(this.radius)
    .clip(true)
  }
}
