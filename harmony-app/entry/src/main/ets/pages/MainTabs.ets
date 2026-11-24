/**
 * 九曲云档 —— 主框架（底部 Tabs：发现 / 收藏 / 我的）
 */
import { IndexContent } from '../components/IndexContent';
import { CollectionsContent } from '../components/CollectionsContent';
import { MineContent } from '../components/MineContent';
import { Theme } from '../common/Theme';
import { FormBridge } from '../datasource/FormBridge';

@Entry
@Component
struct MainTabs {
  @StorageLink('mainTabIndex') @Watch('onTabIndexChange') currentIndex: number = 0;
  private tabsController: TabsController = new TabsController();
  /**
   * 收藏/笔记变更的全局版本号。
   * 详情页、收藏页任一处改动都会自增，这里统一感知并把最新统计推送到桌面卡片，
   * 避免在多个页面散落刷新调用。
   */
  @StorageLink('favVersion') @Watch('onFavVersion') favVersion: number = 0;

  onFavVersion(): void {
    FormBridge.refreshAll();
  }

  onTabIndexChange(): void {
    this.tabsController.changeIndex(this.currentIndex);
  }

  @Builder
  tabBuilder(index: number, icon: string, title: string) {
    Column({ space: 2 }) {
      Text(icon)
        .fontSize(19)
      Text(title)
        .fontSize(10)
        .fontColor(this.currentIndex === index ? Theme.primary : Theme.textSub)
    }
    .width('100%')
    .height(54)
    .justifyContent(FlexAlign.Center)
    .opacity(this.currentIndex === index ? 1 : 0.6)
  }

  build() {
    Tabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
      TabContent() {
        IndexContent()
      }
      .tabBar(this.tabBuilder(0, '🏛️', '发现'))

      TabContent() {
        CollectionsContent()
      }
      .tabBar(this.tabBuilder(1, '⭐', '收藏'))

      TabContent() {
        MineContent()
      }
      .tabBar(this.tabBuilder(2, '👤', '我的'))
    }
    .scrollable(false)
    .barHeight(56)
    .onChange((index: number) => {
      this.currentIndex = index;
    })
    .backgroundColor(Theme.bg)
  }
}
