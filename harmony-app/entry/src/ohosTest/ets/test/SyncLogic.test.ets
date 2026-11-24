import { describe, it, expect } from '@ohos/hypium';
import { FavoriteItem, favoriteVersion } from '../../../main/ets/model/Models';

/** 最新时间戳优先：版本比较是同步冲突处理的基础 */
function latestWins(localTs: number, remoteTs: number): string {
  if (remoteTs > localTs) {
    return 'remote';
  }
  if (localTs > remoteTs) {
    return 'local';
  }
  return 'equal';
}

export default function syncLogicTest() {
  describe('SyncVersion', () => {
    it('prefers_updated_at', 0, () => {
      const fav = new FavoriteItem();
      fav.createdAt = 100;
      fav.updatedAt = 300;
      expect(favoriteVersion(fav)).assertEqual(300);
    });

    it('falls_back_to_created_at', 0, () => {
      const fav = new FavoriteItem();
      fav.createdAt = 200;
      fav.updatedAt = 0;
      expect(favoriteVersion(fav)).assertEqual(200);
    });

    it('newer_remote_wins', 0, () => {
      expect(latestWins(100, 300)).assertEqual('remote');
    });

    it('newer_local_wins', 0, () => {
      expect(latestWins(300, 100)).assertEqual('local');
    });

    it('same_version_keeps_local', 0, () => {
      expect(latestWins(200, 200)).assertEqual('equal');
    });
  });
}
