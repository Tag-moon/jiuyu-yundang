/**
 * 九曲云档 —— 黄河守护灵
 * 基于本地档案上下文的文化问答页
 */
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { Theme } from '../common/Theme';
import { GuardianConfig } from '../common/GuardianConfig';
import { GuardianMsg, GuardianService } from '../datasource/GuardianService';
import { LocalStore } from '../datasource/LocalStore';
import { HeritageRepository } from '../datasource/HeritageRepository';

@Entry
@Component
struct Guardian {
  @State messages: GuardianMsg[] = [];
  @State input: string = '';
  @State sending: boolean = false;
  @State ready: boolean = false;

  private scroller: Scroller = new Scroller();
  private service = GuardianService.getInstance();
  private store = LocalStore.getInstance();
  private repo = HeritageRepository.getInstance();

  aboutToAppear(): void {
    this.init();
  }

  async init(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await this.repo.load(ctx);
    await this.store.init(ctx);
    this.messages = [new GuardianMsg('assistant',
      '我是黄河守护灵，九市五十六处遗存都在我的记忆里。你可以问我某处遗址的来历，也可以让我替你排一条能走的路。')];
    this.ready = true;
  }

  scrollToBottom(): void {
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 60);
  }

  async send(text?: string): Promise<void> {
    const q: string = (text !== undefined ? text : this.input).trim();
    if (q.length === 0 || this.sending) {
      return;
    }
    this.messages = this.messages.concat([new GuardianMsg('user', q)]);
    this.input = '';
    this.sending = true;
    this.scrollToBottom();
    try {
      const reply: string = await this.service.ask(q, this.messages);
      this.messages = this.messages.concat([new GuardianMsg('assistant', reply)]);
    } catch (e) {
      this.messages = this.messages.concat([new GuardianMsg('assistant', this.describeError(e as Error))]);
    } finally {
      this.sending = false;
      this.scrollToBottom();
    }
  }

  describeError(e: Error): string {
    const msg: string = e.message !== undefined ? e.message : '';
    if (msg === 'HTTP_401' || msg === 'HTTP_403') {
      return '云服务鉴权未通过，请检查云上 API 配置。';
    }
    if (msg === 'HTTP_429') {
      return '问得有些急，稍等片刻再试一次。';
    }
    if (msg.indexOf('HTTP_') >= 0) {
      return '云端档案服务暂时没有应答，请确认华为云 API 已部署。';
    }
    return '没能连上云端服务，检查一下网络或云上 API 地址。';
  }

  @Builder
  seal(size: number) {
    Stack() {
      Text('灵')
        .fontSize(size * 0.4)
        .fontWeight(FontWeight.Bold)
        .fontColor('#F6E3B4')
    }
    .width(size)
    .height(size)
    .borderRadius(size / 2)
    .backgroundColor(Theme.primary)
    .border({ width: 1, color: 'rgba(217, 164, 65, 0.7)' })
  }

  @Builder
  header() {
    Row() {
      Text('‹')
        .fontSize(30)
        .fontColor(Theme.textMain)
        .width(32)
        .textAlign(TextAlign.Start)
        .onClick(() => {
          router.back();
        })
      Column({ space: 2 }) {
        Text('黄河守护灵')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMain)
        Text('黄河河南段 · 文化问答')
          .fontSize(10)
          .fontColor(Theme.textSub)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      Text('云')
        .fontSize(12)
        .fontColor(Theme.primary)
        .width(48)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .padding({ left: 12, right: 16, top: 10, bottom: 8 })
    .backgroundColor(Theme.bg)
  }

  @Builder
  bubble(m: GuardianMsg) {
    if (m.role === 'user') {
      Row() {
        Blank()
        Text(m.content)
          .fontSize(13)
          .lineHeight(21)
          .fontColor(Color.White)
          .padding({ left: 12, right: 12, top: 9, bottom: 9 })
          .backgroundColor(Theme.primary)
          .borderRadius(12)
          .margin({ left: 52 })
      }
      .width('100%')
    } else {
      Row({ space: 8 }) {
        this.seal(30)
        Text(m.content)
          .fontSize(13)
          .lineHeight(21)
          .fontColor(Theme.textMain)
          .padding({ left: 12, right: 12, top: 9, bottom: 9 })
          .backgroundColor('#FFFDF6')
          .borderRadius(12)
          .border({ width: 1, color: Theme.divider })
          .margin({ right: 34 })
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
  }

  @Builder
  messageList() {
    List({ space: 12, scroller: this.scroller }) {
      ForEach(this.messages, (m: GuardianMsg, index: number) => {
        ListItem() {
          this.bubble(m)
        }
      }, (m: GuardianMsg, index: number) => index.toString() + m.role)
      if (this.sending) {
        ListItem() {
          Row({ space: 8 }) {
            this.seal(30)
            Text('正在翻阅档案…')
              .fontSize(12)
              .fontColor(Theme.textSub)
              .padding({ left: 12, right: 12, top: 9, bottom: 9 })
              .backgroundColor('#FFFDF6')
              .borderRadius(12)
              .border({ width: 1, color: Theme.divider })
          }
          .width('100%')
        }
      }
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
    .scrollBar(BarState.Off)
  }

  @Builder
  suggestions() {
    if (this.messages.length <= 1 && !this.sending) {
      Scroll() {
        Row({ space: 8 }) {
          ForEach(GuardianConfig.SUGGESTIONS, (s: string) => {
            Text(s)
              .fontSize(11)
              .fontColor(Theme.primary)
              .backgroundColor('#FFF7E8')
              .border({ width: 1, color: '#E6D3AE' })
              .padding({ left: 11, right: 11, top: 6, bottom: 6 })
              .borderRadius(13)
              .onClick(() => {
                this.send(s);
              })
          }, (s: string) => s)
        }
        .padding({ left: 16, right: 16 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ bottom: 6 })
    }
  }

  @Builder
  inputBar() {
    Row({ space: 8 }) {
      TextInput({ text: this.input, placeholder: '问一处遗址，或让我排一条路线…' })
        .layoutWeight(1)
        .height(40)
        .fontSize(13)
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: Theme.divider })
        .borderRadius(20)
        .padding({ left: 14, right: 14 })
        .onChange((v: string) => {
          this.input = v;
        })
        .onSubmit(() => {
          this.send();
        })
      Text(this.sending ? '…' : '发送')
        .fontSize(13)
        .fontColor(Color.White)
        .backgroundColor(Theme.primary)
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .borderRadius(20)
        .opacity(this.sending || this.input.trim().length === 0 ? 0.45 : 1)
        .onClick(() => {
          this.send();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 16 })
    .backgroundColor('#FBF5E8')
    .border({ width: { top: 1 }, color: Theme.divider })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.header()
        if (this.ready) {
          this.messageList()
        } else {
          Column() {
            LoadingProgress()
              .width(28)
              .height(28)
              .color(Theme.primary)
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }
        this.suggestions()
        this.inputBar()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .width('100%')
    .height('100%')
  }
}
