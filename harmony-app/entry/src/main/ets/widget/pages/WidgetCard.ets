/**
 * WidgetCard.ets 桌面服务卡片（2x2）· 九曲云档
 * 上半区：每日一遗（按日期稳定轮换的文化遗址推荐）
 * 下半区：个人收藏数 / 笔记数
 * 点击卡片拉起应用首页
 */

let storageCard: LocalStorage = new LocalStorage();

@Entry(storageCard)
@Component
struct WidgetCard {
  @LocalStorageProp('site_name') siteName: string = '九曲云档';
  @LocalStorageProp('site_city') siteCity: string = '';
  @LocalStorageProp('site_era') siteEra: string = '';
  @LocalStorageProp('site_summary') siteSummary: string = '河南段黄河文化数字档案';
  @LocalStorageProp('fav_count') favCount: number = 0;
  @LocalStorageProp('note_count') noteCount: number = 0;

  build() {
    Column() {
      // 顶部：标题 + 年代标签
      Row() {
        Text('🏺')
          .fontSize(16)
        Text('每日一遗')
          .fontSize(13)
          .fontColor('#FFF3DC')
          .fontWeight(FontWeight.Bold)
          .margin({ left: 4 })
        Blank()
        if (this.siteEra.length > 0) {
          Text(this.siteEra)
            .fontSize(10)
            .fontColor('#8A5A2B')
            .backgroundColor('#FFF7E8')
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .borderRadius(8)
        }
      }
      .width('100%')

      // 遗址名称
      Text(this.siteName)
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 8 })

      // 一句话简介
      Text(this.siteSummary)
        .fontSize(11)
        .fontColor('rgba(255,255,255,0.85)')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(15)
        .width('100%')
        .margin({ top: 3 })

      Blank()

      // 底部：收藏 / 笔记统计
      Row() {
        Text('⭐ 收藏 ' + this.favCount)
          .fontSize(11)
          .fontColor('rgba(255,255,255,0.95)')
        Blank()
        Text('📝 笔记 ' + this.noteCount)
          .fontSize(11)
          .fontColor('rgba(255,255,255,0.95)')
        if (this.siteCity.length > 0) {
          Text('📍 ' + this.siteCity)
            .fontSize(11)
            .fontColor('rgba(255,255,255,0.95)')
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .padding({ top: 7 })
      .border({ width: { top: 0.5 }, color: 'rgba(255,255,255,0.25)' })
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .borderRadius(20)
    .linearGradient({
      angle: 135,
      colors: [['#C08A4D', 0.0], ['#8A5A2B', 1.0]]
    })
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: {
          from: 'widget',
          siteName: this.siteName
        }
      });
    })
  }
}
