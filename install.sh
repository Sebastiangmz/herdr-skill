#!/bin/sh
# herdr-skill installer — download-agnostic, harness-agnostic.
#
# Installs the `herdr` agent skill into the AI coding harness of your choice.
# Works run locally from a checkout, or piped straight from GitHub:
#
#   curl -fsSL https://raw.githubusercontent.com/Sebastiangmz/herdr-skill/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/Sebastiangmz/herdr-skill/main/install.sh | sh -s -- --target claude --yes
#   ./install.sh --dir ~/my-tool/skills          # any SKILL.md-compatible tool
#   ./install.sh --list
#
# Flags:
#   -t, --target <name>   claude | claude-project | omp | portable
#   -d, --dir <path>      install into <path>/herdr (any tool that loads SKILL.md skills)
#   -y, --yes             don't prompt; overwrite an existing install
#   -l, --list            list supported targets and exit
#   -h, --help            show this help
set -eu

REPO="Sebastiangmz/herdr-skill"
BRANCH="main"
NAME="herdr"
RAW="https://raw.githubusercontent.com/$REPO/$BRANCH"
TARBALL="https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz"

TARGET=""; DIR=""; YES=0

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'install: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() { sed -n '2,26p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'; }

list_targets() {
  cat >&2 <<'EOF'
Supported targets:
  claude          Claude Code, global      -> ~/.claude/skills/herdr
  claude-project  Claude Code, this repo   -> ./.claude/skills/herdr
  omp             OMP / oh-my-pi, global   -> ~/.omp/agent/skills/herdr
  cursor          Cursor, this repo        -> ./.cursor/skills/herdr
  agents          Vendor-neutral, project  -> ./.agents/skills/herdr
  portable        Tools without skills     -> ~/.herdr-skill  (+ paste-in instructions)
  --dir <path>    Any SKILL.md-compatible  -> <path>/herdr
EOF
}

# ---- locate the skill source (local checkout or download) --------------------
find_source() {
  # If this script sits next to the skill, use the local checkout.
  _self=""
  if [ -n "${0:-}" ] && [ "${0#/}" != "$0" -o -e "$0" ]; then
    _self=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || true)
  fi
  if [ -n "$_self" ] && [ -f "$_self/SKILL.md" ]; then
    printf '%s' "$_self"; return 0
  fi
  # Otherwise download a tarball of the public repo.
  have tar || die "need 'tar' to download the skill"
  _tmp=$(mktemp -d 2>/dev/null || mktemp -d -t herdr)
  log "Downloading $NAME skill from $REPO ..."
  if have curl; then
    curl -fsSL "$TARBALL" | tar -xz -C "$_tmp" || die "download failed"
  elif have wget; then
    wget -qO- "$TARBALL" | tar -xz -C "$_tmp" || die "download failed"
  else
    die "need curl or wget to download the skill"
  fi
  # tarball extracts to herdr-skill-<branch>/
  printf '%s' "$_tmp/$(basename "$REPO")-$BRANCH"
}

# ---- copy the skill payload into <root>/herdr --------------------------------
install_skill() {
  _src=$1; _root=$2
  [ -f "$_src/SKILL.md" ] || die "source has no SKILL.md ($_src)"
  _dest="$_root/$NAME"
  mkdir -p "$_root"
  if [ -e "$_dest" ] && [ "$YES" -ne 1 ]; then
    printf 'Overwrite existing %s ? [y/N] ' "$_dest" >&2
    read _ans </dev/tty 2>/dev/null || _ans=""
    case "$_ans" in y|Y|yes|YES) ;; *) die "aborted";; esac
  fi
  [ -e "$_dest" ] && rm -rf "$_dest"
  mkdir -p "$_dest/references" "$_dest/bin"
  cp "$_src/SKILL.md" "$_dest/SKILL.md"
  cp "$_src"/references/*.md "$_dest/references/"
  cp "$_src/bin/herd.sh" "$_dest/bin/herd.sh"
  chmod +x "$_dest/bin/herd.sh" 2>/dev/null || true
  printf '%s' "$_dest"
}

# ---- interactive menu (reads /dev/tty so `curl | sh` can still prompt) --------
choose_target() {
  [ -r /dev/tty ] || die "no target given and no interactive terminal (use --target or --dir)"
  {
    echo "Where should the herdr skill be installed?"
    _c=""; [ -d "$HOME/.claude" ] && _c=" (detected)"
    _o=""; [ -d "$HOME/.omp" ] && _o=" (detected)"
    echo "  1) Claude Code (global)   ~/.claude/skills$_c"
    echo "  2) Claude Code (project)  ./.claude/skills"
    echo "  3) OMP / oh-my-pi         ~/.omp/agent/skills$_o"
    echo "  4) Cursor (project)       ./.cursor/skills"
    echo "  5) Vendor-neutral (project) ./.agents/skills"
    echo "  6) Custom skills directory (any SKILL.md tool)"
    echo "  7) Portable + paste-in instructions (any other tool)"
    printf 'Choice [1-7]: '
  } >&2
  read _c </dev/tty
  case "$_c" in
    1) TARGET=claude;; 2) TARGET=claude-project;; 3) TARGET=omp;;
    4) TARGET=cursor;; 5) TARGET=agents;;
    6) printf 'Skills directory path: ' >&2; read DIR </dev/tty; TARGET=dir;;
    7) TARGET=portable;;
    *) die "invalid choice";;
  esac
}

# ---- arg parsing -------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -t|--target) TARGET=${2:-}; shift 2;;
    -d|--dir)    DIR=${2:-}; TARGET=dir; shift 2;;
    -y|--yes)    YES=1; shift;;
    -l|--list)   list_targets; exit 0;;
    -h|--help)   usage; exit 0;;
    *) die "unknown argument '$1' (see --help)";;
  esac
done

[ -n "$TARGET" ] || choose_target

SRC=$(find_source)

case "$TARGET" in
  claude)          ROOT="$HOME/.claude/skills";;
  claude-project)  ROOT="$PWD/.claude/skills";;
  omp)             ROOT="$HOME/.omp/agent/skills";;
  cursor)          ROOT="$PWD/.cursor/skills";;
  agents)          ROOT="$PWD/.agents/skills";;
  dir)             [ -n "$DIR" ] || die "--dir requires a path"
                   ROOT=$(CDPATH= cd -- "$DIR" 2>/dev/null && pwd || printf '%s' "$DIR");;
  portable)        ROOT="$HOME";;   # special-cased below
  *) die "unknown target '$TARGET' (see --list)";;
esac

if [ "$TARGET" = portable ]; then
  DEST="$HOME/.herdr-skill"
  YES=1  # portable location is ours; safe to refresh
  [ -e "$DEST" ] && rm -rf "$DEST"
  mkdir -p "$DEST/references" "$DEST/bin"
  cp "$SRC/SKILL.md" "$DEST/SKILL.md"
  cp "$SRC"/references/*.md "$DEST/references/"
  cp "$SRC/bin/herd.sh" "$DEST/bin/herd.sh"; chmod +x "$DEST/bin/herd.sh" 2>/dev/null || true
  log ""
  log "Installed (portable) at: $DEST"
  log "Your tool does not auto-load SKILL.md skills, so add this line to its global"
  log "instructions / rules file (e.g. AGENTS.md, .cursorrules, system prompt):"
  log ""
  log "  When operating Herdr (HERDR_ENV=1) or orchestrating agents in Herdr,"
  log "  read the skill at ~/.herdr-skill/SKILL.md and follow it."
  log ""
  exit 0
fi

DEST=$(install_skill "$SRC" "$ROOT")
log ""
log "Installed the '$NAME' skill at: $DEST"
case "$TARGET" in
  claude)         log "Claude Code loads it automatically as the 'herdr' skill (new session).";;
  claude-project) log "Claude Code loads it for this project (new session). Commit .claude/skills/herdr to share it.";;
  omp)            log "OMP surfaces it as skill://herdr next session.";;
  cursor)         log "Cursor discovers it from .cursor/skills (also reads .agents/skills). Commit it to share.";;
  agents)         log "Vendor-neutral .agents/skills — read by Cursor, Codex, and other Agent Skills tools.";;
  dir)            log "If your tool loads SKILL.md skills from that directory, it will pick up 'herdr'.";;
esac
log "Verify the helper: $DEST/bin/herd.sh help"
