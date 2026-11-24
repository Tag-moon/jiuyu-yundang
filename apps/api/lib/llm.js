import { env } from './env.js';
import { retrieve, recommend, facets } from './store.js';

function contextText(sites) {
  return sites.map((site) => {
    const tourism = site.tourism || {};
    return [
      `- ${site.name}（${site.city}，${site.era}·${site.dynasty}，${site.type}）`,
      `  简介：${site.summary}`,
      tourism.openTime ? `  开放时间：${tourism.openTime}` : '',
      tourism.ticket ? `  门票：${tourism.ticket}` : ''
    ].filter(Boolean).join('\n');
  }).join('\n');
}

function systemPrompt(sites) {
  return [
    '你是「黄河守护灵」，九曲云档中负责讲解黄河河南段文化遗存的向导。',
    '只谈黄河河南段的文化遗产、历史、考古与研学路线，语气温和克制。',
    '只使用【档案范围】中的资料，不编造遗址名、年代、门票或开放时间。',
    '先给一句结论，再用两到三句解释，总长不超过 160 字。',
    '问路线时给出 2 至 4 个站点，并按城市顺序说明串联理由。',
    '',
    '【档案范围】',
    contextText(sites)
  ].join('\n');
}

function cityQuestion(question) {
  return facets().cities.find((city) => city !== '全部' && question.includes(city)) || '';
}

function eraQuestion(question) {
  return facets().eras.find((era) => era !== '全部' && question.includes(era)) || '';
}

function demoAnswer(question, sites) {
  const isRoute = /路线|推荐|一日|怎么玩|游/.test(question);
  if (isRoute) {
    const city = cityQuestion(question);
    const era = eraQuestion(question);
    const route = recommend({ city, era, keyword: question, limit: 3 });
    if (route.length === 0) {
      return '这条路线暂时没有匹配的档案记录，可以换个城市或年代再问。';
    }
    return `建议走「${route.map((item) => item.name).join(' → ')}」。` +
      (city ? `三处都在${city}，地理上顺路，` : '这些遗址在主题上关联紧密，') +
      `可以按 ${route.map((item) => item.era).filter((v, i, a) => a.indexOf(v) === i).join('、')} 的时间线理解黄河文化。`;
  }
  const primary = sites[0];
  if (!primary) return '档案里暂时没有收录这个问题的答案，可以换个遗址名再问。';
  const detail = primary.archaeology || primary.intro || primary.summary;
  const firstSentence = detail.split(/[。；]/).filter(Boolean).slice(0, 2).join('。') + '。';
  return `${primary.name}值得重点看：${firstSentence}` +
    `它位于${primary.city}，年代为${primary.era}，可作为理解这一阶段黄河文化的关键样本。`;
}

export async function answerQuestion(question, history = []) {
  const sites = retrieve(String(question), 4);
  const sources = sites.map((site) => ({
    id: site.id,
    name: site.name,
    city: site.city,
    era: site.era
  }));

  const canCallCloud = Boolean(env.LLM_BASE_URL && env.LLM_API_KEY);
  if (canCallCloud) {
    try {
      const base = String(env.LLM_BASE_URL).replace(/\/$/, '');
      const messages = [
        { role: 'system', content: systemPrompt(sites) },
        ...history.slice(-6).filter((msg) => ['user', 'assistant'].includes(msg.role)),
        { role: 'user', content: String(question) }
      ];
      const response = await fetch(`${base}/chat/completions`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${env.LLM_API_KEY}`
        },
        body: JSON.stringify({
          model: env.LLM_MODEL || 'default',
          messages,
          temperature: 0.5,
          max_tokens: 500,
          stream: false
        }),
        signal: AbortSignal.timeout(30000)
      });
      if (!response.ok) throw new Error(`HTTP_${response.status}`);
      const data = await response.json();
      const answer = String(data?.choices?.[0]?.message?.content || '').replace(/\*\*/g, '').trim();
      if (answer) return { answer, sources, mode: 'cloud' };
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      return {
        answer: demoAnswer(question, sites) + '\n（大模型暂不可用，已切换演示模式：' + reason + '）',
        sources,
        mode: 'demo-fallback'
      };
    }
  }

  return { answer: demoAnswer(question, sites), sources, mode: 'demo' };
}
