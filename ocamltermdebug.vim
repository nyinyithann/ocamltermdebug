" Shameless debugger plugin using ocamldebug.
"
" Author: Rehan Malak based on termdebug.vim from Bram Moolenaar
" Copyright: Vim license applies, see ":help license"

if exists(':Ocamltermdebug')
  finish
endif

let g:orig_dir = getcwd()

let s:keepcpo = &cpo
set cpo&vim

" The command that starts debugging, e.g. ":Ocamltermdebug vim".
" To end type "quit" in the gdb window.
command -nargs=* -complete=file -bang Ocamltermdebug call s:StartDebug(<bang>0, <f-args>)
command -nargs=+ -complete=file -bang OcamltermdebugCommand call s:StartDebugCommand(<bang>0, <f-args>)

" Name of the gdb command, defaults to "gdb".
if !exists('ocamltermdebugger')
  let ocamltermdebugger = 'rlwrap ocamldebug -emacs'
endif

let s:pc_id = 12
let s:break_id = 13  " breakpoint number is added to this
let s:stopped = 1

hi default debugBreakpoint term=reverse ctermbg=red guibg=red

func s:StartDebug(bang, ...)
  autocmd BufEnter * silent! exe 'lcd ' . g:orig_dir
  " First argument is the command to debug, second core file or process ID.
  call s:StartDebug_internal({'gdb_args': a:000, 'bang': a:bang})
endfunc

func s:StartDebugCommand(bang, ...)
  " First argument is the command to debug, rest are run arguments.
  call s:StartDebug_internal({'gdb_args': [a:1], 'proc_args': a:000[1:], 'bang': a:bang})
endfunc

func s:StartDebug_internal(dict)
  if exists('s:gdbwin')
    echoerr 'Terminal debugger already running'
    return
  endif
  let s:ptywin = 0
  let s:pid = 0

  " Uncomment this line to write logging in "debuglog".
  call ch_logfile('debuglog', 'w')

  let s:sourcewin = win_getid(winnr())

  call s:StartDebug_term(a:dict)
endfunc

func s:StartDebug_term(dict)
  let s:ptywin = win_getid(winnr())

  " Open a terminal window to run the debugger.
  " Add -quiet to avoid the intro message causing a hit-enter prompt.
  let gdb_args = get(a:dict, 'gdb_args', [])
  if empty(gdb_args)
      let gdb_args = [expand('%:r')]
  endif
  let proc_args = get(a:dict, 'proc_args', [])

  let cmd = [g:ocamltermdebugger] + gdb_args
  call ch_log('executing "' . join(cmd) . '"')
  let s:gdbbuf = term_start(join(cmd), {
    \ 'out_cb': function('s:GdbOutCallback'),
	\ 'exit_cb': function('s:EndTermDebug'),
	\ 'term_finish': 'close',
    \ 'vertical': 1
	\ })
  if s:gdbbuf == 0
    echoerr 'Failed to open the gdb terminal window'
    return
  endif
  let s:gdbwin = win_getid(winnr())

  " Set arguments to be run
  if len(proc_args)
    call term_sendkeys(s:gdbbuf, 'set args ' . join(proc_args) . "\r")
  endif

  " Wait for the response to show up, users may not notice the error and wonder
  " why the debugger doesn't work.
  let try_count = 0
  while 1
    let response = term_getline(s:gdbbuf, 1)
    if response =~ 'OCaml Debugger'
      break
    endif
    let try_count += 1
    if try_count > 100
      echoerr 'Cannot check if your ocamldebug works, exit...'
      return
    endif
    sleep 10m
  endwhile

  call s:StartDebugCommon(a:dict)
endfunc

func s:StartDebugCommon(dict)
  " Sign used to highlight the line where the program has stopped.
  " There can be only one.
  sign define debugPC linehl=debugPC

  " Install debugger commands in the text window.
  call win_gotoid(s:sourcewin)
  call s:InstallCommands()
  call win_gotoid(s:gdbwin)

  " Enable showing a balloon with eval info
  if has("balloon_eval") || has("balloon_eval_term")
    set balloonexpr=OcamlTermDebugBalloonExpr()
    if has("balloon_eval")
      set ballooneval
    endif
    if has("balloon_eval_term")
      set balloonevalterm
    endif
  endif

  " Contains breakpoints that have been placed, key is the number.
  let s:breakpoints = {}

  augroup TermDebug
    au BufRead * call s:BufRead()
    au BufUnload * call s:BufUnloaded()
  augroup END

  " Run the command if the bang attribute was given and got to the debug
  " window.
  if get(a:dict, 'bang', 0)
"     call s:SendCommand('-exec-run') " TODO no ocamldebug
    call win_gotoid(s:ptywin)
  endif
endfunc

" Send a command to gdb.  "cmd" is the string without line terminator.
func s:SendCommand(cmd)
  call ch_log('sending to gdb: ' . a:cmd)
  call term_sendkeys(s:gdbbuf, a:cmd . "\r")
endfunc

" This is global so that a user can create their mappings with this.
func OcamlTermDebugSendCommand(cmd)
  let do_continue = 0
  if !s:stopped
    let do_continue = 1
"     call s:SendCommand('-exec-interrupt') " TODO no ocamldebug
    sleep 10m
  endif
  call term_sendkeys(s:gdbbuf, a:cmd . "\r")
  if do_continue
    Continue
  endif
endfunc

" Function called when gdb outputs text.
func s:GdbOutCallback(channel, text)
  call ch_log('received from gdb: ' . a:text)

"   " remove (ocd) prompt
"   let msgs = split(a:text, "\r")
"   let atext = ''
"   for msg in msgs
"     if msg[0:4] == "(ocd)"
"       break
"     else
"       let atext .= msg . "\r"
"     endif
"   endfor

  let atext=a:text
  call ch_log('received from filtered gdb: ' . atext)
  if atext =~ 'Unbound'
    if exists('s:evalexpr') && atext =~ 'Unbound'
      " Silently drop evaluation errors.
      unlet s:evalexpr
      return
    endif
  elseif atext[0] == '~'
    let atext = s:DecodeMessage(atext[1:])
  else
    call s:CommOutput(a:channel, atext)
    return
  endif

  let curwinid = win_getid(winnr())
  call win_gotoid(s:gdbwin)

  " Add the output above the current prompt.
  call append(line('$') - 1, atext)
  set modified

  call win_gotoid(curwinid)
endfunc

" Decode a message from gdb.  quotedText starts with a ", return the text up
" to the next ", unescaping characters.
func s:DecodeMessage(quotedText)
  let result = ''
  let i = 1
  while a:quotedText[i] != '"' && i < len(a:quotedText)
    if a:quotedText[i] == '\'
      let i += 1
      if a:quotedText[i] == 'n'
	" drop \n
	let i += 1
	continue
      endif
    endif
    let result .= a:quotedText[i]
    let i += 1
  endwhile
  return result
endfunc

func s:EndTermDebug(job, status)
  unlet s:gdbwin

  call s:EndDebugCommon()
endfunc

func s:EndDebugCommon()
  let curwinid = win_getid(winnr())

  call win_gotoid(s:sourcewin)
  call s:DeleteCommands()

  call win_gotoid(curwinid)

  if has("balloon_eval") || has("balloon_eval_term")
    set balloonexpr=
    if has("balloon_eval")
      set noballooneval
    endif
    if has("balloon_eval_term")
      set noballoonevalterm
    endif
  endif

  au! TermDebug
endfunc

" Handle a message received from gdb on the GDB/MI interface.
func s:CommOutput(chan, msg)
  let msgs = split(a:msg, "\r")

  for msg in msgs
    " remove prefixed NL
    if msg[0] == "\n"
      let msg = msg[1:]
    endif
    if msg =~ "Can't" || msg =~ '(ocd)' || msg =~ 'print "'
      " nothing to do
    elseif msg =~ '^M'
      call ch_log('DEBUG detect HandleCursor ' . msg)
      call s:HandleCursor(msg)
    elseif msg =~ 'Removed '
      call ch_log('DEBUG detect HandleClearBreakpoint ' . msg)
      call s:HandleBreakpointDelete(msg)
    elseif msg =~ 'No breakpoint '
      break
    elseif msg =~ 'Breakpoint '
      call ch_log('DEBUG detect HandleNewBreakpoint ' . msg)
      call s:HandleNewBreakpoint(msg)
    elseif msg =~ 'Unbound '
      call ch_log('DEBUG detect HandleError ' . msg)
      call s:HandleError(msg)
    elseif msg =~ '='
        call ch_log('DEBUG detect HandleEvaluate ' . msg)
        call s:HandleEvaluate(msg)
    else
        call ch_log('DEBUG not implemented ' . msg)
    endif
  endfor
endfunc

func s:SendArguments()
  call s:SendCommand('set arguments load-file example/path.red')
  sleep 100m
  call term_sendkeys(s:gdbbuf, "y\r")
endfunc

func s:GotoPrgrm()
  call term_sendkeys(s:gdbbuf, "g 0\r")
endfunc

" Install commands in the current window to control the debugger.
func s:InstallCommands()
  let save_cpo = &cpo
  set cpo&vim

  command! Break call s:SetBreakpoint() " wrap around SendCommand('br @ blabla.ml 3')
  nnoremap <C-b> :Break<CR>
  command! Clear call s:ClearBreakpoint()
  nnoremap <C-c> :Clear<CR>
  command! Step call s:SendCommand('step')
  nnoremap <C-s> :Step<CR>
  command! Over call s:SendCommand('next')
  nnoremap <C-n> :Over<CR>
  command! Finish call s:SendCommand('finish')
  nnoremap <C-f> :Finish<CR>
  command! Run call s:SendCommand('run')
  nnoremap <C-e> :Run<CR>
  command! Last call s:SendCommand('last')
  nnoremap <C-l> :Last<CR>
  command! Arguments call s:SendArguments()
  nnoremap <C-a> :Arguments<CR>
  command! Goto call s:GotoPrgrm()
  nnoremap <C-g> :Goto<CR>
  command! Back call s:SendCommand('backstep')
  nnoremap <C-k> :Back<CR>
"   command Stop call s:SendCommand('-exec-interrupt') " TODO no ocamldebug

"   command Continue call term_sendkeys(s:gdbbuf, "continue\r")

  command! -range -nargs=* Evaluate call s:Evaluate(<range>, <q-args>)
  command! Gdb call win_gotoid(s:gdbwin)
  command! Program call win_gotoid(s:ptywin)
  command! Source call s:GotoSourcewinOrCreateIt()

  " TODO: can the K mapping be restored?
  nnoremap K :Evaluate<CR>

  let &cpo = save_cpo
endfunc

let s:winbar_winids = []

" Delete installed debugger commands in the current window.
func s:DeleteCommands()
  delcommand Break
  delcommand Clear
  delcommand Step
  delcommand Over
  delcommand Finish
  delcommand Run
  delcommand Arguments
"   delcommand Stop
"   delcommand Continue
  delcommand Evaluate
  delcommand Gdb
  delcommand Program
  delcommand Source

  nunmap K

  exe 'sign unplace ' . s:pc_id
  for key in keys(s:breakpoints)
    exe 'sign unplace ' . (s:break_id + key)
  endfor
  unlet s:breakpoints

  sign undefine debugPC
  for val in s:BreakpointSigns
    exe "sign undefine debugBreakpoint" . val
  endfor
  let s:BreakpointSigns = []
endfunc

" :Break - Set a breakpoint at the cursor position.
func s:SetBreakpoint()
  " Setting a breakpoint may not work while the program is running.
  " Interrupt to make it work.
  let do_continue = 0
  if !s:stopped
    let do_continue = 1
"     call s:SendCommand('-exec-interrupt') " TODO not ocamldebug
    sleep 10m
  endif
  " Use the most explicit ocamldebug format
  call s:SendCommand('br @ ' . expand('%:t:r') . ' ' . line('.'))
  if do_continue
"     call s:SendCommand('-exec-continue') " TODO not ocamldebug
  endif
endfunc

" :Clear - Delete a breakpoint at the cursor position.
func s:ClearBreakpoint()
  let fname = g:orig_dir . '/' . @%
  call ch_log("DEBUG fname " . fname)
  let lnum = line('.')
  for [key, val] in items(s:breakpoints)
    call ch_log("DEBUG " . key . ' ' . val['fname'])
    if val['fname'] == fname && val['lnum'] == lnum
      call s:SendCommand('delete ' . key)
      break
    endif
  endfor
endfunc

func s:HandleBreakpointDelete(msg)
  let r_line        = '\(\w\+\)\s\(\w\+\)\s\(\d\+\)'
  let m = matchlist(a:msg, r_line)
  call ch_log("DEBUG len(m) " . len(m))
  if !empty(m)
    let key = m[3]
    call ch_log("DEBUG key          inside " . key)
    exe 'sign unplace ' . (s:break_id + key)
    unlet s:breakpoints[key]
  else
    echoerr 'regex not robust enough ?!'
  endif
endfunc

func s:SendEval(expr)
  call s:SendCommand('print "' . a:expr . '"')
  let s:evalexpr = a:expr
endfunc

" :Evaluate - evaluate what is under the cursor
func s:Evaluate(range, arg)
  if a:arg != ''
    let expr = a:arg
  elseif a:range == 2
    let pos = getcurpos()
    let reg = getreg('v', 1, 1)
    let regt = getregtype('v')
    normal! gv"vy
    let expr = @v
    call setpos('.', pos)
    call setreg('v', reg, regt)
  else
    let expr = expand('<cexpr>')
  endif
  let s:ignoreEvalError = 0
  call s:SendEval(expr)
endfunc

let s:ignoreEvalError = 0
let s:evalFromBalloonExpr = 0

" Handle the result of data-evaluate-expression
func s:HandleEvaluate(msg)
  if !exists('s:evalexpr')
    return
  endif
  let value = a:msg 
  let value = substitute(value, '\\"', '"', 'g')
  if s:evalFromBalloonExpr
    let s:evalFromBalloonExprResult = value
    call ch_log(s:evalFromBalloonExprResult)
    call balloon_show(s:evalFromBalloonExprResult)
  else
    echomsg '"' . s:evalexpr . '": ' . value
  endif
endfunc

" Show a balloon with information of the variable under the mouse pointer,
" if there is any.
func OcamlTermDebugBalloonExpr()
  if v:beval_winid != s:sourcewin
    return
  endif
  if !s:stopped
    " Only evaluate when stopped, otherwise setting a breakpoint using the
    " mouse triggers a balloon.
    return
  endif
  let s:evalFromBalloonExpr = 1
  let s:evalFromBalloonExprResult = ''
  let s:ignoreEvalError = 1
  call s:SendEval(v:beval_text)
  return ''
endfunc

" Handle an error.
func s:HandleError(msg)
  if s:ignoreEvalError
    " Result of s:SendEval() failed, ignore.
    let s:ignoreEvalError = 0
    let s:evalFromBalloonExpr = 0
    call ch_log('Handled Error')
    return
  endif
"   echoerr substitute(a:msg, '.*msg="\(.*\)"', '\1', '')
endfunc

func s:GotoSourcewinOrCreateIt()
  if !win_gotoid(s:sourcewin)
    new
    let s:sourcewin = win_getid(winnr())
  endif
endfunc

" Handle stopping and running message from gdb.
" Will update the sign that shows the current position.
func s:HandleCursor(msg)

  let m = matchlist(a:msg, '^M\([^:]*\):\([^:]*\):\([^:]*\).*')
  call ch_log('DEBUG m ' . len(m))
  if len(m) > 0 && m[1] != ''
    let wid = win_getid(winnr())

    let fname  = m[1]
    let bytepos = m[2]
    if bytepos == 0
        let bytepos = 1
    endif
    let bytepos2 = m[3]
    call ch_log('DEBUG m[1] m[2] m[3] ' . m[1] . ' ' . m[2] . ' ' . m[3])
    call ch_log('DEBUG fname ' . fname)

    if filereadable(fname)
      call ch_log('DEBUGGG  ' . 'file readable ' . fname . ' at pos ' . bytepos . ' and ' . bytepos2)
      call s:GotoSourcewinOrCreateIt()
      if expand('%:p') != fnamemodify(fname, ':p')
        if &modified
          " TODO: find existing window
          exe 'vsplit ' . fnameescape(fname)
          let s:sourcewin = win_getid(winnr())
        else
          exe 'edit ' . fnameescape(fname)
        endif
      endif
      exe 'goto ' . bytepos
      let lnum = line('.')
      exe 'sign unplace ' . s:pc_id
      exe 'sign place ' . s:pc_id . ' line=' . lnum . ' name=debugPC file=' . fname
      setlocal signcolumn=yes
    elseif
      echomsg fname . ' not readable '
    endif
    call ch_log('DEBUG endif ')

    call win_gotoid(wid)
  endif

endfunc

let s:BreakpointSigns = []

func s:CreateBreakpoint(nr)
  call ch_log("DEBUG CreateBreakpoing")
  if index(s:BreakpointSigns, a:nr) == -1
    call ch_log("DEBUG if ok ")
    call ch_log("DEBUG a:nr " . a:nr)
    call add(s:BreakpointSigns, a:nr)
    call ch_log("DEBUG s:BreakpointSigns " . join(s:BreakpointSigns))
    let signcmd = "sign define debugBreakpoint" . a:nr . " text=" . a:nr . " texthl=debugBreakpoint"
    exe signcmd
    call ch_log("DEBUG sign cmd " . signcmd)
  else
    call ch_log("DEBUG if pas ok ") . index(s:BreakpointSigns, a:nr)
  endif
endfunc

" Handle setting a breakpoint
" Will update the sign that shows the breakpoint
func s:HandleNewBreakpoint(msg)
  let r_line        = '\(\w\+\)\s\(\d\+\)\s\(\w\+\)\s\(.\+\):\s\(\w\+\)\s\(.\+\),\s\(\w\+\)\s\(\d\+\),\s\(\w\+\)'
  let m = matchlist(a:msg, r_line)
  call ch_log("DEBUGGGGGGGGGGGG          inside " . len(m))
  if len(m) == 10
    let wid = win_getid(winnr())

    let nr = m[2]
    let fname = m[6]
    let lnum = m[8]
    call ch_log('numbreakpoint ' . nr)
    call ch_log('file ' . fname)
    call ch_log('line ' . lnum)
    if fname[0] != '/'
"       let fname = expand('%:p:h') . '/' . fname
        let fname = g:orig_dir . '/' . fname
    endif
    call s:GotoSourcewinOrCreateIt()
    if expand('%:p') != fnamemodify(fname, ':p')
        if &modified
            " TODO: find existing window
            exe 'vsplit ' . fnameescape(fname)
            let s:sourcewin = win_getid(winnr())
        else
            exe 'edit ' . fnameescape(fname)
        endif
    endif
    call s:CreateBreakpoint(nr)
    call win_gotoid(wid)
  elseif a:msg =~ "Breakpoint:"
    return
  else
    echoerr 'regex not robust enough ?!'
  endif
 
  if has_key(s:breakpoints, nr)
    let entry = s:breakpoints[nr]
  else
    let entry = {}
    let s:breakpoints[nr] = entry
  endif

  let entry['fname'] = fname
  let entry['lnum'] = lnum

  if bufloaded(fname)
    call s:PlaceSign(nr, entry)
  endif

endfunc

func s:PlaceSign(nr, entry)
  exe 'sign place ' . (s:break_id + a:nr) . ' line=' . a:entry['lnum'] . ' name=debugBreakpoint' . a:nr . ' file=' . a:entry['fname']
  let a:entry['placed'] = 1
endfunc

" Handle a BufRead autocommand event: place any signs.
func s:BufRead()
  let fname = expand('<afile>:p')
  for [nr, entry] in items(s:breakpoints)
    if entry['fname'] == fname
      call s:PlaceSign(nr, entry)
    endif
  endfor
endfunc

" Handle a BufUnloaded autocommand event: unplace any signs.
func s:BufUnloaded()
  let fname = expand('<afile>:p')
  for [nr, entry] in items(s:breakpoints)
    if entry['fname'] == fname
      let entry['placed'] = 0
    endif
  endfor
endfunc

let &cpo = s:keepcpo
unlet s:keepcpo
