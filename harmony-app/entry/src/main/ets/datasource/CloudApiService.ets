/**
 * 九曲云档 —— 云上 API 访问层
 * 所有云端能力统一经此访问：档案检索、AI 问答、云同步。
 * 服务地址在 GuardianConfig.CLOUD_ENDPOINT 中配置，部署到华为云后替换即可。
 */
import { http } from '@kit.NetworkKit';
import { Heritage, FavoriteItem, NoteItem, HistoryItem, SyncTombstone } from '../model/Models';
import { GuardianConfig } from '../common/GuardianConfig';

interface HeritageListResponse {
  total: number;
  items: Heritage[];
}

export interface CloudChatMessage {
  role: string;
  content: string;
}

export interface ChatSource {
  id: string;
  name: string;
  city: string;
  era: string;
}

export interface ChatResponse {
  answer: string;
  sources: ChatSource[];
  mode: string;
}

export interface CloudSyncPayload {
  favorites: FavoriteItem[];
  notes: NoteItem[];
  history: HistoryItem[];
  tombstones: SyncTombstone[];
}

export class CloudApiService {
  private static instance: CloudApiService = new CloudApiService();

  static getInstance(): CloudApiService {
    return CloudApiService.instance;
  }

  private endpoint(path: string): string {
    return GuardianConfig.CLOUD_ENDPOINT.replace(/\/+$/, '') + path;
  }

  private async requestText(path: string, method: http.RequestMethod,
    body: string = ''): Promise<string> {
    const client = http.createHttp();
    try {
      const header = { 'Content-Type': 'application/json' };
      if (method === http.RequestMethod.POST) {
        const response = await client.request(this.endpoint(path), {
          method: method,
          header: header,
          extraData: body,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 10000,
          readTimeout: 30000,
          usingCache: false
        });
        if (response.responseCode !== 200) {
          throw new Error('HTTP_' + response.responseCode.toString());
        }
        return response.result as string;
      }
      const response = await client.request(this.endpoint(path), {
        method: method,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 30000,
        usingCache: false
      });
      if (response.responseCode !== 200) {
        throw new Error('HTTP_' + response.responseCode.toString());
      }
      return response.result as string;
    } finally {
      client.destroy();
    }
  }

  /** 云优先加载档案，失败时由调用方回退 rawfile */
  async getHeritages(): Promise<Heritage[]> {
    const text: string = await this.requestText('/heritages?page=1&pageSize=100', http.RequestMethod.GET);
    const data: HeritageListResponse = JSON.parse(text) as HeritageListResponse;
    return data.items !== undefined ? data.items : [];
  }

  async chat(question: string, history: CloudChatMessage[]): Promise<ChatResponse> {
    const text: string = await this.requestText('/chat', http.RequestMethod.POST, JSON.stringify({
      question: question,
      history: history,
      userId: 'harmony-client'
    }));
    return JSON.parse(text) as ChatResponse;
  }

  async sync(userId: string, payload: CloudSyncPayload): Promise<CloudSyncPayload> {
    const text: string = await this.requestText('/sync?userId=' + encodeURIComponent(userId),
      http.RequestMethod.POST, JSON.stringify(payload));
    return JSON.parse(text) as CloudSyncPayload;
  }
}
