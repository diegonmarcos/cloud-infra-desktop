# Vim editor configuration
{ config, pkgs, lib, ... }:

{
  programs.vim = {
    enable = true;
    defaultEditor = true;

    settings = {
      number = true;
      relativenumber = true;
      expandtab = true;
      tabstop = 4;
      shiftwidth = 4;
      ignorecase = true;
      smartcase = true;
      hidden = true;
      mouse = "a";
    };

    extraConfig = ''
      " Basic settings
      set nocompatible
      filetype plugin indent on
      syntax enable
      set encoding=utf-8
      set backspace=indent,eol,start
      set autoindent
      set smartindent

      " Interface
      set ruler
      set showcmd
      set showmode
      set laststatus=2
      set wildmenu
      set wildmode=longest:full,full
      set cursorline

      " Colors
      set background=dark
      colorscheme desert

      " Search
      set incsearch
      set hlsearch

      " Files
      set autoread
      set nobackup
      set nowritebackup
      set noswapfile
      set undofile
      set undodir=~/.vim/undodir

      " Performance
      set lazyredraw
      set ttyfast

      " Leader key
      let mapleader = " "

      " Quick save/quit
      nnoremap <leader>w :w<CR>
      nnoremap <leader>q :q<CR>
      nnoremap <leader>x :x<CR>
      nnoremap <leader><space> :nohlsearch<CR>

      " Window navigation
      nnoremap <C-h> <C-w>h
      nnoremap <C-j> <C-w>j
      nnoremap <C-k> <C-w>k
      nnoremap <C-l> <C-w>l

      " Buffer navigation
      nnoremap <leader>bn :bnext<CR>
      nnoremap <leader>bp :bprevious<CR>
      nnoremap <leader>bd :bdelete<CR>
      nnoremap <leader>bl :buffers<CR>

      " Keep visual selection when indenting
      vnoremap < <gv
      vnoremap > >gv

      " Move lines up/down
      nnoremap <A-j> :m .+1<CR>==
      nnoremap <A-k> :m .-2<CR>==
      vnoremap <A-j> :m '>+1<CR>gv=gv
      vnoremap <A-k> :m '<-2<CR>gv=gv

      " Status line
      set statusline=%#PmenuSel#\ %f%m
      set statusline+=%#LineNr#\ %=
      set statusline+=%y\ %{&encoding}\ [%{&fileformat}]
      set statusline+=\ %p%%\ %l:%c\

      " Filetype settings
      autocmd FileType html,css,javascript,typescript,json setlocal tabstop=2 shiftwidth=2
      autocmd FileType yaml,yml setlocal tabstop=2 shiftwidth=2
      autocmd FileType python setlocal tabstop=4 shiftwidth=4
      autocmd FileType markdown setlocal wrap linebreak
      autocmd FileType nix setlocal tabstop=2 shiftwidth=2

      " Create undodir if needed
      if !isdirectory(expand("~/.vim/undodir"))
        call mkdir(expand("~/.vim/undodir"), "p")
      endif

      " Local overrides
      if filereadable(expand("~/.vimrc.local"))
        source ~/.vimrc.local
      endif
    '';
  };
}
