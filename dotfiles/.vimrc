" ==============================================================================
" Gerzain's Vim Configuration (Adapted from curated nix dotfiles)
" ==============================================================================

" Colors {{{
syntax enable           " enable syntax processing
set background=dark
try
    colorscheme badwolf
catch
    " fallback if badwolf is missing
    colorscheme default
endtry
" }}}

" Misc {{{
set modeline
set modelines=1
set encoding=utf-8
" }}}

" Spaces & Tabs {{{
set tabstop=4           " 4 space tab
set expandtab           " use spaces for tabs
set softtabstop=4       " 4 space tab
set shiftwidth=4
filetype indent on
filetype plugin on
set autoindent
set breakindent         " indent wrapped lines to match start of line
set linebreak           " break lines at whitespace instead of arbitrary boundary
" }}}

" UI Layout {{{
set number              " show line numbers
set relativenumber      " show relative line numbers
set showcmd             " show command in bottom bar
set nocursorline        " highlight current line
set wildmenu
set lazyredraw
set showmatch           " highlight matching parenthesis
" }}}

" Searching {{{
set ignorecase          " ignore case when searching
set smartcase           " match case if capital letters entered
set incsearch           " search as characters are entered
set hlsearch            " highlight all matches
" }}}

" Folding {{{
set foldmethod=indent   " fold based on indent level
set foldnestmax=10      " max 10 depth
set foldenable          " enable folding
nnoremap <space> za
set foldlevelstart=10   " start open
" }}}

" Line Shortcuts {{{
nnoremap gV `[v`]
" }}}

" Leader Shortcuts {{{
let mapleader=","
nnoremap <leader>m :silent make\|redraw!\|cw<CR>
nnoremap <leader>ev :vsp $MYVIMRC<CR>
nnoremap <leader>et :exec ":vsp ~/notes/vim/" . strftime('%m-%d-%y') . ".md"<CR>
nnoremap <leader>ez :vsp ~/.zshrc<CR>
nnoremap <leader>sv :source $MYVIMRC<CR>
nnoremap <leader><space> :noh<CR>
nnoremap <leader>s :mksession<CR>
nnoremap <leader>1 :set number!<CR>
vnoremap <leader>y "+y
" }}}

" Backups & Swap {{{
set backup
set backupdir=~/.vim-tmp,~/.tmp,~/tmp,/var/tmp,/tmp
set backupskip=/tmp/*,/private/tmp/*
set directory=~/.vim-tmp,~/.tmp,~/tmp,/var/tmp,/tmp
set writebackup
" }}}

" AutoGroups {{{
augroup configgroup
    autocmd!
    autocmd VimEnter * highlight clear SignColumn
    autocmd BufWritePre *.php,*.py,*.js,*.txt,*.hs,*.java,*.md,*.rb,*.rs,*.c,*.h,*.cpp :call <SID>StripTrailingWhitespaces()
    autocmd BufEnter Makefile setlocal noexpandtab
    autocmd BufEnter *.sh setlocal tabstop=2 shiftwidth=2 softtabstop=2
    autocmd BufEnter *.py setlocal tabstop=4 shiftwidth=4
    autocmd BufEnter *.rs setlocal tabstop=4 shiftwidth=4
    autocmd BufEnter *.md setlocal ft=markdown
    autocmd BufEnter *.go setlocal noexpandtab
augroup END
" }}}

" Custom Functions {{{
" Strip trailing whitespace on buffer write
function! <SID>StripTrailingWhitespaces()
    let _s=@/
    let l = line(".")
    let c = col(".")
    %s/\s\+$//e
    let @/=_s
    call cursor(l, c)
endfunc
" }}}

" vim:foldmethod=marker:foldlevel=0
