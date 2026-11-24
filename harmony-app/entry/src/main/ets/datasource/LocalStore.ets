/**
 * 九曲云档 —— 本地数据存储（RelationalStore）
 * 收藏夹、笔记、标签的本地持久化；支持离线读写
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { FavoriteItem, NoteItem, HistoryItem, SyncTombstone, DEFAULT_TAGS, favoriteVersion } from '../model/Models';

const DB_NAME: string = 'yellowriver.db';
const KEY_TOMBSTONES: string = 'sync_tombstones';
const TOMBSTONE_LIMIT: number = 200;

const SQL_FAV: string = 'CREATE TABLE IF NOT EXISTS favorites (' +
  'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
  'item_id TEXT UNIQUE, item_name TEXT, item_era TEXT, item_type TEXT, ' +
  'item_city TEXT, item_cover TEXT, tags TEXT, created_at INTEGER, updated_at INTEGER)';

const SQL_NOTE: string = 'CREATE TABLE IF NOT EXISTS notes (' +
  'id INTEGER PRIMARY KEY AUTOINCREMENT, item_id TEXT, item_name TEXT, ' +
  'content TEXT, created_at INTEGER, updated_at INTEGER)';

const SQL_META: string = 'CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT)';

const SQL_HISTORY: string = 'CREATE TABLE IF NOT EXISTS history (' +
  'id INTEGER PRIMARY KEY AUTOINCREMENT, item_id TEXT UNIQUE, item_name TEXT, viewed_at INTEGER)';

export class LocalStore {
  private static instance: LocalStore = new LocalStore();

  static getInstance(): LocalStore {
    return LocalStore.instance;
  }

  private store: relationalStore.RdbStore | null = null;
  private ready: boolean = false;
  /** 本地数据变更回调：由入口注入，用于触发分布式自动推送（避免 LocalStore 反向依赖同步模块） */
  private changeListener: (() => void) | null = null;

  setChangeListener(cb: () => void): void {
    this.changeListener = cb;
  }

  private notifyChange(): void {
    if (this.changeListener !== null) {
      this.changeListener();
    }
  }

  /** 参数放宽为 common.Context，使桌面卡片进程也能读取收藏/笔记统计 */
  async init(context: common.Context): Promise<void> {
    if (this.ready) {
      return;
    }
    try {
      const config: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      this.store = await relationalStore.getRdbStore(context, config);
      await this.store.executeSql(SQL_FAV);
      await this.store.executeSql(SQL_NOTE);
      await this.store.executeSql(SQL_META);
      await this.store.executeSql(SQL_HISTORY);
      // 旧版本库升级：为收藏表补充 updated_at 列；列已存在时会报错，忽略即可
      try {
        await this.store.executeSql('ALTER TABLE favorites ADD COLUMN updated_at INTEGER DEFAULT 0');
      } catch (e) {
        console.info('[九曲云档] favorites.updated_at 列已存在，跳过迁移');
      }
      try {
        await this.store.executeSql(
          'UPDATE favorites SET updated_at = created_at WHERE updated_at IS NULL OR updated_at = 0');
      } catch (e) {
        console.error('[九曲云档] 初始化收藏版本号失败: ' + JSON.stringify(e as Error));
      }
      this.ready = true;
    } catch (e) {
      console.error('[九曲云档] 本地库初始化失败: ' + JSON.stringify(e as Error));
    }
  }

  // ---------- 收藏 ----------

  async isFavorite(itemId: string): Promise<boolean> {
    if (!this.store) {
      return false;
    }
    const pred = new relationalStore.RdbPredicates('favorites');
    pred.equalTo('item_id', itemId);
    const rs = await this.store.query(pred, ['id']);
    const found = rs.goToFirstRow();
    rs.close();
    return found;
  }

  async addFavorite(fav: FavoriteItem): Promise<void> {
    if (!this.store) {
      return;
    }
    const value: relationalStore.ValuesBucket = {
      'item_id': fav.itemId,
      'item_name': fav.itemName,
      'item_era': fav.itemEra,
      'item_type': fav.itemType,
      'item_city': fav.itemCity,
      'item_cover': fav.itemCover,
      'tags': fav.tags.join(','),
      'created_at': fav.createdAt,
      'updated_at': favoriteVersion(fav)
    };
    await this.store.insert('favorites', value);
    this.notifyChange();
  }

  /** 带时间戳写入收藏（用于分布式远端数据合并） */
  async addFavoriteWithTime(fav: FavoriteItem): Promise<void> {
    if (!this.store) {
      return;
    }
    const exists = await this.isFavorite(fav.itemId);
    if (!exists) {
      await this.addFavorite(fav);
    }
  }

  /** 按远端时间戳更新收藏（较新者胜；标签编辑等修改也会参与版本比较） */
  async mergeFavorite(fav: FavoriteItem): Promise<boolean> {
    if (!this.store) {
      return false;
    }
    const local = await this.getFavoriteByItemId(fav.itemId);
    if (local === null) {
      await this.addFavorite(fav);
      return true;
    }
    const remoteTs: number = favoriteVersion(fav);
    const localTs: number = favoriteVersion(local);
    if (remoteTs > localTs) {
      // 远端版本较新：采用远端标签，并同步写入远端版本号（不把版本号改成当前时间）
      await this.updateFavoriteTags(fav.itemId, fav.tags, false);
      const value: relationalStore.ValuesBucket = {
        'created_at': fav.createdAt,
        'updated_at': remoteTs
      };
      const pred = new relationalStore.RdbPredicates('favorites');
      pred.equalTo('item_id', fav.itemId);
      await this.store.update(value, pred);
      return true;
    }
    return false;
  }

  async removeFavorite(itemId: string): Promise<void> {
    if (!this.store) {
      return;
    }
    const pred = new relationalStore.RdbPredicates('favorites');
    pred.equalTo('item_id', itemId);
    await this.store.delete(pred);
    // 记录删除墓碑：分布式同步时其他设备据此移除，避免被远端旧数据重新加回
    await this.addTombstone('favorite', itemId, Date.now());
    this.notifyChange();
  }

  /** 消费远端删除墓碑时静默移除本地收藏：不再重复写墓碑，避免把删除时间戳越推越新 */
  async removeFavoriteQuiet(itemId: string): Promise<void> {
    if (!this.store) {
      return;
    }
    const pred = new relationalStore.RdbPredicates('favorites');
    pred.equalTo('item_id', itemId);
    await this.store.delete(pred);
  }

  /**
   * 更新收藏标签。
   * touch=true（本机编辑）时同时刷新 updated_at，使标签修改能作为新版本同步出去；
   * touch=false 用于合并远端数据，版本号由调用方按远端时间戳写入。
   */
  async updateFavoriteTags(itemId: string, tags: string[], touch: boolean = true): Promise<void> {
    if (!this.store) {
      return;
    }
    let value: relationalStore.ValuesBucket;
    if (touch) {
      value = { 'tags': tags.join(','), 'updated_at': Date.now() };
    } else {
      value = { 'tags': tags.join(',') };
    }
    const pred = new relationalStore.RdbPredicates('favorites');
    pred.equalTo('item_id', itemId);
    await this.store.update(value, pred);
    if (touch) {
      this.notifyChange();
    }
  }

  async getFavoriteByItemId(itemId: string): Promise<FavoriteItem | null> {
    if (!this.store) {
      return null;
    }
    const pred = new relationalStore.RdbPredicates('favorites');
    pred.equalTo('item_id', itemId);
    const rs = await this.store.query(pred);
    let fav: FavoriteItem | null = null;
    if (rs.goToFirstRow()) {
      fav = this.rowToFavorite(rs);
    }
    rs.close();
    return fav;
  }

  async getFavorites(): Promise<FavoriteItem[]> {
    if (!this.store) {
      return [];
    }
    const pred = new relationalStore.RdbPredicates('favorites');
    pred.orderByDesc('created_at');
    const rs = await this.store.query(pred);
    const list: FavoriteItem[] = [];
    while (rs.goToNextRow()) {
      list.push(this.rowToFavorite(rs));
    }
    rs.close();
    return list;
  }

  async getFavoriteCount(): Promise<number> {
    return (await this.getFavorites()).length;
  }

  // ---------- 标签栏目（预置 + 用户自定义，持久化在 meta 表） ----------

  /** 读取全部标签栏目；首次使用时初始化为预置标签 */
  async getAllTagList(): Promise<string[]> {
    const raw: string = await this.getMeta('all_tags');
    if (raw.length === 0) {
      await this.setMeta('all_tags', JSON.stringify(DEFAULT_TAGS));
      return [...DEFAULT_TAGS];
    }
    try {
      const list = JSON.parse(raw) as string[];
      return Array.isArray(list) ? list : [...DEFAULT_TAGS];
    } catch (e) {
      return [...DEFAULT_TAGS];
    }
  }

  /** 新增一个标签栏目（重名/空名返回 false） */
  async addTagColumn(tag: string): Promise<boolean> {
    const v: string = tag.trim();
    if (v.length === 0) {
      return false;
    }
    const list: string[] = await this.getAllTagList();
    if (list.includes(v)) {
      return false;
    }
    list.push(v);
    await this.setMeta('all_tags', JSON.stringify(list));
    return true;
  }

  /**
   * 删除标签栏目：从栏目列表移除，并把该标签从所有收藏项上摘除，
   * 收藏本身保留（这些遗址回到「未分类」，可在全部/未分类中继续查看）。
   */
  async removeTagColumn(tag: string): Promise<void> {
    console.info('[九曲云档] 开始删除栏目: ' + tag);
    const list: string[] = await this.getAllTagList();
    const next: string[] = list.filter((t: string) => t !== tag);
    await this.setMeta('all_tags', JSON.stringify(next));
    console.info('[九曲云档] 栏目列表已更新为: ' + JSON.stringify(next));

    await this.stripTagFromAllFavorites(tag);

    // 摘除后回读验证，仍有残留则强制重写一次，保证最终一致
    const after: FavoriteItem[] = await this.getFavorites();
    for (const f of after) {
      if (f.tags.includes(tag)) {
        console.error('[九曲云档] 检测到残留，强制从 ' + f.itemId + ' 摘除 ' + tag);
        await this.updateFavoriteTags(f.itemId, f.tags.filter((t: string) => t !== tag));
      }
    }
  }

  /** 把指定标签从所有收藏项上摘除（收藏保留） */
  private async stripTagFromAllFavorites(tag: string): Promise<void> {
    const favs: FavoriteItem[] = await this.getFavorites();
    for (const f of favs) {
      console.info('[九曲云档] 检查收藏 ' + f.itemId + '，当前标签=' + JSON.stringify(f.tags));
      if (f.tags.includes(tag)) {
        const rest: string[] = f.tags.filter((t: string) => t !== tag);
        await this.updateFavoriteTags(f.itemId, rest);
        console.info('[九曲云档] 已从 ' + f.itemId + ' 摘除，剩余标签=' + JSON.stringify(rest));
      }
    }
  }

  private rowToFavorite(rs: relationalStore.ResultSet): FavoriteItem {
    const fav = new FavoriteItem();
    fav.itemId = rs.getString(rs.getColumnIndex('item_id'));
    fav.itemName = rs.getString(rs.getColumnIndex('item_name'));
    fav.itemEra = rs.getString(rs.getColumnIndex('item_era'));
    fav.itemType = rs.getString(rs.getColumnIndex('item_type'));
    fav.itemCity = rs.getString(rs.getColumnIndex('item_city'));
    fav.itemCover = rs.getString(rs.getColumnIndex('item_cover'));
    const tags = rs.getString(rs.getColumnIndex('tags'));
    fav.tags = tags.length > 0 ? tags.split(',') : [];
    fav.createdAt = rs.getLong(rs.getColumnIndex('created_at'));
    const updatedIdx: number = rs.getColumnIndex('updated_at');
    fav.updatedAt = updatedIdx >= 0 ? rs.getLong(updatedIdx) : 0;
    if (fav.updatedAt <= 0) {
      fav.updatedAt = fav.createdAt;
    }
    return fav;
  }

  // ---------- 笔记 ----------

  async addNote(itemId: string, itemName: string, content: string): Promise<void> {
    if (!this.store) {
      return;
    }
    const now = Date.now();
    const value: relationalStore.ValuesBucket = {
      'item_id': itemId,
      'item_name': itemName,
      'content': content,
      'created_at': now,
      'updated_at': now
    };
    await this.store.insert('notes', value);
    this.notifyChange();
  }

  /**
   * 写入远端笔记：必须同时保留原 createdAt。
   * 跨设备以「itemId + createdAt」定位同一条逻辑笔记，若插入时把 createdAt 改成远端 updatedAt，
   * 下次同步会找不到这条笔记并重复插入。
   */
  async addNoteWithOrigin(itemId: string, itemName: string, content: string,
    createdAt: number, updatedAt: number): Promise<void> {
    if (!this.store) {
      return;
    }
    const value: relationalStore.ValuesBucket = {
      'item_id': itemId,
      'item_name': itemName,
      'content': content,
      'created_at': createdAt,
      'updated_at': updatedAt
    };
    await this.store.insert('notes', value);
  }

  async getNoteById(id: number): Promise<NoteItem | null> {
    if (!this.store) {
      return null;
    }
    const pred = new relationalStore.RdbPredicates('notes');
    pred.equalTo('id', id);
    const rs = await this.store.query(pred);
    let note: NoteItem | null = null;
    if (rs.goToFirstRow()) {
      note = this.rowToNote(rs);
    }
    rs.close();
    return note;
  }

  /** 更新笔记内容与时间戳（编辑与多端合并共用） */
  async updateNoteContent(id: number, content: string, ts: number): Promise<void> {
    if (!this.store) {
      return;
    }
    const value: relationalStore.ValuesBucket = {
      'content': content,
      'updated_at': ts
    };
    const pred = new relationalStore.RdbPredicates('notes');
    pred.equalTo('id', id);
    await this.store.update(value, pred);
  }

  /** 按「所属遗址 + 创建时间」定位同一条逻辑笔记（笔记 id 仅在本机自增，跨设备不可靠） */
  async findNoteByOrigin(itemId: string, createdAt: number): Promise<NoteItem | null> {
    if (!this.store) {
      return null;
    }
    const pred = new relationalStore.RdbPredicates('notes');
    pred.equalTo('item_id', itemId).and().equalTo('created_at', createdAt);
    const rs = await this.store.query(pred);
    let note: NoteItem | null = null;
    if (rs.goToFirstRow()) {
      note = this.rowToNote(rs);
    }
    rs.close();
    return note;
  }

  /**
   * 按远端时间戳合并笔记（较新者胜）。
   * 远端 note.id 是对方设备的自增主键，不能直接当作本机 id 使用：
   * 先按 (itemId, createdAt) 找同一条逻辑笔记，找不到再插入，避免重复插入或覆盖到别的笔记。
   */
  async mergeNote(note: NoteItem): Promise<boolean> {
    if (!this.store) {
      return false;
    }
    const local = await this.findNoteByOrigin(note.itemId, note.createdAt);
    if (local === null) {
      await this.addNoteWithOrigin(note.itemId, note.itemName, note.content,
        note.createdAt, note.updatedAt);
      return true;
    }
    if (note.updatedAt > local.updatedAt) {
      await this.updateNoteContent(local.id, note.content, note.updatedAt);
      return true;
    }
    return false;
  }

  async updateNote(id: number, content: string): Promise<void> {
    if (!this.store) {
      return;
    }
    const value: relationalStore.ValuesBucket = {
      'content': content,
      'updated_at': Date.now()
    };
    const pred = new relationalStore.RdbPredicates('notes');
    pred.equalTo('id', id);
    await this.store.update(value, pred);
    this.notifyChange();
  }

  async deleteNote(id: number): Promise<void> {
    if (!this.store) {
      return;
    }
    const note: NoteItem | null = await this.getNoteById(id);
    const pred = new relationalStore.RdbPredicates('notes');
    pred.equalTo('id', id);
    await this.store.delete(pred);
    // 笔记 id 为设备本地自增值，墓碑用「itemId|createdAt」标识同一条逻辑笔记
    if (note !== null) {
      await this.addTombstone('note', note.itemId + '|' + note.createdAt.toString(), Date.now());
    }
    this.notifyChange();
  }

  /** 消费远端删除墓碑时静默删除本地笔记（不再写墓碑） */
  async deleteNoteQuiet(id: number): Promise<void> {
    if (!this.store) {
      return;
    }
    const pred = new relationalStore.RdbPredicates('notes');
    pred.equalTo('id', id);
    await this.store.delete(pred);
  }

  async getNotesByItem(itemId: string): Promise<NoteItem[]> {
    if (!this.store) {
      return [];
    }
    const pred = new relationalStore.RdbPredicates('notes');
    pred.equalTo('item_id', itemId).orderByDesc('updated_at');
    const rs = await this.store.query(pred);
    const list: NoteItem[] = [];
    while (rs.goToNextRow()) {
      list.push(this.rowToNote(rs));
    }
    rs.close();
    return list;
  }

  async getAllNotes(): Promise<NoteItem[]> {
    if (!this.store) {
      return [];
    }
    const pred = new relationalStore.RdbPredicates('notes');
    pred.orderByDesc('updated_at');
    const rs = await this.store.query(pred);
    const list: NoteItem[] = [];
    while (rs.goToNextRow()) {
      list.push(this.rowToNote(rs));
    }
    rs.close();
    return list;
  }

  async getNoteCount(): Promise<number> {
    return (await this.getAllNotes()).length;
  }

  private rowToNote(rs: relationalStore.ResultSet): NoteItem {
    const note = new NoteItem();
    note.id = rs.getLong(rs.getColumnIndex('id'));
    note.itemId = rs.getString(rs.getColumnIndex('item_id'));
    note.itemName = rs.getString(rs.getColumnIndex('item_name'));
    note.content = rs.getString(rs.getColumnIndex('content'));
    note.createdAt = rs.getLong(rs.getColumnIndex('created_at'));
    note.updatedAt = rs.getLong(rs.getColumnIndex('updated_at'));
    return note;
  }

  // ---------- 浏览足迹（学习进度） ----------

  /**
   * 记录一次浏览。同一条目重复打开时只更新浏览时间，
   * 因此「已探索数量」统计的是去重后的条目数。
   */
  async recordView(itemId: string, itemName: string): Promise<void> {
    if (!this.store || itemId.length === 0) {
      return;
    }
    const pred = new relationalStore.RdbPredicates('history');
    pred.equalTo('item_id', itemId);
    const rs = await this.store.query(pred, ['item_id']);
    const exists = rs.goToFirstRow();
    rs.close();
    if (exists) {
      const value: relationalStore.ValuesBucket = { 'viewed_at': Date.now() };
      await this.store.update(value, pred);
    } else {
      const value: relationalStore.ValuesBucket = {
        'item_id': itemId,
        'item_name': itemName,
        'viewed_at': Date.now()
      };
      await this.store.insert('history', value);
    }
    this.notifyChange();
  }

  /** 最近浏览（按时间倒序，去重） */
  async getHistory(limit: number): Promise<HistoryItem[]> {
    let list: HistoryItem[] = [];
    if (!this.store) {
      return list;
    }
    const pred = new relationalStore.RdbPredicates('history');
    pred.orderByDesc('viewed_at').limitAs(limit);
    const rs = await this.store.query(pred);
    while (rs.goToNextRow()) {
      const it = new HistoryItem();
      it.itemId = rs.getString(rs.getColumnIndex('item_id'));
      it.itemName = rs.getString(rs.getColumnIndex('item_name'));
      it.viewedAt = rs.getLong(rs.getColumnIndex('viewed_at'));
      list.push(it);
    }
    rs.close();
    return list;
  }

  /** 合并远端浏览足迹：保留较新的浏览时间 */
  async mergeHistoryItem(item: HistoryItem): Promise<boolean> {
    if (!this.store) {
      return false;
    }
    const pred = new relationalStore.RdbPredicates('history');
    pred.equalTo('item_id', item.itemId);
    const rs = await this.store.query(pred, ['item_id', 'viewed_at']);
    let exists: boolean = false;
    let oldTs: number = 0;
    if (rs.goToFirstRow()) {
      exists = true;
      oldTs = rs.getLong(rs.getColumnIndex('viewed_at'));
    }
    rs.close();

    if (!exists) {
      const value: relationalStore.ValuesBucket = {
        'item_id': item.itemId,
        'item_name': item.itemName,
        'viewed_at': item.viewedAt
      };
      await this.store.insert('history', value);
      return true;
    }
    if (item.viewedAt > oldTs) {
      const value: relationalStore.ValuesBucket = {
        'item_name': item.itemName,
        'viewed_at': item.viewedAt
      };
      const updatePred = new relationalStore.RdbPredicates('history');
      updatePred.equalTo('item_id', item.itemId);
      await this.store.update(value, updatePred);
      return true;
    }
    return false;
  }

  /** 已浏览过的条目总数（学习进度分子） */
  async getViewedCount(): Promise<number> {
    if (!this.store) {
      return 0;
    }
    const rs = await this.store.querySql('SELECT COUNT(*) AS c FROM history', []);
    let n = 0;
    if (rs.goToFirstRow()) {
      n = rs.getLong(rs.getColumnIndex('c'));
    }
    rs.close();
    return n;
  }

  /** 清空浏览足迹；记录全局墓碑，避免其他设备同步时把旧足迹带回来 */
  async clearHistory(): Promise<void> {
    if (!this.store) {
      return;
    }
    const now: number = Date.now();
    const pred = new relationalStore.RdbPredicates('history');
    await this.store.delete(pred);
    await this.addTombstone('history', 'all', now);
    this.notifyChange();
  }

  /** 消费远端「清空足迹」墓碑：只删除该时间点之前的足迹，之后的新足迹保留 */
  async deleteHistoryBefore(ts: number): Promise<number> {
    if (!this.store) {
      return 0;
    }
    const pred = new relationalStore.RdbPredicates('history');
    pred.lessThanOrEqualTo('viewed_at', ts);
    return await this.store.delete(pred);
  }

  // ---------- 元数据（同步时间等） ----------

  async getMeta(key: string): Promise<string> {
    if (!this.store) {
      return '';
    }
    const pred = new relationalStore.RdbPredicates('meta');
    pred.equalTo('k', key);
    const rs = await this.store.query(pred, ['v']);
    let v = '';
    if (rs.goToFirstRow()) {
      v = rs.getString(rs.getColumnIndex('v'));
    }
    rs.close();
    return v;
  }

  async setMeta(key: string, value: string): Promise<void> {
    if (!this.store) {
      return;
    }
    const pred = new relationalStore.RdbPredicates('meta');
    pred.equalTo('k', key);
    const rs = await this.store.query(pred, ['k']);
    const exists = rs.goToFirstRow();
    rs.close();
    const bucket: relationalStore.ValuesBucket = { 'v': value };
    if (exists) {
      await this.store.update(bucket, pred);
    } else {
      const insertBucket: relationalStore.ValuesBucket = { 'k': key, 'v': value };
      await this.store.insert('meta', insertBucket);
    }
  }

  // ---------- 同步删除墓碑 ----------

  /** 读取本机删除墓碑（离线删除也会保留，下次同步时推送） */
  async getTombstones(): Promise<SyncTombstone[]> {
    const raw: string = await this.getMeta(KEY_TOMBSTONES);
    if (raw.length === 0) {
      return [];
    }
    try {
      const list = JSON.parse(raw) as SyncTombstone[];
      return list !== null && list !== undefined ? list : [];
    } catch (e) {
      return [];
    }
  }

  /** 记录/更新删除墓碑：同一对象只保留最新时间戳，最多保留 200 条 */
  async addTombstone(kind: string, id: string, ts: number): Promise<void> {
    const list: SyncTombstone[] = await this.getTombstones();
    const out: SyncTombstone[] = [];
    let found: boolean = false;
    for (const t of list) {
      if (t.kind === kind && t.id === id) {
        out.push({ kind: kind, id: id, ts: ts > t.ts ? ts : t.ts });
        found = true;
      } else {
        out.push(t);
      }
    }
    if (!found) {
      out.push({ kind: kind, id: id, ts: ts });
    }
    while (out.length > TOMBSTONE_LIMIT) {
      out.shift();
    }
    await this.setMeta(KEY_TOMBSTONES, JSON.stringify(out));
  }
}
