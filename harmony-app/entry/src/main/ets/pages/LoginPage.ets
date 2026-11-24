/**
 * 九曲云档 —— 登录页
 * 手机号 + 短信验证码登录
 */
import { router, promptAction } from '@kit.ArkUI';
import { Theme } from '../common/Theme';
import { UserSession } from '../datasource/UserSession';

@Entry
@Component
struct LoginPage {
  @State phone: string = '';
  @State code: string = '';
  @State countdown: number = 0;
  @State agreed: boolean = false;
  @State logging: boolean = false;
  /** 本次验证码 */
  @State sentCode: string = '';

  private timer: number = -1;

  aboutToDisappear(): void {
    this.clearTimer();
  }

  private clearTimer(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private showToast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 2500 });
  }

  private validPhone(): boolean {
    return /^1[3-9]\d{9}$/.test(this.phone);
  }

  /** 获取验证码 */
  sendCode(): void {
    if (this.countdown > 0) {
      return;
    }
    if (!this.validPhone()) {
      this.showToast('请输入正确的 11 位手机号');
      return;
    }
    const n: number = Math.floor(100000 + Math.random() * 900000);
    this.sentCode = n.toString();
    this.countdown = 60;
    this.clearTimer();
    this.timer = setInterval(() => {
      if (this.countdown <= 1) {
        this.countdown = 0;
        this.clearTimer();
      } else {
        this.countdown -= 1;
      }
    }, 1000);
    this.showToast('验证码已发送');
  }

  /** 登录 */
  async doLogin(): Promise<void> {
    if (this.logging) {
      return;
    }
    if (!this.validPhone()) {
      this.showToast('请输入正确的 11 位手机号');
      return;
    }
    if (this.code.length !== 6) {
      this.showToast('请输入 6 位短信验证码');
      return;
    }
    if (this.sentCode.length === 0) {
      this.showToast('请先获取短信验证码');
      return;
    }
    if (this.code !== this.sentCode) {
      this.showToast('验证码不正确，请重新输入');
      return;
    }
    if (!this.agreed) {
      this.showToast('请先阅读并同意用户协议与隐私政策');
      return;
    }
    this.logging = true;
    try {
      await UserSession.getInstance().login(this.phone);
      this.clearTimer();
      router.replaceUrl({ url: 'pages/MainTabs' });
    } catch (e) {
      this.showToast('登录失败，请稍后重试');
      this.logging = false;
    }
  }

  @Builder
  brand() {
    Column({ space: 10 }) {
      Text('🏺')
        .fontSize(52)
        .width(92)
        .height(92)
        .textAlign(TextAlign.Center)
        .backgroundColor('#F3E7D3')
        .borderRadius(46)
      Text('九曲云档')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textMain)
      Text('黄河文化分布式数字档案')
        .fontSize(13)
        .fontColor(Theme.textSub)
    }
    .width('100%')
    .margin({ top: 56, bottom: 26 })
  }

  @Builder
  formCard() {
    Column({ space: 14 }) {
      // 手机号
      Row({ space: 8 }) {
        Text('📱')
          .fontSize(17)
        Text('+86')
          .fontSize(15)
          .fontColor(Theme.textMain)
        Divider()
          .vertical(true)
          .height(18)
          .color(Theme.divider)
        TextInput({ placeholder: '请输入手机号', text: this.phone })
          .layoutWeight(1)
          .fontSize(15)
          .backgroundColor(Color.Transparent)
          .type(InputType.Number)
          .maxLength(11)
          .padding(0)
          .onChange((v: string) => {
            this.phone = v;
          })
      }
      .width('100%')
      .height(52)
      .padding({ left: 14, right: 14 })
      .backgroundColor('#FBF6EA')
      .borderRadius(12)

      // 验证码
      Row({ space: 8 }) {
        Text('🔑')
          .fontSize(17)
        TextInput({ placeholder: '请输入验证码', text: this.code })
          .layoutWeight(1)
          .fontSize(15)
          .backgroundColor(Color.Transparent)
          .type(InputType.Number)
          .maxLength(6)
          .padding(0)
          .onChange((v: string) => {
            this.code = v;
          })
        Text(this.countdown > 0 ? this.countdown + 's 后重发' : '获取验证码')
          .fontSize(13)
          .fontColor(this.countdown > 0 ? Theme.textSub : Theme.primary)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(8)
          .backgroundColor(this.countdown > 0 ? '#EFE8D8' : '#F3E7D3')
          .onClick(() => {
            this.sendCode();
          })
      }
      .width('100%')
      .height(52)
      .padding({ left: 14, right: 10 })
      .backgroundColor('#FBF6EA')
      .borderRadius(12)

      if (this.sentCode.length > 0) {
        Text('验证码：' + this.sentCode)
          .fontSize(11)
          .fontColor(Theme.textSub)
          .width('100%')
      }

      // 协议
      Row({ space: 6 }) {
        Text(this.agreed ? '☑' : '☐')
          .fontSize(14)
          .fontColor(Theme.primary)
        Text('已阅读并同意')
          .fontSize(12)
          .fontColor(Theme.textSub)
        Text('《用户协议》')
          .fontSize(12)
          .fontColor(Theme.primary)
        Text('和')
          .fontSize(12)
          .fontColor(Theme.textSub)
        Text('《隐私政策》')
          .fontSize(12)
          .fontColor(Theme.primary)
      }
      .width('100%')
      .onClick(() => {
        this.agreed = !this.agreed;
      })

      // 登录按钮
      Button(this.logging ? '登录中…' : '手机号登录')
        .width('100%')
        .height(48)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .backgroundColor(Theme.primary)
        .onClick(() => {
          this.doLogin();
        })

      Text('登录后管理你的收藏、笔记与学习足迹')
        .fontSize(11)
        .fontColor(Theme.textSub)
        .lineHeight(17)
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Theme.cardBg)
    .borderRadius(16)
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 20 }) {
          this.brand()
          this.formCard()
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 40 })
        .alignItems(HorizontalAlign.Center)
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }
}
