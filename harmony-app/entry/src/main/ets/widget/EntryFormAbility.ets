/**
 * EntryFormAbility.ets 桌面服务卡片扩展（九曲云档）
 * 卡片内容：每日一遗推荐 + 个人收藏 / 笔记统计
 * 点击卡片任意位置可拉起应用首页
 */
import { formBindingData, FormExtensionAbility, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { FormBridge } from '../datasource/FormBridge';

const FORM_ID_KEY = 'ohos.extra.param.key.form_identity';

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId = want.parameters !== undefined ? want.parameters[FORM_ID_KEY] as string : '';
    if (formId !== undefined && formId.length > 0) {
      FormBridge.init(this.context);
      FormBridge.register(formId);
      this.refreshCard(formId);
    }
    return formBindingData.createFormBindingData({
      'fav_count': 0,
      'note_count': 0,
      'site_name': '九曲云档',
      'site_city': '',
      'site_era': '',
      'site_summary': '河南段黄河文化数字档案'
    });
  }

  onCastToNormalForm(formId: string): void {
    this.refreshCard(formId);
  }

  onUpdateForm(formId: string): void {
    this.refreshCard(formId);
  }

  onRemoveForm(formId: string): void {
    FormBridge.init(this.context);
    FormBridge.unregister(formId);
  }

  private async refreshCard(formId: string): Promise<void> {
    try {
      FormBridge.init(this.context);
      const data = await FormBridge.collect();
      await formProvider.updateForm(formId, formBindingData.createFormBindingData({
        'fav_count': data.favCount,
        'note_count': data.noteCount,
        'site_name': data.siteName,
        'site_city': data.siteCity,
        'site_era': data.siteEra,
        'site_summary': data.siteSummary
      }));
    } catch (e) {
      // 卡片刷新失败时保留默认内容，不影响主应用
    }
  }
}
