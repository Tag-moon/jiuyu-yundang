/**
 * 九曲云档 —— 文化资源数据仓库
 * 从 rawfile 预置数据加载，支持三维度筛选、关键词检索与关联推荐
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Heritage, FavoriteItem } from '../model/Models';
import { CloudApiService } from './CloudApiService';
import { GuardianConfig } from '../common/GuardianConfig';

/** 相似度排序的中间结构 */
interface ScoreItem {
  h: Heritage;
  score: number;
}

export class HeritageRepository {
  private static instance: HeritageRepository = new HeritageRepository();

  static getInstance(): HeritageRepository {
    return HeritageRepository.instance;
  }

  private all: Heritage[] = [];
  private loaded: boolean = false;

  /** 云优先加载档案；云上失败时回退 rawfile，保证离线可用 */
  async load(context: common.Context): Promise<void> {
    if (this.loaded) {
      return;
    }
    if (GuardianConfig.isCloudConfigured()) {
      try {
        const cloudItems: Heritage[] = await CloudApiService.getInstance().getHeritages();
        if (cloudItems.length > 0) {
          this.all = cloudItems;
          this.loaded = true;
          return;
        }
      } catch (e) {
        console.info('[九曲云档] 云端档案不可用，切换本地数据: ' + JSON.stringify(e as Error));
      }
    }
    try {
      const raw: Uint8Array = await context.resourceManager.getRawFileContent('heritages.json');
      const decoder = util.TextDecoder.create('utf-8');
      const text = decoder.decodeToString(raw);
      this.all = JSON.parse(text) as Heritage[];
      this.loaded = true;
    } catch (e) {
      console.error('[九曲云档] 文化数据加载失败: ' + JSON.stringify(e as Error));
    }
  }

  getAll(): Heritage[] {
    return this.all;
  }

  getById(id: string): Heritage | undefined {
    return this.all.find((h: Heritage) => h.id === id);
  }

  /** 关键词检索 + 年代/类型/城市 三维度筛选 */
  search(keyword: string, era: string, type: string, city: string): Heritage[] {
    const kw: string = keyword.trim().toLowerCase();
    return this.all.filter((h: Heritage) => {
      if (era !== '全部' && h.era !== era) {
        return false;
      }
      if (type !== '全部' && h.type !== type) {
        return false;
      }
      if (city !== '全部' && h.city !== city) {
        return false;
      }
      if (kw.length > 0) {
        const pool: string = (h.name + h.city + h.dynasty + h.type + h.summary + h.intro + h.keywords.join(' ')).toLowerCase();
        if (pool.indexOf(kw) < 0) {
          return false;
        }
      }
      return true;
    });
  }

  /**
   * 关联推荐：基于「同年代 > 同城市 > 同类型」相似度打分，
   * 返回与当前遗址最相关的一组遗址
   */
  recommendById(id: string, limit: number, preferredEras: string[] = [],
    preferredCities: string[] = []): Heritage[] {
    const cur: Heritage | undefined = this.getById(id);
    if (!cur) {
      return [];
    }
    const scored: ScoreItem[] = [];
    for (const h of this.all) {
      if (h.id === id) {
        continue;
      }
      // 内容相似度：同年代 > 同城市 > 同类型
      let s: number = 0;
      if (h.era === cur.era) {
        s += 3;
      }
      if (h.city === cur.city) {
        s += 2;
      }
      if (h.type === cur.type) {
        s += 1;
      }
      // 用户行为加权：偏好年代/城市（来自收藏与浏览历史）额外加分
      if (preferredEras.indexOf(h.era) >= 0) {
        s += 2;
      }
      if (preferredCities.indexOf(h.city) >= 0) {
        s += 1.5;
      }
      scored.push({ h: h, score: s });
    }
    scored.sort((a: ScoreItem, b: ScoreItem) => b.score - a.score);
    return scored.slice(0, limit).map((x: ScoreItem) => x.h);
  }

  /**
   * 基于用户行为的个性化推荐
   * 统计收藏/浏览过的年代与城市分布，作为偏好权重推荐可能感兴趣的遗址
   */
  recommendByProfile(favs: FavoriteItem[], limit: number): Heritage[] {
    const favIds: string[] = [];
    for (const f of favs) {
      favIds.push(f.itemId);
    }
    const eraCount: Map<string, number> = new Map();
    const cityCount: Map<string, number> = new Map();
    for (const f of favs) {
      if (f.itemEra.length > 0) {
        eraCount.set(f.itemEra, (eraCount.get(f.itemEra) ?? 0) + 1);
      }
      if (f.itemCity.length > 0) {
        cityCount.set(f.itemCity, (cityCount.get(f.itemCity) ?? 0) + 1);
      }
    }
    const scored: ScoreItem[] = [];
    for (const h of this.all) {
      if (favIds.indexOf(h.id) >= 0) {
        continue;
      }
      const s: number = (eraCount.get(h.era) ?? 0) * 3 + (cityCount.get(h.city) ?? 0) * 2;
      scored.push({ h: h, score: s });
    }
    scored.sort((a: ScoreItem, b: ScoreItem) => b.score - a.score);
    return scored.slice(0, limit).map((x: ScoreItem) => x.h);
  }

  /** 获取某一维度的候选值列表（用于动态筛选） */
  getEras(): string[] {
    return ['全部'].concat(this.unique(this.all.map((h: Heritage) => h.era)));
  }

  getTypes(): string[] {
    return ['全部'].concat(this.unique(this.all.map((h: Heritage) => h.type)));
  }

  getCities(): string[] {
    return ['全部'].concat(this.unique(this.all.map((h: Heritage) => h.city)));
  }

  private unique(list: string[]): string[] {
    const out: string[] = [];
    for (const item of list) {
      if (out.indexOf(item) < 0) {
        out.push(item);
      }
    }
    return out;
  }
}
