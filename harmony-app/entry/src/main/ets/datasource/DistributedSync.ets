/**
 * 九曲云档 —— 鸿蒙分布式数据服务封装
 * 基于 DistributedKVStore 实现多设备收藏 / 笔记 / 浏览足迹同步：
 *  - 应用层「最新时间戳版本优先」的冲突处理策略
 *  - 删除墓碑（tombstone）传播：一端删除后其他设备不会被旧数据重新加回
 *  - 同步状态可视化（在线设备数 / 最后同步时间 / 冲突记录数）
 *  - 不支持分布式的设备自动使用本地模式，不影响主功能
 */
import { distributedKVStore } from '@kit.ArkData';
import { abilityAccessCtrl, Permissions, common } from '@kit.AbilityKit';
import { distributedDeviceManager } from '@kit.DistributedServiceKit';
import { FavoriteItem, NoteItem, HistoryItem, SyncTombstone, favoriteVersion } from '../model/Models';
import { LocalStore } from './LocalStore';

const PERM_DISTRIBUTED: Permissions = 'ohos.permission.DISTRIBUTED_DATASYNC';
const BUNDLE_NAME: string = 'com.yellowriver.memory';
const STORE_NAME: string = 'yellowriver_sync';
const KEY_LAST_SYNC: string = 'sync_last_time';
/** 用户开关偏好：'0' 表示用户主动关闭，启动时不再自动恢复同步 */
const KEY_SYNC_ENABLED: string = 'sync_user_enabled';
const PREFIX_FAV: string = 'fav_';
const PREFIX_NOTE: string = 'note_';
const PREFIX_HIST: string = 'hist_';
const PREFIX_TOMB: string = 'tomb_';
const HISTORY_SYNC_LIMIT: number = 100;

/** 同步状态模型（供同步面板展示） */
export class SyncStatus {
  enabled: boolean = false;
  syncing: boolean = false;
  lastSyncTime: number = 0;
  conflictCount: number = 0;
  /** 在线设备数（含本机） */
  deviceCount: number = 1;
  /** 已发现的其他设备名称 */
  deviceNames: string[] = [];
  message: string = '未开启分布式同步（本地模式）';

  /** 生成快照：@State 赋值为同一对象引用时不会触发刷新，需返回新实例 */
  clone(): SyncStatus {
    const s: SyncStatus = new SyncStatus();
    s.enabled = this.enabled;
    s.syncing = this.syncing;
    s.lastSyncTime = this.lastSyncTime;
    s.conflictCount = this.conflictCount;
    s.deviceCount = this.deviceCount;
    s.deviceNames = [...this.deviceNames];
    s.message = this.message;
    return s;
  }
}

/** 一次完整同步的结果 */
export class SyncResult {
  pushed: number = 0;
  merged: number = 0;
  removed: number = 0;
  conflict: number = 0;
}

/** 同步负载：带时间戳的版本化数据 */
interface SyncPayload {
  ts: number;
  kind: string;
  data: string;
}

export class DistributedSync {
  private static instance: DistributedSync = new DistributedSync();

  static getInstance(): DistributedSync {
    return DistributedSync.instance;
  }

  private context: common.UIAbilityContext | null = null;
  private kvManager: distributedKVStore.KVManager | null = null;
  private kvStore: distributedKVStore.DeviceKVStore | null = null;
  private storeRef: LocalStore | null = null;
  private deviceManager: distributedDeviceManager.DeviceManager | null = null;
  private status: SyncStatus = new SyncStatus();
  private changeListener: (() => void) | null = null;
  private pulling: boolean = false;
  private pullQueued: boolean = false;
  private enableTask: Promise<boolean> | null = null;
  private syncTask: Promise<SyncResult> | null = null;
  private pushTimer: number = -1;
  private lastPullMerged: number = 0;
  private lastPullRemoved: number = 0;
  private lastPullConflict: number = 0;

  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /** 关联本地库，用于把远端数据合并写回 */
  setStore(store: LocalStore): void {
    this.storeRef = store;
  }

  getStatus(): SyncStatus {
    return this.status;
  }

  setChangeListener(cb: () => void): void {
    this.changeListener = cb;
  }

  private notify(): void {
    if (this.changeListener !== null) {
      this.changeListener();
    }
  }

  /**
   * 本机数据变更后的防抖推送：收藏 / 笔记 / 足迹改动后自动写入分布式库，
   * 无需等用户手动点「双向同步」；未开启同步时静默跳过。
   */
  schedulePush(): void {
    if (!this.status.enabled) {
      return;
    }
    if (this.pushTimer !== -1) {
      clearTimeout(this.pushTimer);
    }
    this.pushTimer = setTimeout(async () => {
      this.pushTimer = -1;
      try {
        await this.pushLocal();
        this.status.lastSyncTime = Date.now();
        this.notify();
      } catch (e) {
        console.error('[九曲云档] 自动推送失败: ' + JSON.stringify(e as Error));
      }
    }, 600);
  }

  /** 动态申请分布式数据同步权限 */
  async requestPermission(): Promise<boolean> {
    if (this.context === null) {
      return false;
    }
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(this.context,
        [PERM_DISTRIBUTED] as Permissions[]);
      return result.authResults.length > 0 && result.authResults[0] === 0;
    } catch (e) {
      console.error('[九曲云档] 申请分布式权限失败: ' + JSON.stringify(e as Error));
      return false;
    }
  }

  /** 权限是否已授予（不弹窗） */
  private async hasPermission(): Promise<boolean> {
    if (this.context === null) {
      return false;
    }
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const tokenId: number = this.context.applicationInfo.accessTokenId;
      const state = await atManager.checkAccessToken(tokenId, PERM_DISTRIBUTED);
      return state === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (e) {
      return false;
    }
  }

  /**
   * 自动同步入口（网络恢复 / 回到前台后自动同步）
   * 已授权则静默开启并完成一次双向同步；未授权时保持本地模式，不影响主功能。
   */
  async autoEnableIfPermitted(): Promise<boolean> {
    if (this.status.enabled) {
      await this.syncAll();
      return true;
    }
    // 用户主动关闭过同步：尊重该偏好，不自动恢复
    if (!(await this.userWantsSync())) {
      this.status.message = '已关闭分布式同步（本地模式）';
      return false;
    }
    const granted: boolean = await this.hasPermission();
    if (!granted) {
      this.status.message = '未开启分布式同步（本地模式）';
      return false;
    }
    const ok: boolean = await this.enable();
    if (ok) {
      await this.syncAll();
    }
    return ok;
  }

  /** 开启分布式同步（不可用时使用本地模式；并发调用复用同一任务） */
  async enable(): Promise<boolean> {
    if (this.status.enabled) {
      return true;
    }
    if (this.enableTask !== null) {
      return this.enableTask;
    }
    const task: Promise<boolean> = this.doEnable();
    this.enableTask = task;
    try {
      const ok: boolean = await task;
      return ok;
    } finally {
      this.enableTask = null;
    }
  }

  private async doEnable(): Promise<boolean> {
    if (this.context === null) {
      return false;
    }
    const granted: boolean = await this.requestPermission();
    if (!granted) {
      this.status.message = '未获得分布式数据同步权限，当前为本地模式';
      this.notify();
      return false;
    }
    try {
      const config: distributedKVStore.KVManagerConfig = {
        context: this.context,
        bundleName: BUNDLE_NAME
      };
      this.kvManager = distributedKVStore.createKVManager(config);
      const options: distributedKVStore.Options = {
        createIfMissing: true,
        encrypt: false,
        backup: false,
        autoSync: true,
        kvStoreType: distributedKVStore.KVStoreType.DEVICE_COLLABORATION,
        securityLevel: distributedKVStore.SecurityLevel.S1
      };
      const kv: distributedKVStore.DeviceKVStore =
        await this.kvManager.getKVStore<distributedKVStore.DeviceKVStore>(
          STORE_NAME, options);
      this.kvStore = kv;
      this.status.enabled = true;
      this.status.message = '已开启，等待多设备协同';
      if (this.storeRef !== null) {
        const raw: string = await this.storeRef.getMeta(KEY_LAST_SYNC);
        if (raw.length > 0) {
          this.status.lastSyncTime = Number(raw);
        }
        // 记录用户开启意图，后续启动 / 回到前台时按此恢复同步
        await this.storeRef.setMeta(KEY_SYNC_ENABLED, '1');
      }
      // 远端数据变化 → 自动拉取合并
      kv.on('dataChange', distributedKVStore.SubscribeType.SUBSCRIBE_TYPE_REMOTE,
        () => {
          this.pullAndMerge();
        });
      this.refreshDevices();
      this.notify();
      return true;
    } catch (e) {
      console.error('[九曲云档] 分布式库不可用，使用本地模式: ' + JSON.stringify(e as Error));
      this.status.enabled = false;
      this.status.message = '当前设备环境不支持分布式，当前为本地模式';
      this.notify();
      return false;
    }
  }

  /** 用户是否保留开启意图（未写入过偏好时视为允许自动恢复） */
  private async userWantsSync(): Promise<boolean> {
    if (this.storeRef === null) {
      return true;
    }
    const raw: string = await this.storeRef.getMeta(KEY_SYNC_ENABLED);
    return raw !== '0';
  }

  /**
   * 关闭分布式同步：停止自动推送、取消远端变更监听并释放分布式库句柄。
   * 同时写入关闭偏好，避免下次进入应用或回到前台时被自动重新开启。
   * 本地数据不做任何删除，关闭后仍可正常浏览、收藏与记笔记。
   */
  async disable(): Promise<void> {
    if (this.pushTimer !== -1) {
      clearTimeout(this.pushTimer);
      this.pushTimer = -1;
    }
    const kv: distributedKVStore.DeviceKVStore | null = this.kvStore;
    if (kv !== null) {
      try {
        kv.off('dataChange');
      } catch (e) {
        console.error('[九曲云档] 取消远端变更监听失败: ' + JSON.stringify(e as Error));
      }
    }
    this.kvStore = null;
    if (this.kvManager !== null) {
      try {
        await this.kvManager.closeKVStore(BUNDLE_NAME, STORE_NAME);
      } catch (e) {
        console.error('[九曲云档] 关闭分布式库失败: ' + JSON.stringify(e as Error));
      }
      this.kvManager = null;
    }
    this.status.enabled = false;
    this.status.syncing = false;
    this.status.conflictCount = 0;
    this.status.deviceCount = 1;
    this.status.deviceNames = [];
    this.status.message = '已关闭分布式同步（本地模式）';
    if (this.storeRef !== null) {
      await this.storeRef.setMeta(KEY_SYNC_ENABLED, '0');
    }
    this.notify();
  }

  private getDeviceManager(): distributedDeviceManager.DeviceManager | null {
    if (this.deviceManager !== null) {
      return this.deviceManager;
    }
    try {
      this.deviceManager = distributedDeviceManager.createDeviceManager(BUNDLE_NAME);
    } catch (e) {
      console.error('[九曲云档] 创建设备管理器失败: ' + JSON.stringify(e as Error));
      return null;
    }
    return this.deviceManager;
  }

  /** 已发现的其他设备（不含本机） */
  private availableDevices(): distributedDeviceManager.DeviceBasicInfo[] {
    const dm: distributedDeviceManager.DeviceManager | null = this.getDeviceManager();
    if (dm === null) {
      return [];
    }
    try {
      const list: distributedDeviceManager.DeviceBasicInfo[] = dm.getAvailableDeviceListSync();
      return list !== undefined && list !== null ? list : [];
    } catch (e) {
      console.error('[九曲云档] 获取在线设备失败: ' + JSON.stringify(e as Error));
      return [];
    }
  }

  /** 统计在线设备数（尽力而为，失败不影响主流程） */
  refreshDevices(): void {
    if (!this.status.enabled || this.context === null) {
      this.status.deviceCount = 1;
      this.status.deviceNames = [];
      return;
    }
    const list: distributedDeviceManager.DeviceBasicInfo[] = this.availableDevices();
    const names: string[] = [];
    for (const d of list) {
      if (d.deviceName !== undefined && d.deviceName.length > 0) {
        names.push(d.deviceName);
      }
    }
    this.status.deviceCount = list.length + 1;
    this.status.deviceNames = names;
  }

  /** 触发一次跨设备同步（手动同步时调用；数据到达后 dataChange 会再拉取） */
  private async syncWithDevices(kv: distributedKVStore.DeviceKVStore): Promise<void> {
    const ids: string[] = [];
    for (const d of this.availableDevices()) {
      const id: string = d.networkId !== undefined && d.networkId.length > 0 ? d.networkId : d.deviceId;
      if (id !== undefined && id.length > 0 && !ids.includes(id)) {
        ids.push(id);
      }
    }
    if (ids.length === 0) {
      return;
    }
    try {
      kv.sync(ids, distributedKVStore.SyncMode.PUSH_PULL);
      // 等待一次同步窗口，让远端数据落地后再拉取；即使超时也有 dataChange 兜底
      await new Promise<void>((resolve) => {
        setTimeout(() => {
          resolve();
        }, 800);
      });
    } catch (e) {
      console.error('[九曲云档] 触发跨设备同步失败: ' + JSON.stringify(e as Error));
    }
  }

  /**
   * 汇总本机与已发现设备的 KV 条目。
   * DEVICE_COLLABORATION 模式下 getEntries(prefix) 只返回本机数据，
   * 其他设备的数据需按 networkId 逐个读取，否则多设备同步只会看到自己写的数据。
   */
  private async collectEntries(kv: distributedKVStore.DeviceKVStore): Promise<distributedKVStore.Entry[]> {
    const all: distributedKVStore.Entry[] = [];
    const local: distributedKVStore.Entry[] = await kv.getEntries('');
    for (const e of local) {
      all.push(e);
    }
    for (const d of this.availableDevices()) {
      // networkId 是 DDS 跨设备同步使用的设备标识，deviceId 作为兼容兜底
      const ids: string[] = [];
      if (d.networkId !== undefined && d.networkId.length > 0) {
        ids.push(d.networkId);
      }
      if (d.deviceId !== undefined && d.deviceId.length > 0 && d.deviceId !== d.networkId) {
        ids.push(d.deviceId);
      }
      for (const id of ids) {
        try {
          const remote: distributedKVStore.Entry[] = await kv.getEntries(id, '');
          if (remote.length > 0) {
            for (const e of remote) {
              all.push(e);
            }
            break;
          }
        } catch (e) {
          console.error('[九曲云档] 读取设备 ' + id + ' 数据失败: ' + JSON.stringify(e as Error));
        }
      }
    }
    return all;
  }

  /**
   * 兼容 Entry.value 的两种形态：
   * API 26 声明为 { type: ValueType, value: ... }，部分运行时版本直接返回字符串。
   */
  private entryText(entry: distributedKVStore.Entry): string {
    return this.valueText(entry.value as string | distributedKVStore.Value);
  }

  private valueText(v: string | distributedKVStore.Value): string {
    if (typeof v === 'string') {
      return v;
    }
    if (v !== null && v !== undefined && typeof v.value === 'string') {
      return v.value;
    }
    return '';
  }

  /** 读取已存在条目的版本时间戳，用于推送前比较 */
  private payloadTs(raw: string): number {
    if (raw.length === 0) {
      return 0;
    }
    try {
      const payload: SyncPayload = JSON.parse(raw) as SyncPayload;
      if (payload !== null && payload !== undefined && typeof payload.ts === 'number') {
        return payload.ts;
      }
    } catch (e) {
      return 0;
    }
    return 0;
  }

  /** 写入一条带时间戳的版本化记录 */
  async put(key: string, ts: number, kind: string, data: string): Promise<void> {
    const kv: distributedKVStore.DeviceKVStore | null = this.kvStore;
    if (kv === null || !this.status.enabled) {
      return;
    }
    try {
      // 推送前比较版本：库里已有更新的记录时跳过，避免本机旧数据覆盖远端修改
      let current: string = '';
      try {
        current = this.valueText(await kv.get(key) as string | distributedKVStore.Value);
      } catch (e) {
        current = '';
      }
      if (this.payloadTs(current) > ts) {
        return;
      }
      const payload: SyncPayload = { ts: ts, kind: kind, data: data };
      await kv.put(key, JSON.stringify(payload));
      this.status.lastSyncTime = Date.now();
    } catch (e) {
      console.error('[九曲云档] 分布式写入失败: ' + JSON.stringify(e as Error));
    }
  }

  /** 笔记的分布式键：本地自增 id 跨设备会重复，改用「遗址 + 创建时间」逻辑标识 */
  private noteKey(note: NoteItem): string {
    return PREFIX_NOTE + note.itemId + '@' + note.createdAt.toString();
  }

  private tombKey(t: SyncTombstone): string {
    return PREFIX_TOMB + t.kind + '_' + t.id;
  }

  /** 全量推送本地收藏 / 笔记 / 足迹 / 删除墓碑 */
  async pushAll(favs: FavoriteItem[], notes: NoteItem[], history: HistoryItem[] = []): Promise<void> {
    if (!this.status.enabled) {
      return;
    }
    this.status.syncing = true;
    this.notify();
    for (const f of favs) {
      await this.put(PREFIX_FAV + f.itemId, favoriteVersion(f), 'favorite', JSON.stringify(f));
    }
    for (const n of notes) {
      await this.put(this.noteKey(n), n.updatedAt, 'note', JSON.stringify(n));
    }
    for (const h of history) {
      await this.put(PREFIX_HIST + h.itemId, h.viewedAt, 'history', JSON.stringify(h));
    }
    if (this.storeRef !== null) {
      const tombs: SyncTombstone[] = await this.storeRef.getTombstones();
      for (const t of tombs) {
        await this.put(this.tombKey(t), t.ts, 'tombstone', JSON.stringify(t));
      }
    }
    this.status.syncing = false;
    this.status.lastSyncTime = Date.now();
    this.notify();
  }

  /** 多端协同编辑：把本地笔记按最新时间戳推送，远端 dataChange 会自动合并 */
  async pushNotes(notes: NoteItem[]): Promise<void> {
    if (!this.status.enabled) {
      return;
    }
    this.status.syncing = true;
    this.notify();
    for (const n of notes) {
      await this.put(this.noteKey(n), n.updatedAt, 'note', JSON.stringify(n));
    }
    this.status.syncing = false;
    this.status.lastSyncTime = Date.now();
    this.notify();
  }

  /**
   * 完整双向同步：先拉取（把远端最新版本合并进本地）→ 再推送 → 最后再拉一次。
   * 顺序很重要：若先推送，本机旧数据会覆盖远端更新版本，导致对方的新修改丢失。
   */
  async syncAll(): Promise<SyncResult> {
    if (this.syncTask !== null) {
      return this.syncTask;
    }
    const task: Promise<SyncResult> = this.doSyncAll();
    this.syncTask = task;
    try {
      const res: SyncResult = await task;
      return res;
    } finally {
      this.syncTask = null;
    }
  }

  private async doSyncAll(): Promise<SyncResult> {
    const res: SyncResult = new SyncResult();
    if (!this.status.enabled) {
      return res;
    }
    this.status.syncing = true;
    this.notify();

    // 手动同步时先主动触发一次跨设备同步，避免只读到本机数据
    const kv: distributedKVStore.DeviceKVStore | null = this.kvStore;
    if (kv !== null) {
      await this.syncWithDevices(kv);
    }

    await this.pullAndMerge();
    res.merged += this.lastPullMerged;
    res.removed += this.lastPullRemoved;
    res.conflict = this.lastPullConflict;

    res.pushed = await this.pushLocal();

    await this.pullAndMerge();
    res.merged += this.lastPullMerged;
    res.removed += this.lastPullRemoved;
    if (this.lastPullConflict > res.conflict) {
      res.conflict = this.lastPullConflict;
    }

    // 同步过程中用户关闭了同步：保留关闭状态，不回写同步结果
    if (!this.status.enabled) {
      return res;
    }

    this.status.syncing = false;
    this.status.lastSyncTime = Date.now();
    this.status.conflictCount = res.conflict;
    if (res.pushed > 0 || res.merged > 0 || res.removed > 0) {
      this.status.message = '同步完成：推送 ' + res.pushed + ' 条，合并 ' + res.merged + ' 条' +
        (res.removed > 0 ? '，删除 ' + res.removed + ' 条' : '');
    } else {
      this.status.message = '已同步：数据一致';
    }
    if (this.storeRef !== null) {
      await this.storeRef.setMeta(KEY_LAST_SYNC, this.status.lastSyncTime.toString());
    }
    this.refreshDevices();
    this.notify();
    return res;
  }

  /** 退到后台等场景的快速推送：只推不拉，避免拉取等待拖慢生命周期回调 */
  async flushPush(): Promise<void> {
    if (this.pushTimer !== -1) {
      clearTimeout(this.pushTimer);
      this.pushTimer = -1;
    }
    if (!this.status.enabled || this.storeRef === null) {
      return;
    }
    try {
      await this.pushLocal();
      this.status.lastSyncTime = Date.now();
      this.notify();
    } catch (e) {
      console.error('[九曲云档] 后台推送失败: ' + JSON.stringify(e as Error));
    }
  }

  /** 推送本机全量数据（含墓碑），返回推送条数 */
  private async pushLocal(): Promise<number> {
    if (this.storeRef === null) {
      return 0;
    }
    const favs: FavoriteItem[] = await this.storeRef.getFavorites();
    const notes: NoteItem[] = await this.storeRef.getAllNotes();
    const history: HistoryItem[] = await this.storeRef.getHistory(HISTORY_SYNC_LIMIT);
    const tombs: SyncTombstone[] = await this.storeRef.getTombstones();
    let count: number = 0;
    for (const f of favs) {
      await this.put(PREFIX_FAV + f.itemId, favoriteVersion(f), 'favorite', JSON.stringify(f));
      count++;
    }
    for (const n of notes) {
      await this.put(this.noteKey(n), n.updatedAt, 'note', JSON.stringify(n));
      count++;
    }
    for (const h of history) {
      await this.put(PREFIX_HIST + h.itemId, h.viewedAt, 'history', JSON.stringify(h));
      count++;
    }
    for (const t of tombs) {
      await this.put(this.tombKey(t), t.ts, 'tombstone', JSON.stringify(t));
      count++;
    }
    return count;
  }

  /** 拉取远端数据并合并回本地（可重入保护：同步期间再次触发则排队执行一次） */
  async pullAndMerge(): Promise<void> {
    if (this.kvStore === null || !this.status.enabled || this.storeRef === null) {
      return;
    }
    if (this.pulling) {
      this.pullQueued = true;
      return;
    }
    this.pulling = true;
    try {
      await this.doPull();
    } catch (e) {
      console.error('[九曲云档] 拉取远端数据失败: ' + JSON.stringify(e as Error));
    }
    this.pulling = false;
    if (this.pullQueued) {
      this.pullQueued = false;
      await this.pullAndMerge();
    }
  }

  private async doPull(): Promise<void> {
    const kv: distributedKVStore.DeviceKVStore | null = this.kvStore;
    const store: LocalStore | null = this.storeRef;
    if (kv === null || store === null) {
      return;
    }
    // 本机条目 + 已发现设备的条目（DEVICE_COLLABORATION 下需按设备读取）
    const entries: distributedKVStore.Entry[] = await this.collectEntries(kv);

    // 1. 汇总远端删除墓碑（同一对象取最大时间戳）
    const tombs: Map<string, SyncTombstone> = new Map<string, SyncTombstone>();
    for (const entry of entries) {
      const key: string = entry.key;
      const raw: string = this.entryText(entry);
      if (!key || !raw || !key.startsWith(PREFIX_TOMB)) {
        continue;
      }
      try {
        const payload: SyncPayload = JSON.parse(raw) as SyncPayload;
        if (payload === null || payload === undefined || !payload.data) {
          continue;
        }
        const t: SyncTombstone = JSON.parse(payload.data) as SyncTombstone;
        if (t === null || t === undefined || t.kind === undefined || t.id === undefined) {
          continue;
        }
        const k: string = t.kind + '_' + t.id;
        const old: SyncTombstone | undefined = tombs.get(k);
        if (old === undefined || t.ts > old.ts) {
          tombs.set(k, t);
        }
      } catch (e) {
        console.error('[九曲云档] 远端墓碑解析失败: ' + JSON.stringify(e as Error));
      }
    }

    // 2. 合并本机墓碑：本机刚删除、尚未推送出去的条目，不能被远端旧数据重新加回
    const localTombs: SyncTombstone[] = await store.getTombstones();
    for (const t of localTombs) {
      const k: string = t.kind + '_' + t.id;
      const old: SyncTombstone | undefined = tombs.get(k);
      if (old === undefined || t.ts > old.ts) {
        tombs.set(k, t);
      }
    }

    // 3. 应用墓碑：本地条目若不比删除动作更新，则移除
    const tombList: SyncTombstone[] = [];
    tombs.forEach((t: SyncTombstone) => {
      tombList.push(t);
    });
    let removed: number = 0;
    for (const t of tombList) {
      if (t.kind === 'favorite') {
        const local: FavoriteItem | null = await store.getFavoriteByItemId(t.id);
        if (local !== null && favoriteVersion(local) <= t.ts) {
          await store.removeFavoriteQuiet(t.id);
          removed++;
        }
      } else if (t.kind === 'note') {
        const sep: number = t.id.lastIndexOf('|');
        if (sep <= 0) {
          continue;
        }
        const itemId: string = t.id.substring(0, sep);
        const created: number = Number(t.id.substring(sep + 1));
        if (!Number.isFinite(created)) {
          continue;
        }
        const local: NoteItem | null = await store.findNoteByOrigin(itemId, created);
        if (local !== null && local.updatedAt <= t.ts) {
          await store.deleteNoteQuiet(local.id);
          removed++;
        }
      } else if (t.kind === 'history') {
        removed += await store.deleteHistoryBefore(t.ts);
      }
    }

    // 4. 逐条合并收藏 / 笔记 / 足迹；已被墓碑删除的条目不再回加
    let merged: number = 0;
    let skipped: number = 0;
    let conflict: number = 0;
    for (const entry of entries) {
      const key: string = entry.key;
      const raw: string = this.entryText(entry);
      if (!key || !raw || key.startsWith(PREFIX_TOMB)) {
        continue;
      }
      try {
        const payload: SyncPayload = JSON.parse(raw) as SyncPayload;
        if (payload === null || payload === undefined || !payload.data) {
          continue;
        }
        if (key.startsWith(PREFIX_FAV)) {
          const fav: FavoriteItem = JSON.parse(payload.data) as FavoriteItem;
          if (fav === null || fav === undefined || fav.itemId === undefined || fav.itemId.length === 0) {
            continue;
          }
          const tomb: SyncTombstone | undefined = tombs.get('favorite_' + fav.itemId);
          if (tomb !== undefined && tomb.ts >= favoriteVersion(fav)) {
            const local: FavoriteItem | null = await store.getFavoriteByItemId(fav.itemId);
            if (local !== null && favoriteVersion(local) <= tomb.ts) {
              await store.removeFavoriteQuiet(fav.itemId);
              removed++;
            }
            continue;
          }
          const local: FavoriteItem | null = await store.getFavoriteByItemId(fav.itemId);
          // 冲突定义：两端同时存在同一条目且版本不一致 → 以最新时间戳为准
          if (local !== null && favoriteVersion(local) !== favoriteVersion(fav)) {
            conflict++;
          }
          const applied: boolean = await store.mergeFavorite(fav);
          if (applied) {
            merged++;
          } else {
            skipped++;
          }
        } else if (key.startsWith(PREFIX_NOTE)) {
          const note: NoteItem = JSON.parse(payload.data) as NoteItem;
          if (note === null || note === undefined || note.itemId === undefined) {
            continue;
          }
          const tomb: SyncTombstone | undefined =
            tombs.get('note_' + note.itemId + '|' + note.createdAt.toString());
          if (tomb !== undefined && tomb.ts >= note.updatedAt) {
            const local: NoteItem | null = await store.findNoteByOrigin(note.itemId, note.createdAt);
            if (local !== null && local.updatedAt <= tomb.ts) {
              await store.deleteNoteQuiet(local.id);
              removed++;
            }
            continue;
          }
          const local: NoteItem | null = await store.findNoteByOrigin(note.itemId, note.createdAt);
          if (local !== null && local.updatedAt !== note.updatedAt) {
            conflict++;
          }
          const applied: boolean = await store.mergeNote(note);
          if (applied) {
            merged++;
          } else {
            skipped++;
          }
        } else if (key.startsWith(PREFIX_HIST)) {
          const h: HistoryItem = JSON.parse(payload.data) as HistoryItem;
          if (h === null || h === undefined || h.itemId === undefined) {
            continue;
          }
          // 已执行「清空足迹」的旧记录不再合并回来
          const clearTomb: SyncTombstone | undefined = tombs.get('history_all');
          if (clearTomb !== undefined && h.viewedAt <= clearTomb.ts) {
            continue;
          }
          const applied: boolean = await store.mergeHistoryItem(h);
          if (applied) {
            merged++;
          } else {
            skipped++;
          }
        }
      } catch (e) {
        console.error('[九曲云档] 远端单条数据解析失败: ' + JSON.stringify(e as Error));
      }
    }

    this.lastPullMerged = merged;
    this.lastPullRemoved = removed;
    this.lastPullConflict = conflict;
    // 拉取期间用户关闭了同步：不再回写状态与时间
    if (!this.status.enabled) {
      return;
    }
    this.status.conflictCount = conflict;
    this.status.lastSyncTime = Date.now();
    if (merged > 0 || removed > 0) {
      this.status.message = '已同步：合并 ' + merged + ' 条' +
        (removed > 0 ? '，删除 ' + removed + ' 条' : '') +
        (conflict > 0 ? '，按最新时间戳处理冲突 ' + conflict + ' 条' : '');
    } else if (skipped > 0) {
      this.status.message = '已同步：本地均为最新版本（跳过 ' + skipped + ' 条）';
    } else {
      this.status.message = '已同步：数据一致';
    }
    await store.setMeta(KEY_LAST_SYNC, this.status.lastSyncTime.toString());
    this.notify();
  }
}
