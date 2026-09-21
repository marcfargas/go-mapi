import { execFile } from 'node:child_process';
import { readdir, rm } from 'node:fs/promises';
import { join, parse } from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export type NativeArchitecture = 'x86' | 'x64';

export interface NativeMessage {
  filename: string;
  fullPath: string;
  architecture: NativeArchitecture;
}

export class NativeMapiProducer {
  private readonly created = new Set<string>();

  constructor(
    private readonly queueDir: string,
    private readonly binaries: Record<NativeArchitecture, { harness: string; dll: string }>,
  ) {}

  async send(architecture: NativeArchitecture, caseName = 'Simple Send'): Promise<NativeMessage> {
    const before = new Set(await this.queueFiles());
    const binary = this.binaries[architecture];
    await execFileAsync(binary.harness, [binary.dll, '--case', caseName], {
      env: { ...process.env, GO_MAPI_TEST_RETAIN_OUTPUT: '1' },
      windowsHide: true,
      timeout: 30_000,
    });
    const created = (await this.queueFiles()).filter((filename) => !before.has(filename));
    if (created.length !== 1) {
      throw new Error(`native ${architecture} ${caseName} created ${created.length} queue descriptors; expected exactly one`);
    }
    const fullPath = join(this.queueDir, created[0]);
    this.created.add(fullPath);
    return { filename: created[0], fullPath, architecture };
  }

  async cleanup(): Promise<void> {
    await Promise.all([...this.created].flatMap((fullPath) => [
      rm(fullPath, { force: true }),
      rm(join(parse(fullPath).dir, parse(fullPath).name), { recursive: true, force: true }),
    ]));
  }

  private async queueFiles(): Promise<string[]> {
    return (await readdir(this.queueDir, { withFileTypes: true }))
      .filter((entry) => entry.isFile() && entry.name.endsWith('.json'))
      .map((entry) => entry.name);
  }
}
