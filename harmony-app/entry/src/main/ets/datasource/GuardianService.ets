/**
 * 九曲云档 —— 黄河守护灵问答服务（云上智能体版）
 * 客户端不再持有任何大模型 API Key；问题与最近上下文提交到云上 API，
 * 由云端完成档案检索、Redis 缓存、大模型调用与来源组装。
 */
import { CloudApiService, CloudChatMessage, ChatSource } from './CloudApiService';

/** 对话消息 */
export class GuardianMsg {
  role: string = 'user';
  content: string = '';

  constructor(role: string, content: string) {
    this.role = role;
    this.content = content;
  }
}

export class GuardianService {
  private static instance: GuardianService = new GuardianService();

  static getInstance(): GuardianService {
    return GuardianService.instance;
  }

  /** 发起一次问答；云端失败时抛出带标识的错误，由页面给出提示 */
  async ask(question: string, history: GuardianMsg[]): Promise<string> {
    const recent: CloudChatMessage[] = [];
    for (const msg of history.slice(-6)) {
      if (msg.role === 'user' || msg.role === 'assistant') {
        recent.push(new CloudChatMessageImpl(msg.role, msg.content));
      }
    }
    const result = await CloudApiService.getInstance().chat(question, recent);
    const sourceText: string = this.buildSourceText(result.sources);
    const modeTag: string = result.mode === 'cloud' ? '' : '（本地演示模式）';
    return result.answer + modeTag + sourceText;
  }

  private buildSourceText(sources: ChatSource[]): string {
    if (sources === undefined || sources.length === 0) {
      return '';
    }
    const names: string[] = [];
    for (const source of sources) {
      names.push(source.name + '·' + source.city);
    }
    return '\n\n档案来源：' + names.join('、');
  }
}

class CloudChatMessageImpl implements CloudChatMessage {
  role: string;
  content: string;

  constructor(role: string, content: string) {
    this.role = role;
    this.content = content;
  }
}
