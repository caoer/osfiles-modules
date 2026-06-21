--[[
═══════════════════════════════════════════════════════════════════════════════
                              LazyVim CHEAT SHEET
═══════════════════════════════════════════════════════════════════════════════

NOTE: This file is for reference only. The interactive picker is in
      lua/plugins/cheatsheet.lua

HOW TO USE:
  :Cheatsheet        - Open interactive picker (recommended)
  <leader>?          - Quick cheatsheet picker keymap

═══════════════════════════════════════════════════════════════════════════════

┌─────────────────────────────────────────────────────────────────────────────┐
│ SPELLCHECK                                                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│ <leader>us   Toggle spellcheck on/off                                      │
│ zg           Add word to dictionary - "z = spell, g = Good word"           │
│ zw           Mark word as Wrong/bad                                        │
│ zug          Undo Good - remove from dictionary                            │
│ ]s           Jump to next misspelled word - ] goes forward, s = spell     │
│ [s           Jump to previous misspelled word - [ goes backward            │
│ z=           Show spelling suggestions - "z = spell, = means equals/list"  │
│                                                                             │
│ Mnemonic: "z" prefix = "zzz" (sleep/spell), or last letter in alphabet!   │
│           Think: z is rarely used, perfect for spell commands              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ NAVIGATION (Flash.nvim)                                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│ s            2-char forward jump - "s = search"                            │
│ S            Treesitter search - "capital S = Syntax search"               │
│ f{char}      Jump forward to character - "f = find forward"                │
│ F{char}      Jump backward to character - "capital F = Find backward"      │
│ t{char}      Jump forward until (before) char - "t = 'til (until)"         │
│ T{char}      Jump backward until (after) char - "capital T = 'Til back"    │
│ ;            Repeat last f/F/t/T in same direction - "semicolon = same"    │
│ ,            Repeat last f/F/t/T opposite direction - "comma = contrary"   │
│ /{pattern}   Search forward - "/ = forward slash points right →"           │
│ ?{pattern}   Search backward - "? looks like / but reversed"               │
│ n            Next match - "n = next"                                       │
│ N            Previous match - "capital N = opposite of next"               │
│ <C-s>        Toggle Flash labels in search mode                            │
│                                                                             │
│ Memory tip: Lowercase = forward, Uppercase = backward (f/F, t/T, n/N)     │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ FILE FINDING                                                                │
├─────────────────────────────────────────────────────────────────────────────┤
│ <leader><leader>  Find files (respects .gitignore)                         │
│ <leader>fF        Find ALL files (gitignored too) - "capital F = FULL"     │
│ <leader>ff        Find files - "f = files" (same as space-space)           │
│ <leader>fg        Git files - "g = git"                                    │
│ <leader>fr        Recent files - "r = recent"                              │
│ <leader>/         Grep in files                                            │
│ <leader>sg        Search grep - "s = search, g = grep"                     │
│                                                                             │
│ Memory tip: <leader>f = "find" prefix, second letter specifies what:       │
│             f=files, F=FULL(all), g=git, r=recent                          │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ WINDOW MANAGEMENT                                                           │
├─────────────────────────────────────────────────────────────────────────────┤
│ <leader>h    Go to left window - "h = left"                                │
│ <leader>j    Go to below window - "j = down"                               │
│ <leader>k    Go to above window - "k = up"                                 │
│ <leader>l    Go to right window - "l = right"                              │
└─────────────────────────────────────────────────────────────────────────────┘

═══════════════════════════════════════════════════════════════════════════════
--]]

-- This file is just documentation
-- The actual picker plugin is in lua/plugins/cheatsheet.lua
return {}
