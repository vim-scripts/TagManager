" File: TagManager.vim
" Author: Alexey Radkov
" Version: 0.2
" Description: Project aware incremental tags manager
" Usage:
"   This plugin is capable of managing both tag jumps and highlights databases
"   simultaneously for different projects. It consists of two standalone
"   applications BuildTags and MakeVimHlTags and this file. To manage tag
"   highlights it uses excellent plugin TagHighlight as backend. The plugin
"   also needs exuberant ctags and (optionally) cscope packages.
"
"   TagManager can manage both jumps and highlights tags incrementally, it
"   means that projects may depend on other projects and user can setup his
"   projects in such a way that he would need to update only small pieces of
"   tags databases related to changes he would have made for a small project:
"   all not changed dependencies would not be rebuilt and would be attached to
"   the small projects as is. For example user can manage a small project
"   my_proj which depends on large 3rd-party libraries libLarge1 and libLarge2
"   that he would definitely never change (we denote this sort of dependency
"   as my_proj:libLarge1,libLarge2), then when he decide to update the tags of
"   the project my_proj, tags from libLarge1 and libLarge2 will be attached to
"   those from my_proj not having been rebuilt.
"
"   The plugin provides 3 commands:
"
"       UpdateProjectJumps
"       UpdateProjectHighlights
"       UpdateProjectTags
"
"   Normally you will need only UpdateProjectTags which is a simple sequence
"   of the first two. Issuing :UpdateProjectTags will update both jumps and
"   highlights tags in the project you are currently in.
"
"   To use the plugin efficiently add following lines in your .vimrc:
"
"       if !exists('g:TagHighlightSettings')
"           let g:TagHighlightSettings = {}
"       endif
"       let g:TagHighlightSettings['LanguageDetectionMethods'] =
"                                               \ ['Extension', 'FileType']
"       let g:TagHighlightSettings['FileTypeLanguageOverrides'] =
"                                               \ {'svn': 'c', 'tagbar': 'c'}
"       let g:loaded_TagHighlight = 2
"
"   Setting variable g:TagHighlightSettings['FileTypeLanguageOverrides'] will
"   let you enjoy tag highlights in tagbar window and when committed svn
"   changes. Line 'let g:loaded_TagHighlight = 2' will prevent loading of
"   TagHighlight before TagManager thus letting the latter to manage
"   initialization of the former itself. This is important because TagManager
"   depends on TagHighlight plugin and autocommands from TagManager must go
"   before corresponding autocommands from TagHighlight. Value 2 will make
"   TagManager aware that variable g:loaded_TagHighlight was only initialized
"   in .vimrc and TagHighlight is really not loaded yet.
"
"   You also may want to put scripts BuildTags and MakeVimHlTags in some
"   directory listed in your $PATH environment variable (by default this
"   plugin expects to find them in $HOME/bin/), and create new environment
"   variable $TAGSDIR where all plugin data will be saved. Now you can
"   additionally use BuildTags and MakeVimHlTags as standalone scripts and
"   create tags for vim directly from command line. To see available
"   command-line options run the scripts with option --help.
"
"   By default plugin reads configuration file $HOME/.vim-TagManager.conf
"   where a user defines settings for building and updating tags for his
"   projects. Each line in the configuration file corresponds to one project
"   and consists of 5 columns, separated with double semicolon (possibly
"   surrounded by spaces or tabs). The first column is a directory match
"   pattern used to define where the project resides, second column - name of
"   the project with optionally appended (after colon) comma-separated list of
"   other projects upon which this project depends, third column - language
"   for building tag highlights (for example 'c' or 'python'), if user do not
"   want to specify any language (i.e. highlights tags will be built for any
"   languages that TagHighlight supports) then he can put in this column
"   special placeholder - exclamation sign (!) which denotes empty value,
"   fourth column - root directory for building jumps and highlights tags,
"   fifth column - options for MakeVimHlTags, to see them run
"
"       MakeVimHlTags --help
"
"   in command line. Please make sure that you understand the difference
"   between values in column 1 and column 4: the former will be used in
"   autocommands for finding out if specific directory matches project
"   directory pattern and thus may contain glob symbols like '*' or '?',
"   whereas the latter denotes the root directory for building tags. Values in
"   any column may refer to environment variables: they will be expanded. An
"   example of configuration file is shipped with this distribution.


if exists('g:loaded_TagMgr') && g:loaded_TagMgr
    finish
endif

let g:loaded_TagMgr = 1

if !exists('g:TagMgrJumpsBuilder')
    let g:TagMgrJumpsBuilder = $HOME."/bin/BuildTags"
endif

if !exists('g:TagMgrHighlightsBuilder')
    let g:TagMgrHighlightsBuilder = $HOME."/bin/MakeVimHlTags"
endif

if !exists('g:TagMgrTagsdir')
    if empty($TAGSDIR)
        echohl WarningMsg
        echo "TagManager: neither g:TagMgrTagsdir nor $TAGSDIR defined!"
                    \ "Plugin will be disabled"
        echohl None
        finish
    endif
    let g:TagMgrTagsdir = $TAGSDIR
endif

if !exists('g:TagMgrFtMap')
    let g:TagMgrFtMap = {'cpp': 'c'}
endif

if !exists('g:TagMgrFtMapExtra')
    let g:TagMgrFtMapExtra = {'svn': '', 'tagbar': ''}
endif

call extend(g:TagMgrFtMap, g:TagMgrFtMapExtra)

if !exists('g:TagMgrTags')
    let g:TagMgrTags = []
endif

if !exists('g:TagMgrDataFile')
    let g:TagMgrDataFile = $HOME.'/.vim-TagManager.conf'
endif

if filereadable(g:TagMgrDataFile)
    for s:line in readfile(g:TagMgrDataFile, '')
        if s:line =~ '\(^\s*#\|^\s*$\)'
            continue
        endif
        call add(g:TagMgrTags, map(map(map(split(s:line, '\s*::\s*'),
                    \ 'substitute(v:val, "^!$", "", "")'),
                    \ 'substitute(v:val, "\\([*?]\\)", "\\\\\\1", "g")'),
                    \ 'expand(v:val)'))
    endfor
endif

let s:tagmgr_usetaghl = 0


fun! <SID>GetLangMap(def_lang, cur_ft)
    if empty(a:def_lang)
        return ''
    endif
    if exists('g:TagMgrFtMap[a:cur_ft]')
        let uselang = g:TagMgrFtMap[a:cur_ft]
        return empty(uselang) ? a:def_lang : uselang
    endif
    return a:cur_ft
endfun

fun! <SID>SetJumps(tags)
    let tagdata = split(a:tags, ':')
    let tagname = tagdata[0]
    let tagdeps = len(tagdata) > 1 ? tagdata[1] : ''

    for db in insert(split(tagdeps, ','), tagname)
        let ctagsdb  = g:TagMgrTagsdir."/".db.".ctags"
        let cscopedb = g:TagMgrTagsdir."/".db.".cscope_out"
        if filereadable(ctagsdb)
            exe 'set tags+=' . ctagsdb
        endif
        if filereadable(cscopedb)
            exe 'cscope add ' . cscopedb
        endif
    endfor
endfun

fun! <SID>SetHighlights()
    if s:tagmgr_usetaghl == 0
        return
    endif
    if !exists('b:TagMgrCurrentTags')
        if !exists('g:TagMgrCurrentTags')
            return
        endif
        let ft = expand('<amatch>')
        if !exists('g:TagMgrFtMapExtra[ft]')
            return
        endif
        let b:TagMgrCurrentTags = g:TagMgrCurrentTags
        if !exists('g:TagMgrUseLang')
            return
        endif
        let b:TagMgrUseLang = g:TagMgrUseLang
    endif

    if !exists('b:TagHighlightSettings')
        let b:TagHighlightSettings = {}
    endif

    let tagdata = split(b:TagMgrCurrentTags, ':')
    let tagname = tagdata[0]
    let tagdeps = len(tagdata) > 1 ? tagdata[1] : ''
    let uselang = <SID>GetLangMap(b:TagMgrUseLang, &ft)

    exe "let b:TagHighlightSettings['UserLibraries'] = ".
                \ "filter(map(add(split(tagdeps, ','), tagname),".
                \ "'\"".g:TagMgrTagsdir."\".\"/\".v:val.\"_".uselang.
                \ ".vim\"'), 'filereadable(v:val)')"
endfun


for s:item in g:TagMgrTags
    let s:tagmgr_tagdata = split(s:item[1], ':')
    let s:tagmgr_tagname = s:tagmgr_tagdata[0]
    let s:tagmgr_uselang = s:item[2] ? '-L'.s:item[2] : ''
    exe "autocmd BufReadPre,BufNewFile ".s:item[0].
            \ " if !empty('".s:item[3]."') | let b:TagMgrJBOpt = '-p ".
                \ s:tagmgr_tagname." -d ".g:TagMgrTagsdir." ".s:item[3].
                \ "' | let b:TagMgrHlBOpt = '-p". s:tagmgr_tagname." -d".
                \ g:TagMgrTagsdir." ".s:tagmgr_uselang." ".s:item[4]." ".
                \ s:item[3].
            \ "' | endif | ".
            \ " let b:TagMgrProject = '".s:tagmgr_tagname."'"
    exe "autocmd BufReadPre,BufNewFile ".s:item[0].
            \ " let b:TagMgrCurrentTags = '".s:item[1]."'".
            \ " | let g:TagMgrCurrentTags = b:TagMgrCurrentTags".
            \ " | let b:TagMgrUseLang = '".s:item[2]."'".
            \ " | let g:TagMgrUseLang = b:TagMgrUseLang"
    " calling SetHighlights() in autocmd BufNewFile is necessary because
    " FileType event goes before BufNewFile event (in contrast BufReadPre
    " goes before FileType):
    exe "autocmd BufNewFile ".s:item[0]." call <SID>SetHighlights()"
    " BEWARE: jump tags are only set at vim enter!
    exe "autocmd VimEnter ".s:item[0].
            \ " silent call <SID>SetJumps('".s:item[1]."')"
endfor

autocmd FileType * call <SID>SetHighlights()


fun! <SID>UpdateProjectJumps()
    let proj = exists('b:TagMgrProject') ? b:TagMgrProject :
                \ '(undefined project)'

    if exists('b:TagMgrJBOpt') && executable(g:TagMgrJumpsBuilder)
        echo "Building tags for project ".proj." ..."
        exe "call system('".g:TagMgrJumpsBuilder." ".b:TagMgrJBOpt."')"
        " add tags of the current project if not present yet
        if exists('b:TagMgrProject') && !empty(b:TagMgrProject)
            let ctagsdb  = g:TagMgrTagsdir."/".b:TagMgrProject.".ctags"
            if &tags !~ '\(^\|,\)'.ctagsdb.'\(,\|$\)' &&
                        \ filereadable(ctagsdb)
                exe 'set tags+=' . ctagsdb
            endif
            let cscopedb = g:TagMgrTagsdir."/".b:TagMgrProject.".cscope_out"
            if cscope_connection(1, b:TagMgrProject) == 0 &&
                        \ filereadable(cscopedb)
                exe 'cscope add ' . cscopedb
            endif
        endif
        " reset cscope db, ctags need not be reset
        cscope reset
        echo "done"
    else
        echoerr "Failed to build tags for project ".proj
    endif
endfun

fun! <SID>UpdateProjectHighlights()
    let proj = exists('b:TagMgrProject') ? b:TagMgrProject :
                \ '(undefined project)'

    if exists('b:TagMgrHlBOpt') && executable(g:TagMgrHighlightsBuilder)
        echo "Building highlights for project ".proj." ..."
        exe "call system('".g:TagMgrHighlightsBuilder." ".b:TagMgrHlBOpt."')"

        " refresh highlights in all related buffers
        let updated = 0
        let lastbuf = bufnr('$')
        let i = 1
        while i <= lastbuf
            let cur_proj = getbufvar(i, 'TagMgrProject')
            let cur_lang = getbufvar(i, 'TagMgrUseLang')
            let cur_ft = getbufvar(i, '&filetype')
            let uselang = <SID>GetLangMap(cur_lang, cur_ft)
            " variable b:TagMgrProject is not defined in tagbar, but we want
            " to update tagbar too
            if cur_proj == b:TagMgrProject && uselang == b:TagMgrUseLang ||
                        \ cur_ft == 'tagbar'
                " trigger FileType event forcibly in related buffers
                call setbufvar(i, '&filetype', cur_ft)
                let updated += 1
            endif
            let i += 1
        endwhile

        " restore false Powerline activation in all windows except current
        if updated
            let lastwin = winnr('$')
            let curwin = winnr()
            let i = 1
            while i <= lastwin
                if i != curwin
                    let sl = getwinvar(i, '&statusline')
                    if sl =~ '^%!Pl#Statusline(\d\+,1)$'
                        let sl = substitute(sl, '1\()\)$', '0\1', '')
                        call setwinvar(i, '&statusline', sl)
                    endif
                endif
                let i += 1
            endwhile
        endif

        echo "done"
    else
        echoerr "Failed to build highlights for project ".proj
    endif
endfun

fun! <SID>UpdateProjectTags()
    call <SID>UpdateProjectJumps()
    call <SID>UpdateProjectHighlights()
endfun


command UpdateProjectJumps call <SID>UpdateProjectJumps()
command UpdateProjectHighlights call <SID>UpdateProjectHighlights()
command UpdateProjectTags call <SID>UpdateProjectTags()


" load plugin TagHighlight after all our autocommands were defined
if !exists('g:loaded_TagHighlight') || g:loaded_TagHighlight == 2
    unlet! g:loaded_TagHighlight
    runtime plugin/TagHighlight.vim
    if exists('g:loaded_TagHighlight')
        let s:tagmgr_usetaghl = 1
    endif
endif

