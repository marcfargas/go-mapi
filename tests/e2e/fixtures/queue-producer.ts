import { randomBytes } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';

export interface QueueMessageOptions {
  subject?: string;
  timestamp?: string;
  to?: Array<{ name?: string; address: string }>;
}

export class QueueProducer {
  constructor(readonly dir: string, private readonly onWrite: () => Promise<void> = async () => {}) {}

  async send(options: QueueMessageOptions = {}) {
    const filename = `email-${Date.now()}-${randomBytes(4).toString('hex')}.json`;
    const fullPath = join(this.dir, filename);
    const message = {
      version: 1,
      interceptorVersion: '4.0.0',
      timestamp: options.timestamp ?? new Date().toISOString(),
      subject: options.subject ?? 'E2E test subject',
      body: 'E2E test body',
      bodyFormat: 'plain',
      recipients: {
        to: options.to ?? [{ name: 'Recipient', address: 'recipient@example.com' }],
        cc: [],
        bcc: [],
      },
      attachments: [],
      originApp: 'e2e-queue-producer',
    };
    await writeFile(fullPath, JSON.stringify(message), 'utf8');
    await this.onWrite();
    return { filename, fullPath };
  }
}
