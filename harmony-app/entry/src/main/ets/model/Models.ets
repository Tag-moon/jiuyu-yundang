/**
 * 九曲云档·黄河文化分布式数字档案 —— 数据模型定义
 */

/** 历史事件 */
export interface EventItem {
  time: string;
  title: string;
  desc: string;
}

/** 相关诗词/文献名句 */
export interface PoemItem {
  title: string;
  author: string;
  content: string;
}

/** 现代文旅信息 */
export interface TourismItem {
  address: string;
  openTime: string;
  ticket: string;
  tips: string;
}

/** 代表性可收藏文物条目 */
export interface RelicItem {
  name: string;
  desc: string;
}

/** 文化遗址条目（预置数据） */
export interface Heritage {
  id: string;
  name: string;
  city: string;
  era: string;
  type: string;
  typeDesc: string;
  dynasty: string;
  cover: string;
  /** rawfile 图片文件名（如 yinxu.jpg）；为空时 UI 自动回退为年代配色封面 */
  image: string;
  summary: string;
  intro: string;
  archaeology: string;
  /** 代表性文物条目，可单独收藏 */
  relics: RelicItem[];
  events: EventItem[];
  poems: PoemItem[];
  tourism: TourismItem;
  keywords: string[];
}

/** 个人收藏条目（持久化） */
export class FavoriteItem {
  itemId: string = '';
  itemName: string = '';
  itemEra: string = '';
  itemType: string = '';
  itemCity: string = '';
  itemCover: string = '';
  tags: string[] = [];
  createdAt: number = 0;
  /** 最后修改时间（标签编辑等），用于分布式同步版本比较；旧数据为 0 时回退 createdAt */
  updatedAt: number = 0;
}

/** 收藏条目的同步版本号：优先取最后修改时间，旧数据回退到收藏时间 */
export function favoriteVersion(fav: FavoriteItem): number {
  return fav.updatedAt > 0 ? fav.updatedAt : fav.createdAt;
}

/** 浏览足迹条目（学习进度统计用，持久化） */
export class HistoryItem {
  itemId: string = '';
  itemName: string = '';
  viewedAt: number = 0;
}

/** 个人笔记条目（持久化） */
export class NoteItem {
  id: number = 0;
  itemId: string = '';
  itemName: string = '';
  content: string = '';
  createdAt: number = 0;
  updatedAt: number = 0;
}

/**
 * 同步删除墓碑：记录本机删除动作，避免其他设备把已删除条目重新合并回来。
 * favorite 的 id 为 itemId；note 的 id 为「itemId|createdAt」，用于跨设备定位同一条逻辑笔记。
 */
export interface SyncTombstone {
  kind: string;
  id: string;
  ts: number;
}

/** 预置收藏标签 */
export const DEFAULT_TAGS: string[] = ['待实地探访', '已去过', '研究资料'];

/** 年代筛选维度（仰韶→龙山→夏商→周→汉唐→宋） */
export const ERA_LIST: string[] = ['全部', '仰韶', '龙山', '夏商', '周', '汉唐', '宋'];

/** 遗址类型筛选维度 */
export const TYPE_LIST: string[] = ['全部', '都城遗址', '墓葬群', '窑址', '古建筑'];

/** 沿线城市筛选维度：核心城市优先，其他城市随后 */
export const CITY_LIST: string[] = ['全部', '三门峡', '洛阳', '郑州', '开封', '濮阳', '济源', '焦作',
  '新乡', '安阳'];

/** 空遗址条目（用于 @State 初始占位） */
export const EMPTY_HERITAGE: Heritage = {
  id: '',
  name: '加载中…',
  city: '',
  era: '仰韶',
  type: '',
  typeDesc: '',
  dynasty: '',
  cover: '🏺',
  image: '',
  summary: '',
  intro: '',
  archaeology: '',
  relics: [],
  events: [],
  poems: [],
  tourism: { address: '', openTime: '', ticket: '', tips: '' },
  keywords: []
};

/** 文物条目在收藏表中的 itemId 规则：<遗址id>#<序号>，复用同一张收藏表 */
export function relicKey(heritageId: string, index: number): string {
  return heritageId + '#' + index;
}

/** 判断某个收藏 id 是否为文物条目 */
export function isRelicKey(itemId: string): boolean {
  return itemId.indexOf('#') >= 0;
}

/** 从文物 itemId 解析出遗址 id */
export function relicHeritageId(itemId: string): string {
  const i = itemId.indexOf('#');
  return i >= 0 ? itemId.substring(0, i) : itemId;
}

/** 时间戳格式化为可读时间 */
export function formatTime(ts: number): string {
  const d = new Date(ts);
  const pad = (n: number): string => (n < 10 ? '0' + n : '' + n);
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
    ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
}

/** 备份版本 */
export const BACKUP_VERSION: number = 2;

/** 备份文件结构 */
export interface BackupPayload {
  app: string;
  version: number;
  exportedAt: number;
  favorites: FavoriteItem[];
  notes: NoteItem[];
  history: HistoryItem[];
}

/** 导出收藏、笔记、浏览足迹为 JSON 备份文本 */
export function buildBackupText(favs: FavoriteItem[], notes: NoteItem[],
  history: HistoryItem[]): string {
  const payload: BackupPayload = {
    app: '九曲云档',
    version: BACKUP_VERSION,
    exportedAt: Date.now(),
    favorites: favs,
    notes: notes,
    history: history
  };
  return JSON.stringify(payload);
}

/** 解析备份文本 */
export function parseBackupText(text: string): BackupPayload | null {
  try {
    const obj = JSON.parse(text) as BackupPayload;
    if (obj === null || obj === undefined) {
      return null;
    }
    if (obj.favorites === undefined || obj.notes === undefined) {
      return null;
    }
    obj.version = obj.version !== undefined ? obj.version : 1;
    obj.history = obj.history !== undefined ? obj.history : [];
    return obj;
  } catch (e) {
    return null;
  }
}
