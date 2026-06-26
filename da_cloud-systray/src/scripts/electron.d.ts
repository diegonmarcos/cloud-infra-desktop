// Minimal Electron type stubs — enough to compile main.ts without npm install.
declare module 'electron' {
  export const app: {
    on(event: 'ready' | 'window-all-closed' | string, cb: (...a: any[]) => void): void
    quit(): void
    dock?: { hide(): void }
  }
  export const ipcMain: {
    on(channel: string, cb: (event: any, ...args: any[]) => void): void
    handle(channel: string, cb: (event: any, ...args: any[]) => Promise<any>): void
  }
  export class Tray {
    constructor(icon: string)
    setToolTip(tip: string): void
    setContextMenu(menu: Menu): void
    on(event: 'click' | string, cb: (...a: any[]) => void): this
  }
  export class BrowserWindow {
    constructor(opts: Record<string, any>)
    loadFile(path: string): void
    show(): void
    hide(): void
    focus(): void
    isVisible(): boolean
    on(event: string, cb: (...a: any[]) => void): this
    webContents: { send(channel: string, ...args: any[]): void }
  }
  export const Menu: {
    new(): Menu
    buildFromTemplate(tpl: MenuItemConstructorOptions[]): Menu
  }
  export interface MenuItemConstructorOptions {
    label?: string
    type?: 'normal' | 'separator' | 'submenu' | 'checkbox' | 'radio'
    submenu?: MenuItemConstructorOptions[]
    click?: () => void
    enabled?: boolean
  }
}
