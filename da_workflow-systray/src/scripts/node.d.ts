// Minimal Node.js type stubs — covers exactly what main.ts uses.
// Avoids needing @types/node from npm/nixpkgs.

declare const __dirname: string
declare const __filename: string
declare class URL {
  constructor(input: string)
  protocol: string
  hostname: string
  port:     string
  pathname: string
  search:   string
}
declare function require(mod: string): any
declare const process: {
  env: Record<string, string | undefined>
  argv: string[]
  exit(code?: number): never
  on(event: 'uncaughtException', cb: (err: Error) => void): void
  on(event: 'unhandledRejection', cb: (reason: unknown) => void): void
}
declare function setInterval(cb: (...a: any[]) => void, ms: number): any
declare function setTimeout(cb: (...a: any[]) => void, ms: number): any
declare function clearInterval(id: any): void
declare function clearTimeout(id: any): void

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
  export interface ExecFileException extends Error { code?: number | string }
  export function execFile(
    cmd: string, args: string[],
    opts: { timeout?: number },
    cb: (err: ExecFileException | null, stdout: string, stderr: string) => void
  ): void
}

declare module 'https' {
  export interface IncomingMessage {
    statusCode?: number
    on(event: 'data', cb: (chunk: Buffer) => void): this
    on(event: 'end', cb: () => void): this
    on(event: 'error', cb: (err: Error) => void): this
    setEncoding(enc: string): void
    destroy(): void
  }
  export interface ClientRequest {
    on(event: 'error', cb: (err: Error) => void): this
    on(event: 'timeout', cb: () => void): this
    setTimeout(ms: number, cb?: () => void): void
    write(data: string): void
    end(): void
    destroy(): void
  }
  export interface RequestOptions {
    hostname?: string
    port?: number
    path?: string
    method?: string
    headers?: Record<string, string>
    rejectUnauthorized?: boolean
  }
  export function get(url: string, opts: RequestOptions, cb: (res: IncomingMessage) => void): ClientRequest
  export function request(opts: RequestOptions, cb: (res: IncomingMessage) => void): ClientRequest
}

declare module 'http' {
  export * from 'https'
}

declare namespace Buffer {
  function from(s: string): any
}
