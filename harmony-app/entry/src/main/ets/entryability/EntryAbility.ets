/**
 * 九曲云档 —— EntryAbility 入口
 */
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { LocalStore } from '../datasource/LocalStore';
import { DistributedSync } from '../datasource/DistributedSync';
import { UserSession } from '../datasource/UserSession';
import { FormBridge } from '../datasource/FormBridge';
import { CloudSyncService } from '../datasource/CloudSyncService';
import { GuardianConfig } from '../common/GuardianConfig';

const DOMAIN: number = 0x0000;
const TAG: string = 'YellowRiverMemory';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
    // 预建全局收藏版本号：发现/收藏/我的三页通过 @StorageLink 联动刷新
    AppStorage.setOrCreate('favVersion', 0);
    // 桌面卡片数据桥：启动时同步一次已添加卡片的统计
    FormBridge.init(this.context);
    FormBridge.refreshAll();
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    // 按登录态决定落地页：未登录 → 手机号登录页；已登录 → 主页
    const session: UserSession = UserSession.getInstance();
    await session.load(this.context);
    const landing: string = session.isLoggedIn() ? 'pages/MainTabs' : 'pages/LoginPage';
    windowStage.loadContent(landing, (err: BusinessError) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, '加载页面失败: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, '加载页面成功: %{public}s', landing);
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  /**
   * 回到前台时执行一次自动同步
   * 已授权设备静默拉取远端收藏/笔记并按最新时间戳合并；未授权则保持本地模式。
   */
  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onForeground');
    this.autoSync();
    // 回到前台时刷新桌面卡片（同步可能带来了新的收藏/笔记）
    FormBridge.refreshAll();
  }

  private async autoSync(): Promise<void> {
    try {
      const store: LocalStore = LocalStore.getInstance();
      await store.init(this.context);
      const sync: DistributedSync = DistributedSync.getInstance();
      sync.init(this.context);
      sync.setStore(store);
      // 本地数据变更后自动推送到分布式库（未开启同步时内部静默跳过）
      store.setChangeListener(() => {
        sync.schedulePush();
      });
      await sync.autoEnableIfPermitted();
      // 云同步：把本地收藏/笔记/足迹与华为云 API 做一次版本化合并
      if (GuardianConfig.isCloudConfigured()) {
        const session: UserSession = UserSession.getInstance();
        const phone: string = session.getPhone();
        const userId: string = phone.length > 0 ? phone : 'local-device';
        const cloudResult = await CloudSyncService.getInstance().sync(store, userId);
        hilog.info(DOMAIN, TAG, 'cloud sync ok: %{public}s', JSON.stringify(cloudResult));
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'autoSync failed: %{public}s', JSON.stringify(e as Error));
    }
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onBackground');
    // 退到后台前把本机修改推送到分布式库，保证其他设备能及时拉到
    DistributedSync.getInstance().flushPush();
  }
}
