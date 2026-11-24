/**
 * 九曲云档 —— 云端同步服务
 * 将本地收藏 / 笔记 / 足迹 / 墓碑推送到云上 API，
 * 再按「最新时间戳优先」把云端合并结果写回本地库。
 */
import { LocalStore } from './LocalStore';
import { CloudApiService, CloudSyncPayload } from './CloudApiService';
import { FavoriteItem, NoteItem, HistoryItem, SyncTombstone } from '../model/Models';

export class CloudSyncResult {
  favorites: number = 0;
  notes: number = 0;
  history: number = 0;
  tombstones: number = 0;
}

export class CloudSyncService {
  private static instance: CloudSyncService = new CloudSyncService();

  static getInstance(): CloudSyncService {
    return CloudSyncService.instance;
  }

  async sync(store: LocalStore, userId: string): Promise<CloudSyncResult> {
    const payload: CloudSyncPayload = {
      favorites: await store.getFavorites(),
      notes: await store.getAllNotes(),
      history: await store.getHistory(200),
      tombstones: await store.getTombstones()
    };
    const merged: CloudSyncPayload = await CloudApiService.getInstance().sync(userId, payload);
    for (const fav of merged.favorites) {
      await store.mergeFavorite(fav);
    }
    for (const note of merged.notes) {
      await store.mergeNote(note);
    }
    for (const item of merged.history) {
      await store.mergeHistoryItem(item);
    }
    const result: CloudSyncResult = new CloudSyncResult();
    result.favorites = merged.favorites.length;
    result.notes = merged.notes.length;
    result.history = merged.history.length;
    result.tombstones = merged.tombstones.length;
    return result;
  }
}
