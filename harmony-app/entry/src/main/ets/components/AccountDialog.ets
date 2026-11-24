/**
 * 九曲云档 —— 账号详情对话框
 * 展示当前手机号账号、登录时间与本机个人数据概况
 */
import { Theme } from '../common/Theme';

/** 账号快照：打开弹窗前由个人页填充，避免弹窗复用旧数据 */
export class AccountSnapshot {
  phone: string = '';
  loginAtText: string = '';
  favCount: number = 0;
  noteCount: number = 0;
  historyCount: number = 0;
  syncEnabled: boolean = false;
  deviceCount: number = 1;
}

@CustomDialog
export struct AccountDialog {
  controller?: CustomDialogController;
  snapshot: AccountSnapshot = new AccountSnapshot();
  onClose: () => void = () => {
  };
  onLogout: () => void = () => {
  };

  @State phone: string = '';
  @State loginAtText: string = '';
  @State favCount: number = 0;
  @State noteCount: number = 0;
  @State historyCount: number = 0;
  @State syncEnabled: boolean = false;
  @State deviceCount: number = 1;

  aboutToAppear(): void {
    this.phone = this.snapshot.phone;
    this.loginAtText = this.snapshot.loginAtText;
    this.favCount = this.snapshot.favCount;
    this.noteCount = this.snapshot.noteCount;
    this.historyCount = this.snapshot.historyCount;
    this.syncEnabled = this.snapshot.syncEnabled;
    this.deviceCount = this.snapshot.deviceCount;
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(Theme.textSub)
      Blank()
      Text(value)
        .fontSize(12)
        .fontColor(Theme.textMain)
    }
    .width('100%')
    .padding({ top: 5, bottom: 5 })
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text('🏺')
          .fontSize(28)
          .width(52)
          .height(52)
          .textAlign(TextAlign.Center)
          .backgroundColor('#F3E7D3')
          .borderRadius(26)
        Column({ space: 4 }) {
          Text(this.phone.length > 0 ? this.phone : '未登录')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textMain)
          Text('九曲云档 · 手机号账号')
            .fontSize(11)
            .fontColor(Theme.textSub)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('✕')
          .fontSize(18)
          .fontColor(Theme.textSub)
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')

      Divider()
        .color(Theme.divider)

      Column({ space: 2 }) {
        this.infoRow('登录时间', this.loginAtText.length > 0 ? this.loginAtText : '--')
        this.infoRow('已收藏遗址', this.favCount.toString() + ' 处')
        this.infoRow('个人笔记', this.noteCount.toString() + ' 条')
        this.infoRow('浏览足迹', this.historyCount.toString() + ' 处')
        this.infoRow('分布式同步',
          this.syncEnabled ? '已开启 · ' + this.deviceCount.toString() + ' 台设备' :
            '未开启（本地模式）')
      }
      .width('100%')

      Row({ space: 12 }) {
        Button('关闭')
          .layoutWeight(1)
          .height(38)
          .fontSize(14)
          .backgroundColor('#EAE3D3')
          .fontColor(Theme.textMain)
          .onClick(() => {
            this.onClose();
          })
        Button('退出登录')
          .layoutWeight(1)
          .height(38)
          .fontSize(14)
          .backgroundColor(Theme.danger)
          .fontColor(Color.White)
          .onClick(() => {
            this.onLogout();
          })
      }
      .width('100%')
    }
    .padding(20)
    .backgroundColor(Theme.bg)
    .borderRadius(16)
  }
}
