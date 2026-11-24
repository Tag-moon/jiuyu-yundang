/**
 * 九曲云档 —— 用户会话
 * 手机号登录态持久化，用于标识个人档案；
 * 收藏 / 笔记 / 浏览足迹保存在本机，多设备同步需在「分布式数据同步」中开启。
 */
import { common } from '@kit.AbilityKit';
import { LocalStore } from './LocalStore';

const KEY_PHONE: string = 'session_phone';
const KEY_LOGIN_AT: string = 'session_login_at';

export class UserSession {
  private static instance: UserSession = new UserSession();

  static getInstance(): UserSession {
    return UserSession.instance;
  }

  private phone: string = '';
  private loginAt: number = 0;

  /** 启动时读取本地登录态（自动初始化本地库） */
  async load(context: common.Context): Promise<void> {
    const store: LocalStore = LocalStore.getInstance();
    await store.init(context);
    this.phone = await store.getMeta(KEY_PHONE);
    const raw: string = await store.getMeta(KEY_LOGIN_AT);
    this.loginAt = raw.length > 0 ? Number(raw) : 0;
  }

  isLoggedIn(): boolean {
    return this.phone.length === 11;
  }

  getPhone(): string {
    return this.phone;
  }

  getLoginAt(): number {
    return this.loginAt;
  }

  /** 脱敏手机号：138****1234 */
  maskedPhone(): string {
    if (this.phone.length !== 11) {
      return this.phone;
    }
    return this.phone.substring(0, 3) + '****' + this.phone.substring(7);
  }

  /** 登录成功：持久化账号与登录时间 */
  async login(phone: string): Promise<void> {
    this.phone = phone;
    this.loginAt = Date.now();
    const store: LocalStore = LocalStore.getInstance();
    await store.setMeta(KEY_PHONE, phone);
    await store.setMeta(KEY_LOGIN_AT, this.loginAt.toString());
  }

  /** 退出登录：清除本地登录态（收藏/笔记等个人数据保留在本机） */
  async logout(): Promise<void> {
    this.phone = '';
    this.loginAt = 0;
    const store: LocalStore = LocalStore.getInstance();
    await store.setMeta(KEY_PHONE, '');
    await store.setMeta(KEY_LOGIN_AT, '');
  }
}
