# Terminal colors configuration
# Cross-platform: macOS, Linux (Debian), Ghostty (tab colors at the end)
# Vesper-inspired color palette

# ============================================================================
# Platform detection
# ============================================================================

_is_macos() { [[ "$OSTYPE" == darwin* ]]; }
_is_linux() { [[ "$OSTYPE" == linux* ]]; }

# ============================================================================
# LS_COLORS - GNU ls and completion (Linux, macOS with GNU coreutils/eza)
# ============================================================================

export LS_COLORS="\
di=1;34:\
ln=1;36:\
so=1;35:\
pi=33:\
ex=1;32:\
bd=1;33:\
cd=1;33:\
su=30;41:\
sg=30;43:\
tw=30;42:\
ow=34;42:\
*.tar=1;31:\
*.tgz=1;31:\
*.arc=1;31:\
*.arj=1;31:\
*.taz=1;31:\
*.lha=1;31:\
*.lz4=1;31:\
*.lzh=1;31:\
*.lzma=1;31:\
*.tlz=1;31:\
*.txz=1;31:\
*.tzo=1;31:\
*.t7z=1;31:\
*.zip=1;31:\
*.z=1;31:\
*.dz=1;31:\
*.gz=1;31:\
*.lrz=1;31:\
*.lz=1;31:\
*.lzo=1;31:\
*.xz=1;31:\
*.zst=1;31:\
*.tzst=1;31:\
*.bz2=1;31:\
*.bz=1;31:\
*.tbz=1;31:\
*.tbz2=1;31:\
*.tz=1;31:\
*.deb=1;31:\
*.rpm=1;31:\
*.jar=1;31:\
*.war=1;31:\
*.ear=1;31:\
*.sar=1;31:\
*.rar=1;31:\
*.alz=1;31:\
*.ace=1;31:\
*.zoo=1;31:\
*.cpio=1;31:\
*.7z=1;31:\
*.rz=1;31:\
*.cab=1;31:\
*.wim=1;31:\
*.swm=1;31:\
*.dwm=1;31:\
*.esd=1;31:\
*.jpg=1;35:\
*.jpeg=1;35:\
*.mjpg=1;35:\
*.mjpeg=1;35:\
*.gif=1;35:\
*.bmp=1;35:\
*.pbm=1;35:\
*.pgm=1;35:\
*.ppm=1;35:\
*.tga=1;35:\
*.xbm=1;35:\
*.xpm=1;35:\
*.tif=1;35:\
*.tiff=1;35:\
*.png=1;35:\
*.svg=1;35:\
*.svgz=1;35:\
*.mng=1;35:\
*.pcx=1;35:\
*.mov=1;35:\
*.mpg=1;35:\
*.mpeg=1;35:\
*.m2v=1;35:\
*.mkv=1;35:\
*.webm=1;35:\
*.webp=1;35:\
*.ogm=1;35:\
*.mp4=1;35:\
*.m4v=1;35:\
*.mp4v=1;35:\
*.vob=1;35:\
*.qt=1;35:\
*.nuv=1;35:\
*.wmv=1;35:\
*.asf=1;35:\
*.rm=1;35:\
*.rmvb=1;35:\
*.flc=1;35:\
*.avi=1;35:\
*.fli=1;35:\
*.flv=1;35:\
*.gl=1;35:\
*.dl=1;35:\
*.xcf=1;35:\
*.xwd=1;35:\
*.yuv=1;35:\
*.cgm=1;35:\
*.emf=1;35:\
*.ogv=1;35:\
*.ogx=1;35:\
*.aac=36:\
*.au=36:\
*.flac=36:\
*.m4a=36:\
*.mid=36:\
*.midi=36:\
*.mka=36:\
*.mp3=36:\
*.mpc=36:\
*.ogg=36:\
*.ra=36:\
*.wav=36:\
*.oga=36:\
*.opus=36:\
*.spx=36:\
*.xspf=36:\
*.pdf=1;33:\
*.doc=1;33:\
*.docx=1;33:\
*.xls=1;33:\
*.xlsx=1;33:\
*.ppt=1;33:\
*.pptx=1;33:\
*.odt=1;33:\
*.ods=1;33:\
*.odp=1;33:\
*.md=33:\
*.txt=33:\
*.log=90"

# ============================================================================
# LSCOLORS - BSD ls (macOS native)
# ============================================================================
# Format: foreground+background pairs for:
# directory, symlink, socket, pipe, executable, block special, char special,
# executable with setuid, executable with setgid, dir writable to others with sticky bit,
# dir writable to others without sticky bit
export LSCOLORS="ExGxFxdaCxDaDahbadacec"

# ============================================================================
# Colored man pages (works in all terminals)
# ============================================================================

export LESS_TERMCAP_mb=$'\e[1;31m'      # begin bold
export LESS_TERMCAP_md=$'\e[1;34m'      # begin blink (headers)
export LESS_TERMCAP_me=$'\e[0m'         # end mode
export LESS_TERMCAP_so=$'\e[1;33m'      # begin standout (info box)
export LESS_TERMCAP_se=$'\e[0m'         # end standout
export LESS_TERMCAP_us=$'\e[1;32m'      # begin underline (emphasis)
export LESS_TERMCAP_ue=$'\e[0m'         # end underline

# ============================================================================
# FZF colors (Vesper palette)
# ============================================================================

export FZF_DEFAULT_OPTS="\
--color=bg+:#262626,bg:#1C1C1C,spinner:#4EC994,hl:#FFC799 \
--color=fg:#A0A0A0,header:#6B6B6B,info:#D4A656,pointer:#4EC994 \
--color=marker:#A8C97F,fg+:#FFFFFF,prompt:#FFC799,hl+:#FFC799 \
--height=40% \
--layout=reverse \
--border \
--info=inline"

# ============================================================================
# Bat configuration (better cat)
# ============================================================================

export BAT_THEME="OneHalfDark"

# Detect bat command (Debian uses 'batcat' due to naming conflict)
if command -v batcat &>/dev/null; then
    _bat_cmd="batcat"
elif command -v bat &>/dev/null; then
    _bat_cmd="bat"
else
    _bat_cmd=""
fi

# Use bat as man pager for syntax highlighting
if [[ -n "$_bat_cmd" ]]; then
    export MANPAGER="sh -c 'col -bx | $_bat_cmd -l man -p'"
fi

# ============================================================================
# Aliases for colorized tools
# ============================================================================

# eza (better ls) - preferred, works on both platforms
if command -v eza &>/dev/null; then
    alias ls='eza --color=auto --group-directories-first'
    alias ll='eza -l --color=auto --group-directories-first --git'
    alias la='eza -la --color=auto --group-directories-first --git'
    alias lt='eza --tree --level=2 --color=auto'
    alias l='eza -1 --color=auto'
elif _is_macos; then
    # macOS BSD ls
    alias ls='ls -G'
    alias ll='ls -lG'
    alias la='ls -laG'
    alias l='ls -1G'
else
    # GNU ls (Linux)
    alias ls='ls --color=auto'
    alias ll='ls -l --color=auto'
    alias la='ls -la --color=auto'
    alias l='ls -1 --color=auto'
fi

# bat (better cat) - handle Debian's batcat
if [[ -n "$_bat_cmd" ]]; then
    alias bat="$_bat_cmd"
    alias cat="$_bat_cmd --paging=never"
    alias catp="$_bat_cmd"  # with paging
fi

# Colored grep/diff (works on both platforms)
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias diff='diff --color=auto'

# ripgrep with color
if command -v rg &>/dev/null; then
    alias rg='rg --color=auto'
fi

# fd (better find) - Debian uses 'fdfind' due to naming conflict
if command -v fdfind &>/dev/null; then
    alias fd='fdfind'
fi

# Cleanup
unset _bat_cmd

# ============================================
# Tab Color Functions for Ghostty
# ============================================
# Uses iTerm2's OSC 6 escape sequence (supported by Ghostty)

# Set tab color from hex (e.g., tab-color "#FF6B6B")
tab-color() {
  local hex="${1#\#}"
  local r=$((16#${hex:0:2}))
  local g=$((16#${hex:2:2}))
  local b=$((16#${hex:4:2}))
  printf '\033]6;1;bg;red;brightness;%d\a' "$r"
  printf '\033]6;1;bg;green;brightness;%d\a' "$g"
  printf '\033]6;1;bg;blue;brightness;%d\a' "$b"
}

# Reset tab color to default
tab-reset() {
  printf '\033]6;1;bg;*;default\a'
}

# ============================================
# Preset Colors (Vesper theme inspired)
# ============================================
tab-work()    { tab-color "#FFC799"; }  # Orange/amber
tab-dev()     { tab-color "#A8C97F"; }  # Green
tab-server()  { tab-color "#E06C75"; }  # Red/coral
tab-docs()    { tab-color "#61AFEF"; }  # Blue

# ============================================
# Auto-Color by Directory
# ============================================
_auto_tab_color_dir() {
  case "$PWD" in
    */work/*)      tab-color "#FFC799" ;;  # Work projects = orange
    */Developer/*) tab-color "#A8C97F" ;;  # Dev projects = green
    *)             ;;  # Keep current color for other dirs
  esac
}

# Register hook (uncomment to enable)
# chpwd_functions+=(_auto_tab_color_dir)

# ============================================
# Auto-Color by SSH Host
# ============================================
ssh() {
  local host="$1"
  case "$host" in
    *prod*|*production*) tab-color "#E06C75" ;;  # Production = red
    *staging*|*stage*)   tab-color "#FFC799" ;;  # Staging = orange
    *dev*|*development*) tab-color "#A8C97F" ;;  # Dev = green
  esac
  command ssh "$@"
  tab-reset  # Reset after SSH session ends
}
