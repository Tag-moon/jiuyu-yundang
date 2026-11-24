/**
 * 九曲云档 —— 标签管理对话框（@CustomDialog）
 * 支持预置标签（待实地探访/已去过/研究资料）+ 自定义标签，实现个人文化主题分类
 */
import { DEFAULT_TAGS } from '../model/Models';
import { Theme, tagColor } from '../common/Theme';

@CustomDialog
export struct TagDialog {
  controller?: CustomDialogController;
  /** 父组件传入的当前已选标签（弹窗每次打开都会重建实例，aboutToAppear 中拷贝到 @State） */
  initialTags: string[] = [];
  @State selectedTags: string[] = [];
  @State customInput: string = '';
  onConfirm: (tags: string[]) => void = (tags: string[]) => {
  };
  /** 新建自定义标签时回调，父组件将其注册为全局栏目 */
  onNewTag: (tag: string) => void = (tag: string) => {
  };
  presetTags: string[] = DEFAULT_TAGS;

  aboutToAppear(): void {
    this.selectedTags = [...this.initialTags];
  }

  toggleTag(tag: string): void {
    if (this.selectedTags.includes(tag)) {
      this.selectedTags = this.selectedTags.filter((t: string) => t !== tag);
    } else {
      this.selectedTags = [...this.selectedTags, tag];
    }
  }

  addCustom(): void {
    const v = this.customInput.trim();
    if (v.length > 0 && !this.selectedTags.includes(v)) {
      this.selectedTags = [...this.selectedTags, v];
      // 同步注册为顶部标签栏目（已存在时存储层自动忽略）
      this.onNewTag(v);
      this.customInput = '';
    }
  }

  build() {
    Column({ space: 12 }) {
      Text('标签管理')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textMain)
      Text('将收藏分类管理，构建个人文化知识库')
        .fontSize(12)
        .fontColor(Theme.textSub)

      // 全部标签栏目（预置 + 自定义，自动换行）
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.presetTags, (tag: string) => {
          Text(tag)
            .fontSize(13)
            .fontColor(this.selectedTags.includes(tag) ? Color.White : Theme.textMain)
            .backgroundColor(this.selectedTags.includes(tag) ? tagColor(tag) : Theme.cardBg)
            .border({ width: 1, color: this.selectedTags.includes(tag) ? tagColor(tag) : Theme.divider })
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.toggleTag(tag);
            })
        }, (tag: string) => tag)
      }
      .width('100%')

      // 已选标签
      if (this.selectedTags.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.selectedTags, (tag: string) => {
            Row({ space: 4 }) {
              Text(tag)
                .fontSize(12)
                .fontColor(Theme.textMain)
              Text('✕')
                .fontSize(11)
                .fontColor(Theme.textSub)
                .onClick(() => {
                  this.toggleTag(tag);
                })
            }
            .backgroundColor('#F3E7D3')
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(12)
            .margin({ right: 8, bottom: 8 })
          }, (tag: string) => tag)
        }
        .width('100%')
      }

      // 自定义标签输入
      Row({ space: 8 }) {
        TextInput({ placeholder: '输入自定义标签，如：研学选题', text: this.customInput })
          .onChange((v: string) => {
            this.customInput = v;
          })
          .layoutWeight(1)
          .height(36)
          .fontSize(13)
          .backgroundColor(Theme.cardBg)
        Button('添加')
          .height(36)
          .fontSize(13)
          .backgroundColor(Theme.primary)
          .onClick(() => {
            this.addCustom();
          })
      }
      .width('100%')

      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(38)
          .fontSize(14)
          .backgroundColor('#EAE3D3')
          .fontColor(Theme.textMain)
          .onClick(() => {
            if (this.controller) {
              this.controller.close();
            }
          })
        Button('保存')
          .layoutWeight(1)
          .height(38)
          .fontSize(14)
          .backgroundColor(Theme.primary)
          .onClick(() => {
            this.onConfirm(this.selectedTags);
            if (this.controller) {
              this.controller.close();
            }
          })
      }
      .width('100%')
    }
    .padding(20)
    .backgroundColor(Theme.bg)
    .borderRadius(16)
  }
}
