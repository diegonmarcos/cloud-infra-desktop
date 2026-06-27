// Minimal Node.js type stubs — covers exactly what main.ts uses.
// Avoids needing @types/node from npm/nixpkgs.

declare const __dirname: string
declare const __filename: string
declare const process: {
  env: Record<string, string | undefined>
  argv: string[]
  exit(code?: number): never
  on(event: 'uncaughtException', cb: (err: Error) => void): void
  on(event: 'unhandledRejection', cb: (reason: unknown) => void): void
}

declare module 'fs' {
  export function readFileSync(path: string, enc: 'utf8'): string
  export function readlinkSync(path: string): string
  export function existsSync(path: string): boolean
  export function readdirSync(path: string): string[]
  export function statSync(path: string): { mtime: Date; mtimeMs: number }
}

declare module 'path' {
  export function join(...parts: string[]): string
  export function dirname(p: string): string
  export function basename(p: string, ext?: string): string
}

declare module 'child_process' {
  export interface ChildProcess {
    stdout: { on(event: 'data', cb: (d: Buffer) => void): void } | null
    stderr: { on(event: 'data', cb: (d: Buffer) => void): void } | null
    on(event: 'close', cb: (code: number | null) => void): this
    kill(signal?: string): boolean
    unref(): void
  }
  export interface SpawnOptions {
    detached?: boolean
    stdio?: 'ignore' | 'pipe' | 'inherit' | Array<any>
    cwd?: string
  }
  export function spawn(cmd: string, args?: string[], opts?: SpawnOptions): ChildProcess
}
