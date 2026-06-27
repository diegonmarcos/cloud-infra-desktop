// Minimal Electron type stubs — enough to compile main.ts without npm install.
declare module 'electron' {
  export const app: {
    on(event: 'ready' | 'window-all-closed' | 'second-instance' | string, cb: (...a: any[]) => void): void
    quit(): void
    setQuitOnLastWindowClose(v: boolean): void
    requestSingleInstanceLock(): boolean
    setPath(name: string, path: string): void
    getPath(name: string): string
    dock?: { hide(): void }
  }
  export const ipcMain: {
    on(channel: string, cb: (event: any, ...args: any[]) => void): void
  }
  export const nativeImage: {
    createFromPath(path: string): NativeImage
  }
  export interface NativeImage {}
  export class Tray {
    constructor(icon: string | NativeImage)
    setToolTip(tip: string): void
    setContextMenu(menu: Menu): void
    on(event: 'click' | 'double-click' | 'right-click' | string, cb: (...a: any[]) => void): this
  }
  export class BrowserWindow {
    constructor(opts: Record<string, any>)
    loadFile(path: string): void
    show(): void
    hide(): void
    focus(): void
    isVisible(): boolean
    on(event: string, cb: (...a: any[]) => void): this
    webContents: {
      send(channel: string, ...args: any[]): void
      on(event: string, cb: (...a: any[]) => void): void
    }
  }
  export const Menu: {
    buildFromTemplate(tpl: MenuItemConstructorOptions[]): Menu
  }
  export interface Menu {}
  export interface MenuItemConstructorOptions {
    label?: string
    type?: 'normal' | 'separator' | 'submenu' | 'checkbox' | 'radio'
    click?: () => void
    enabled?: boolean
    submenu?: MenuItemConstructorOptions[]
  }
}
