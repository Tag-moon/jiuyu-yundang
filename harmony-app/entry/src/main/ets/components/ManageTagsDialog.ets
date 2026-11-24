/**
 * 九曲云档 —— 标签栏目管理对话框（@CustomDialog）
 * 系统栏目（全部 / 文物 / 未分类）固定不可删除；
 * 预置与自定义标签栏目可随时新增、删除；删除栏目后其下遗址回到「未分类」，收藏不丢失。
 */
import { Theme } from '../common/Theme';

@CustomDialog
export struct ManageTagsDialog {
  controller?: CustomDialogController;
  /** 父组件传入的当前标签栏目 */
  tagList: string[] = [];
  onAdd: (tag: string) => void = (tag: string) => {
  };
  onRemove: (tag: string) => void = (tag: string) => {
  };

  @State tags: string[] = [];
  @State input: string = '';
  private systemTags: string[] = ['全部', '文物', '未分类'];

  aboutToAppear(): void {
    this.tags = [...this.tagList];
  }

  isSystem(tag: string): boolean {
    return this.systemTags.includes(tag);
  }

  doAdd(): void {
    const v: string = this.input.trim();
    if (v.length === 0 || this.isSystem(v) || this.tags.includes(v)) {
      return;
    }
    this.onAdd(v);
    this.tags = [...this.tags, v];
    this.input = '';
  }

  doRemove(tag: string): void {
    this.onRemove(tag);
    this.tags = this.tags.filter((t: string) => t !== tag);
  }

  build() {
    Column({ space: 12 }) {
      Text('标签栏目管理')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textMain)
      Text('系统栏目不可删除；删除其他栏目后，其下遗址将回到「未分类」，收藏不会丢失')
        .fontSize(11)
        .fontColor(Theme.textSub)

      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.systemTags, (tag: string) => {
            Row() {
              Text(tag)
                .fontSize(13)
                .fontColor(Theme.textSub)
                .layoutWeight(1)
              Text('系统')
                .fontSize(10)
                .fontColor(Theme.textSub)
                .backgroundColor('#F1ECE1')
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                .borderRadius(8)
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 9, bottom: 9 })
            .backgroundColor(Theme.cardBg)
            .borderRadius(10)
          }, (tag: string) => 'sys_' + tag)

          ForEach(this.tags, (tag: string) => {
            Row() {
              Text(tag)
                .fontSize(13)
                .fontColor(Theme.textMain)
                .layoutWeight(1)
              Text('✕ 删除')
                .fontSize(11)
                .fontColor(Theme.danger)
                .onClick(() => {
                  this.doRemove(tag);
                })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 9, bottom: 9 })
            .backgroundColor('#FBF6EA')
            .borderRadius(10)
          }, (tag: string) => 'tag_' + tag)
        }
        .width('100%')
      }
      .constraintSize({ maxHeight: 280 })
      .scrollBar(BarState.Auto)
      .width('100%')

      Row({ space: 8 }) {
        TextInput({ placeholder: '新增标签栏目，如：研学选题', text: this.input })
          .onChange((v: string) => {
            this.input = v;
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
            this.doAdd();
          })
      }
      .width('100%')

      Button('完成')
        .width('100%')
        .height(38)
        .fontSize(14)
        .backgroundColor(Theme.primary)
        .onClick(() => {
          if (this.controller) {
            this.controller.close();
          }
        })
    }
    .padding(20)
    .backgroundColor(Theme.bg)
    .borderRadius(16)
  }
}
