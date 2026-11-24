/**
 * 九曲云档 —— 黄河文化主题研学路线
 * 将遗址按文化主题串联，结合收藏、笔记与地图，形成可执行的研学路径。
 */

/** 文化主题研学路线 */
export class CulturalRoute {
  id: string = '';
  title: string = '';
  icon: string = '';
  desc: string = '';
  siteIds: string[] = [];
  highlight: string = '';

  constructor(id: string, title: string, icon: string, desc: string, siteIds: string[],
    highlight: string) {
    this.id = id;
    this.title = title;
    this.icon = icon;
    this.desc = desc;
    this.siteIds = siteIds;
    this.highlight = highlight;
  }
}

/** 预置研学路线 */
export const CULTURAL_ROUTES: CulturalRoute[] = [
  new CulturalRoute(
    'route_yangshao',
    '仰韶探源线',
    '🌾',
    '从仰韶村、西坡到大河村，理解黄河中游史前聚落、彩陶与早期社会复杂化。',
    ['yangshao', 'xipo', 'miaodigou', 'beiyangping', 'dahecun', 'xishuipo'],
    '史前聚落 · 彩陶文化 · 早期信仰'
  ),
  new CulturalRoute(
    'route_longshan',
    '龙山寻踪线',
    '🏔️',
    '串联龙山时期城址与聚落，观察城垣、礼制萌芽和早期国家形成背景。',
    ['xinzha', 'wangchenggang', 'yuancheng', 'tieqiu'],
    '城址起源 · 礼制萌芽 · 早期国家'
  ),
  new CulturalRoute(
    'route_capital',
    '王朝都城线',
    '🏯',
    '从二里头、郑州商城、殷墟到洛阳城与北宋东京，梳理中原王朝都城演进。',
    ['erlituo', 'zhengzhoushangcheng', 'yinxu', 'luoyangzhouwangcheng', 'hanweigucheng',
      'suitangluoyang', 'dongjing'],
    '夏商周 · 汉魏隋唐 · 北宋东京'
  ),
  new CulturalRoute(
    'route_temple',
    '石窟古寺线',
    '🛕',
    '以龙门石窟、白马寺、少林寺等为线索，理解佛教传播与中原艺术融合。',
    ['longmen', 'baimasi', 'shaolinsi', 'biganmiao', 'jidumiao'],
    '石窟艺术 · 佛教传播 · 古寺建筑'
  ),
  new CulturalRoute(
    'route_kiln',
    '黄河窑火线',
    '🏺',
    '走访当阳峪、黄冶、登封窑等窑址，认识唐三彩、绞胎瓷与北方民窑体系。',
    ['dangyangyu', 'huangye', 'muyangta'],
    '唐三彩 · 绞胎瓷 · 北方民窑'
  ),
  new CulturalRoute(
    'route_song',
    '宋韵古塔线',
    '🗼',
    '从开封铁塔、繁塔到宝轮寺塔、延庆寺塔，感受宋代建筑与城市风貌。',
    ['dongjing', 'tieta', 'fantai', 'baolinsi', 'yanqingsita', 'linglongta'],
    '宋代塔幢 · 东京梦华 · 建筑技艺'
  )
];
