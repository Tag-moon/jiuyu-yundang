/**
 * FormBridge.ets —— 桌面服务卡片数据桥（九曲云档）
 *
 * 卡片进程默认只在「添加卡片 / 系统定时更新」时拉数据，
 * 用户在 App 内新增收藏或笔记后桌面数字会滞后。
 * 本桥负责：
 *  1. 登记 / 注销已添加到桌面的卡片 formId（持久化到 Preferences）
 *  2. 在收藏、笔记、同步等数据变更后，主动把最新统计推送到全部卡片
 *  3. 按日期稳定轮换「每日一遗」推荐，保证同一天多次打开结果一致
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { Heritage } from '../model/Models';
import { HeritageRepository } from './HeritageRepository';
import { LocalStore } from './LocalStore';

const PREF_NAME: string = 'yr_form_pref';
const KEY_FORM_IDS: string = 'form_ids';

/** 卡片展示数据 */
export interface CardData {
  favCount: number;
  noteCount: number;
  siteName: string;
  siteCity: string;
  siteEra: string;
  siteSummary: string;
}

export class FormBridge {
  private static ctx: common.Context | null = null;

  static init(context: common.Context): void {
    FormBridge.ctx = context;
  }

  private static async getPref(): Promise<preferences.Preferences | null> {
    if (FormBridge.ctx === null) {
      return null;
    }
    return await preferences.getPreferences(FormBridge.ctx, PREF_NAME);
  }

  static async getFormIds(): Promise<string[]> {
    const pref = await FormBridge.getPref();
    if (pref === null) {
      return [];
    }
    const raw = pref.getSync(KEY_FORM_IDS, '[]') as string;
    let ids: string[] = [];
    try {
      const arr = JSON.parse(raw) as string[];
      for (let i = 0; i < arr.length; i++) {
        if (arr[i].length > 0) {
          ids.push(arr[i]);
        }
      }
    } catch (e) {
      ids = [];
    }
    return ids;
  }

  private static async saveFormIds(ids: string[]): Promise<void> {
    const pref = await FormBridge.getPref();
    if (pref === null) {
      return;
    }
    await pref.putSync(KEY_FORM_IDS, JSON.stringify(ids));
    await pref.flush();
  }

  static async register(formId: string): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    const ids = await FormBridge.getFormIds();
    if (ids.indexOf(formId) >= 0) {
      return;
    }
    ids.push(formId);
    await FormBridge.saveFormIds(ids);
  }

  static async unregister(formId: string): Promise<void> {
    const ids = await FormBridge.getFormIds();
    const next: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      if (ids[i] !== formId) {
        next.push(ids[i]);
      }
    }
    if (next.length !== ids.length) {
      await FormBridge.saveFormIds(next);
    }
  }

  /**
   * 按日期稳定轮换推荐一处遗址。
   * 用「一年中的第几天」对遗址总数取模，保证同一天刷新结果一致。
   */
  private static pickDaily(all: Heritage[]): Heritage | null {
    if (all.length === 0) {
      return null;
    }
    const now = new Date();
    const start = new Date(now.getFullYear(), 0, 0);
    const dayOfYear = Math.floor((now.getTime() - start.getTime()) / 86400000);
    const idx = dayOfYear % all.length;
    return all[idx];
  }

  /** 采集当前卡片应展示的数据（读 rawfile 失败时仅展示统计） */
  static async collect(): Promise<CardData> {
    const data: CardData = {
      favCount: 0,
      noteCount: 0,
      siteName: '九曲云档',
      siteCity: '',
      siteEra: '',
      siteSummary: '河南段黄河文化数字档案'
    };
    try {
      const repo = HeritageRepository.getInstance();
      await repo.load(FormBridge.ctx as common.Context);
      const all = repo.getAll();
      const pick = FormBridge.pickDaily(all);
      if (pick !== null) {
        data.siteName = pick.name;
        data.siteCity = pick.city;
        data.siteEra = pick.era;
        data.siteSummary = pick.summary.length > 0 ? pick.summary : pick.dynasty;
      }
    } catch (e) {
      // rawfile 读取失败时保留默认文案，不影响卡片其它内容
    }
    try {
      const store = LocalStore.getInstance();
      await store.init(FormBridge.ctx as common.UIAbilityContext);
      data.favCount = await store.getFavoriteCount();
      data.noteCount = await store.getNoteCount();
    } catch (e) {
      // 本地库不可用时统计保持为 0
    }
    return data;
  }

  /** 主动刷新全部已登记卡片 */
  static async refreshAll(): Promise<void> {
    const ids = await FormBridge.getFormIds();
    if (ids.length === 0) {
      return;
    }
    const data = await FormBridge.collect();
    const binding = formBindingData.createFormBindingData({
      'fav_count': data.favCount,
      'note_count': data.noteCount,
      'site_name': data.siteName,
      'site_city': data.siteCity,
      'site_era': data.siteEra,
      'site_summary': data.siteSummary
    });
    const alive: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      try {
        await formProvider.updateForm(ids[i], binding);
        alive.push(ids[i]);
      } catch (e) {
        // 卡片已被移除：从登记表中剔除
      }
    }
    if (alive.length !== ids.length) {
      await FormBridge.saveFormIds(alive);
    }
  }
}
