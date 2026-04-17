import { EventsOn } from '../../wailsjs/runtime/runtime';
import { GetQueue } from '../../wailsjs/go/main/App';

export interface MailMessageFrom { address: string; name?: string }
export interface MailMessage {
  version: number;
  timestamp: string;
  bodyFormat: string;
  subject?: string;
  from?: MailMessageFrom;
}
export interface EmailWithId { id: string; message?: MailMessage }

export async function fetchQueue(): Promise<EmailWithId[]> {
  return (await GetQueue()) ?? [];
}

export function subscribeQueue(onChange: (q: EmailWithId[]) => void): () => void {
  return EventsOn('queue-update', async () => {
    onChange(await fetchQueue());
  });
}
