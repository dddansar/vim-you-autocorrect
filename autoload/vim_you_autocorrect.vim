" Set cpoptions so we can use line continuation
let s:save_cpo = &cpoptions
set cpoptions&vim

" ***************
" *             *
" * Autocorrect *
" *             *
" ***************

function! s:autocorrect(...) abort
  let force = a:0 && a:1
  let prev_lnum = get(s:, 'last_lnum', 0)
  let s:last_lnum = line('.')
  let before = strpart(getline('.'), 0, col('.') - 1)
  let ctx_lnum = line('.')

  if force
    " Esc: the word right before the cursor
    let token = matchstr(before, '\S*$')
    let ctx = before
    let tok_col = len(before) - len(token) + 1
  elseif before =~# '^\s*$'
    " Enter: only if the line just changed, and the previous line ends in a word
    if line('.') == 1 || line('.') == prev_lnum
      return
    endif
    let ctx_lnum = line('.') - 1
    let ctx = getline(ctx_lnum)
    let token = matchstr(ctx, '\S*$')
    let tok_col = len(ctx) - len(token) + 1
  elseif before =~# '[A-Za-z''][ \t.,;:!?)\]"]$'
    " Exactly one delimiter right after a word (2nd+ space fails this)
    let token = matchstr(strpart(before, 0, len(before) - 1), '\S*$')
    let ctx = before
    let tok_col = len(before) - len(token)
  else
    return
  endif

  " Only plain words: skip anything with other characters
  " and anything with a capital after the first letter
  if token !~# '^[A-Za-z'']\+$' || token =~# '^.\+[A-Z]'
    return
  endif

  " spellbadword() only reports the FIRST bad word in the string, so we must
  " not hand it the whole line: an earlier unknown word would be reported
  " instead of the token. Instead, build a minimal context: a known-good
  " stand-in word, then whatever non-word characters (e.g. ". ") sat between
  " the previous word and the token, then the token itself. That's all
  " Vim needs to decide whether the token starts a sentence.
  let lead = strpart(ctx, 0, tok_col - 1)
  if lead =~# '^\s*$'
    " Token is first on its line: look at the end of the previous line.
    let prev_text = ctx_lnum > 1 ? getline(ctx_lnum - 1) : ''
    if ctx_lnum == 1 || prev_text =~# '^\s*$'
      let tail = '. '
    else
      let tail = s:sentence_tail(prev_text) . ' '
    endif
  else
    let tail = s:sentence_tail(lead)
  endif
  let sctx = 'Ok' . tail . token
  let bad = spellbadword(sctx)
  if empty(bad[0])
    return
  endif

  " Capitalization error on the word just typed: just capitalize it
  if bad[1] ==# 'caps' && bad[0] ==# token
    let l = getline(ctx_lnum)
    let cap = toupper(token[0]) . token[1:]
    call setline(ctx_lnum, strpart(l, 0, tok_col - 1) . cap . strpart(l, tok_col - 1 + len(token)))

    " Record the correction so highlight, undo and jump work
    let spell_pos = [0, ctx_lnum, tok_col, 0]
    let w:vim_you_autocorrect_last_pos = copy(spell_pos)
    let w:vim_you_autocorrect_last_edit_pos = getpos('.')
    let w:vim_you_autocorrect_before_correction = token
    let w:vim_you_autocorrect_after_correction = cap
    let w:vim_you_autocorrect_correct_count = 1
    call s:highlight_correction(spell_pos)
    return
  endif

  " Ordinary misspelling: check the token on its own. Without sentence
  " context spellbadword() never reports 'caps', only real misspellings.
  if spellbadword(token)[0] !=# token
    return
  endif

  let edit_pos = getpos('.')
  let spell_pos = [0, ctx_lnum, tok_col, 0]

  " If the cursor has gone back before where this insert started (e.g. by
  " backspacing), that point becomes the new start of the session.
  if s:pos_before(edit_pos, s:start_pos)
    let s:start_pos = edit_pos
  endif
  " Don't touch words that began before this insert session
  if s:pos_before(spell_pos, s:start_pos)
    return
  endif

  try
    call cursor(ctx_lnum, tok_col)
    let w:vim_you_autocorrect_correct_count = 1
    let adjustment = s:correct_error(spell_pos, edit_pos, 1)
    call s:update_position(edit_pos, spell_pos,
          \ len(w:vim_you_autocorrect_before_correction), adjustment)
  finally
    silent! call setpos('.', edit_pos)
  endtry
endfunction

" Reduce the text before a token to the ASCII punctuation/space that decides
" whether the token starts a sentence. Whatever came before the punctuation is irrelevant.
function! s:sentence_tail(text) abort
  if a:text =~# '[.!?][)\]"'']*\s*$'
    return '. '
  endif
  return substitute(matchstr(a:text, '[^[:alnum:]]*$'), '[^\x00-\x7f]', '', 'g')
endfunction


" Returns true if pos1 is earlier in the buffer than pos2
function! s:pos_before(pos1, pos2) abort
  return a:pos1[1] < a:pos2[1]
        \ || a:pos1[1] == a:pos2[1] && a:pos1[2] < a:pos2[2]
endfunction


" Returns whether or not it changed pos
" N.B. Don't really care what happens to cursor if it's between the
"      end before and the end after the change. There's no obvious
"      "right" answer. Therefore arbitrarily selecting the "before"
"      end. Could also have used the "after" or the max or the min.
"
function! s:update_position(pos, correction_pos, length_before_change, adjustment)
  if a:adjustment != 0
        \ && a:pos[1] == a:correction_pos[1]
        \ && a:pos[2] > a:correction_pos[2] + a:length_before_change
    let a:pos[2] = a:pos[2] + a:adjustment
    return 1
  endif

  return 0
endfunction


function! s:correct_error(spell_pos, edit_pos, index)
  " Not sure why I originally decided to use window variables and not buffer
  " variables, but it makes sense for the things that are window-local
  " (matches, 'spell') and works quite well.
  "
  " Save current spell_pos and edit_pos so I can jump back and re-run this
  " function to pick different corrections with   Nz=
  let w:vim_you_autocorrect_last_pos = copy(a:spell_pos)
  let w:vim_you_autocorrect_last_edit_pos = copy(a:edit_pos)

  " Correct the error.
  let old_line = getline('.')
  execute 'keepjumps normal!'  a:index . 'z='
  let new_line = getline('.')

  let position_adjustment = 0

  " Start and end of the misspelled word
  let start_index = a:spell_pos[2] - 1
  let end_index = a:edit_pos[2] - 3

  if a:edit_pos[1] == a:spell_pos[1]
    " Adjust cursor position if the replacement is a different length
    " and is on same line as us.
    let position_adjustment = strlen(new_line) - strlen(old_line)

    " Save the original and corrected spellings of the most recent
    " autocorrection so we can revert it.
    "
    " Problem occurs when correction "include[s] other text". Need to include
    " this other text in our saved before/after. e.g. when "anotherr test" is
    " replaced by "another retest", we need to include the space in the before and
    " the "e" in the after.
    "
    " Check for differences in the lines after the current end_index, and
    " extend the index if any are found. I don't know how far we have to go,
    " so far the only examples I've found include a single extra space, but
    " arbitrarily doing it for 10 more bytes.
    for i in range(end_index + 1, end_index + 10)
      if old_line[i] != new_line[i + position_adjustment]
        let end_index = i
      endif
    endfor
    let w:vim_you_autocorrect_before_correction = old_line[start_index:end_index]
    let w:vim_you_autocorrect_after_correction = new_line[start_index:end_index + position_adjustment]
  else
    " We got here via Enter: the misspelled word is the last one on the
    " previous line, so everything from its start to the end of the line is
    " the before/after text.
    let w:vim_you_autocorrect_before_correction = old_line[start_index:]
    let w:vim_you_autocorrect_after_correction = new_line[start_index:]
  endif
  call s:highlight_correction(a:spell_pos)

  return position_adjustment
endfunction

" ****************
" *              *
" * Highlighting *
" *              *
" ****************

function! s:highlight_correction(spell_pos)
  " Clear any existing highlight (and timer)
  call s:clear_highlight()

  if get(g:, 'vim_you_autocorrect_disable_highlighting', 0)
    return
  endif

  " Highlight
  if exists('w:vim_you_autocorrect_after_correction')
    let s:match_id = matchaddpos('AutocorrectGood',
          \ [[a:spell_pos[1],
          \ a:spell_pos[2],
          \ len(w:vim_you_autocorrect_after_correction)]])
    if has('timers')
      let s:timer_id = timer_start(2000, {timer_id -> s:clear_highlight()})
    endif
    let s:win_id = win_getid(winnr())
  endif
endfunction

" Clear the match of the autocorrected word
function! s:clear_highlight()
  " Cancel any existing timer
  if exists('s:timer_id')
    call timer_stop(s:timer_id)
  endif

  " Clear the highlight
  if exists('s:match_id')
    let winnr = winnr()
    let tabpagenr = tabpagenr()
    let highlight_tabwin = win_id2tabwin(s:win_id)
    if highlight_tabwin != [0, 0]
      execute highlight_tabwin[0] . 'tabdo' highlight_tabwin[1] . 'windo call matchdelete(' . s:match_id . ')'
      execute tabpagenr . 'tabnext'
      execute winnr . 'wincmd w'
    endif
    unlet s:match_id
  endif
endfunction

" *************************
" *                       *
" * Enable/Disable Plugin *
" *                       *
" *************************

function! vim_you_autocorrect#enable_autocorrect() abort
  " Save 'spell'
  " FIXME: 'spell' is window local, but the autocommands are buffer local.
  if !&spell
    " We'll need to unset spell when we disable the plugin
    let w:vim_you_autocorrect_reset_spell = 1
    setlocal spell
  endif

  silent! call <SID>remove_autocommands()
  augroup vim_you_autocorrect
    autocmd InsertEnter <buffer> call <SID>reset_start_pos()
    autocmd CursorMovedI <buffer> call <SID>autocorrect()
    autocmd InsertLeavePre <buffer> call <SID>autocorrect(1)
    if !has('timers')
      autocmd CursorHold <buffer> call <SID>clear_highlight()
      autocmd CursorHoldI <buffer> call <SID>clear_highlight()
    endif
  augroup END

  " highlight link AutocorrectGood SpellBad
  highlight link AutocorrectGood DiffChange
endfunction

function! vim_you_autocorrect#disable_autocorrect() abort
  " We don't really want to report errors to the user if the attempt to disable
  " when it's already disabled: use `silent!`
  silent! call <SID>remove_autocommands()

  " Unset spell if we set it
  if exists('w:vim_you_autocorrect_reset_spell')
    unlet w:vim_you_autocorrect_reset_spell
    setlocal nospell
  endif
endfunction

function! s:reset_start_pos() abort
  let s:start_pos = getpos('.')
endfunction

function! s:remove_autocommands() abort
  autocmd! vim_you_autocorrect InsertEnter,CursorMovedI,InsertLeavePre <buffer>
endfunction

" *************
" *           *
" * Undo Last *
" *           *
" *************

function! vim_you_autocorrect#undo_last() abort
  if exists('w:vim_you_autocorrect_last_pos')
    let [corrected_line, sp, ep] = s:get_line_and_positions()
    if corrected_line[sp:ep - 1] ==# w:vim_you_autocorrect_after_correction
      let w:vim_you_autocorrect_redo = [
            \ copy(w:vim_you_autocorrect_last_pos),
            \ w:vim_you_autocorrect_before_correction,
            \ w:vim_you_autocorrect_after_correction]
    endif
  endif

  let length_before_change = len(w:vim_you_autocorrect_after_correction)
  let adjustment = s:undo_last()

  " Adjust the cursor position to account for changes in length.
  "
  " N.B. We're adjusting the position of the cursor correctly here, but
  "      marks on the line won't move. In particular, the `` mark isn't
  "      moved correctly, so you can't jump back to the correct position
  "      in e.g. a mapping.
  let edit_pos = getpos('.')
  if s:update_position(edit_pos, w:vim_you_autocorrect_last_pos, length_before_change, adjustment)
    silent! call setpos('.', edit_pos)
  endif

  if exists('w:vim_you_autocorrect_last_pos')
    unlet w:vim_you_autocorrect_last_pos
  endif

  call s:reset_start_pos()
endfunction

function! s:undo_last() abort
  let adjustment = 0

  if exists('w:vim_you_autocorrect_last_pos')
    let [corrected_line, sp, ep] = s:get_line_and_positions()

    " Only undo if the correction hasn't been changed subsequently
    if corrected_line[sp:ep - 1] ==# w:vim_you_autocorrect_after_correction
      let edit_pos = getpos('.')

      if sp > 0
        let line_before = corrected_line[:sp - 1]
      else
        let line_before = ''
      endif
      let line_after = corrected_line[ep:]

      call setline(w:vim_you_autocorrect_last_pos[1],
            \ line_before .
            \ w:vim_you_autocorrect_before_correction .
            \ line_after)

      let adjustment = strlen(w:vim_you_autocorrect_before_correction) -
            \ strlen(w:vim_you_autocorrect_after_correction)

      call s:clear_highlight()
    endif
  endif

  return adjustment
endfunction

function! vim_you_autocorrect#redo_last() abort
  if !exists('w:vim_you_autocorrect_redo')
    return
  endif
  let [pos, before, after] = w:vim_you_autocorrect_redo
  let lnum = pos[1]
  let sp = pos[2] - 1
  let line = getline(lnum)
  if strpart(line, sp, strlen(before)) !=# before
    let sp = stridx(line, before)
    if sp < 0
      return
    endif
    let pos[2] = sp + 1
  endif
  call setline(lnum, strpart(line, 0, sp) . after . strpart(line, sp + strlen(before)))
  if line('.') == lnum && col('.') - 1 > sp
    call cursor(lnum, col('.') + strlen(after) - strlen(before))
  endif

  " Restore the plugin's state so undo (and Jump) work again
  let w:vim_you_autocorrect_last_pos = pos
  let w:vim_you_autocorrect_before_correction = before
  let w:vim_you_autocorrect_after_correction = after
  call s:reset_start_pos()
endfunction

" ****************
" *              *
" * Jump to Last *
" *              *
" ****************

function! vim_you_autocorrect#jump_to_last() abort
  call s:jump_to_last(0)
endfunction

function! s:jump_to_last(force_jump) abort
  if exists('w:vim_you_autocorrect_last_pos')
    let [corrected_line, sp, ep] = s:get_line_and_positions()

    " Only move if the correction hasn't been changed subsequently
    if a:force_jump || corrected_line[sp:ep - 1] ==# w:vim_you_autocorrect_after_correction
      " Add current position to the jumplist
      normal! m'

      " And jump
      silent! call setpos('.', w:vim_you_autocorrect_last_pos)
    endif
  endif
endfunction

" This gets the line, and the start and end positions of the word that was
" substituted in when making the correction.
function! s:get_line_and_positions() abort
  let corrected_line = getline(w:vim_you_autocorrect_last_pos[1])
  let sp = w:vim_you_autocorrect_last_pos[2] - 1
  let ep = sp + strlen(w:vim_you_autocorrect_after_correction)

  return [corrected_line, sp, ep]
endfunction

" ****************************
" *                          *
" * Next/Previous Correction *
" *                          *
" ****************************

function! vim_you_autocorrect#next() abort
  call s:bump_correction(1)
endfunction

function! vim_you_autocorrect#previous() abort
  call s:bump_correction(-1)
endfunction

function! s:bump_correction(direction) abort
  let edit_pos = getpos('.')
  if exists('w:vim_you_autocorrect_last_pos')
    try
      " Undo the correction
      let length_before_change = len(w:vim_you_autocorrect_after_correction)
      let adjustment = s:undo_last()

      " Update edit_pos and the cursor
      if s:update_position(edit_pos, w:vim_you_autocorrect_last_pos, length_before_change, adjustment)
        silent! call setpos('.', edit_pos)
      endif

      " Jump back to the error
      call s:jump_to_last(1)

      let w:vim_you_autocorrect_correct_count += a:direction
      if w:vim_you_autocorrect_correct_count < 1
        let w:vim_you_autocorrect_correct_count = 1
      endif

      let adjustment = s:correct_error(w:vim_you_autocorrect_last_pos,
            \ w:vim_you_autocorrect_last_edit_pos,
            \ w:vim_you_autocorrect_correct_count)
      call s:update_position(edit_pos, w:vim_you_autocorrect_last_pos, len(w:vim_you_autocorrect_before_correction), adjustment)
    finally
      " Reset the cursor position.
      silent! call setpos('.', edit_pos)
    endtry
  endif
endfunction

" Restore user's cpoptions setting
let &cpoptions = s:save_cpo
unlet s:save_cpo
