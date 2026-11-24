/**
 * 九曲云档 —— 全局主题样式常量
 * 黄河文化视觉基调：米黄底、赭石棕、鎏金点缀
 */
export class Theme {
  /** 主色：赭石棕 */
  static readonly primary: string = '#8A5A2B';
  /** 主色浅 */
  static readonly primaryLight: string = '#C89B6D';
  /** 点缀金 */
  static readonly accent: string = '#D9A441';
  /** 页面背景：米黄 */
  static readonly bg: string = '#F7F1E3';
  /** 卡片背景 */
  static readonly cardBg: string = '#FFFFFF';
  /** 主文字 */
  static readonly textMain: string = '#3A2E1F';
  /** 次要文字 */
  static readonly textSub: string = '#8C7B66';
  /** 分割线 */
  static readonly divider: string = '#E8DFCD';
  /** 警示红 */
  static readonly danger: string = '#C0392B';
  /** 在线绿 */
  static readonly online: string = '#2E8B57';
}

/** 遗址卡片封面色（按年代取色） */
export function eraColor(era: string): string {
  switch (era) {
    case '仰韶':
      return '#C0392B';
    case '龙山':
      return '#8E44AD';
    case '夏商':
      return '#D35400';
    case '周':
      return '#2471A3';
    case '汉唐':
      return '#148F77';
    case '宋':
      return '#7D6608';
    default:
      return '#8A5A2B';
  }
}

/** 城市标识色：新增三市使用独立色相，避免与原有主题色、年代色混淆 */
export function cityColor(city: string): string {
  switch (city) {
    case '济源':
      return '#2A9D8F';
    case '焦作':
      return '#C2185B';
    case '新乡':
      return '#3D5A80';
    default:
      return Theme.primary;
  }
}

/** 收藏标签色 */
export function tagColor(tag: string): string {
  switch (tag) {
    case '待实地探访':
      return '#D9A441';
    case '已去过':
      return '#2E8B57';
    case '研究资料':
      return '#2471A3';
    default:
      return '#8A5A2B';
  }
}
