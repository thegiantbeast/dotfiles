#!/usr/bin/env python3
"""Session records for a Claude Code resume-picker, styled like `claude --resume`.

Modes:
  --browse            walk every session under ~/.claude/projects
  (stdin file list)   sessions matching a term, as paths from `rg -l`
  --preview <path>    render a session transcript's opening messages (for fzf)

--tsv emits NUL-separated multi-line records for fzf (--read0): each record is
`sid \t cwd \t <two visual lines> \t main-path`. Without --tsv it prints a plain
resume list.
"""
import glob
import json
import os
import re
import sys
import time

BASE = os.path.expanduser("~/.claude/projects")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
UUID_ANY = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

BOLD, RESET = "\033[1m", "\033[0m"
GRAY = "\033[38;5;245m"  # survives the highlight band better than plain dim


def rel_time(ts):
    d = max(0, int(time.time() - ts))
    for unit, secs in (("d", 86400), ("h", 3600), ("m", 60)):
        if d >= secs:
            return f"{d // secs}{unit} ago"
    return "just now"


def human_size(n):
    step = float(n)
    for unit in ("B", "KB", "MB", "GB"):
        if step < 1024 or unit == "GB":
            return f"{int(step)}{unit}" if unit == "B" else f"{step:.1f}{unit}"
        step /= 1024


def text_of(content):
    """Readable prose from a message .content (string or block list).

    Returns "" for tool-only messages so previews/titles skip them.
    """
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        texts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"]
        return "\n".join(t for t in texts if t)
    return ""


def unwrap_command(text):
    """Turn slash-command scaffolding into its real argument text, else pass through."""
    m = re.search(r"<command-args>(.*?)</command-args>", text, re.S)
    if m:
        return m.group(1).strip()
    if text.startswith("<command-") or text.startswith("<local-command"):
        return ""
    return text


def read_meta(main_path):
    """cwd, git branch, and a title — from the first lines only (cheap)."""
    cwd = branch = name = None
    try:
        with open(main_path, encoding="utf-8", errors="ignore") as fh:
            for i, line in enumerate(fh):
                if i > 40 or (cwd and branch and name):
                    break
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(obj, dict):
                    continue
                cwd = cwd or obj.get("cwd")
                branch = branch or obj.get("gitBranch")
                if name:
                    continue
                if obj.get("type") == "summary" and obj.get("summary"):
                    name = obj["summary"]
                elif obj.get("type") == "user":
                    text = unwrap_command(text_of(obj.get("message", {}).get("content", "")))
                    if text:
                        name = text.strip()
    except OSError:
        pass
    return cwd, branch, name


ROLE = {"user": "\033[1;36muser\033[0m", "assistant": "\033[1;35mclaude\033[0m"}


def msg_text(obj):
    """(role_label, text) for a readable user/assistant message, else None."""
    if not isinstance(obj, dict) or obj.get("isSidechain") or obj.get("isMeta"):
        return None
    if obj.get("type") not in ROLE:
        return None
    raw = re.sub(r"<system-reminder>.*?</system-reminder>", "", text_of(obj.get("message", {}).get("content", "")), flags=re.S).strip()
    text = unwrap_command(raw)
    return (ROLE[obj["type"]], text) if text else None


def head_messages(path, n, only_user=False):
    out = []
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                if len(out) >= n:
                    break
                try:
                    m = msg_text(json.loads(line))
                except json.JSONDecodeError:
                    continue
                if m and not (only_user and m[0] != ROLE["user"]):
                    out.append(m)
    except OSError:
        pass
    return out


def tail_messages(path, n, budget=524288):
    """Last n readable messages, read from the end of the file (bounded)."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            fh.seek(max(0, size - budget))
            lines = fh.read().split(b"\n")
        if size > budget:
            lines = lines[1:]  # drop the partial line we seeked into
    except OSError:
        return []
    out = []
    for raw in reversed(lines):
        if len(out) >= n:
            break
        if not raw.strip():
            continue
        try:
            m = msg_text(json.loads(raw.decode("utf-8", "ignore")))
        except json.JSONDecodeError:
            continue
        if m:
            out.append(m)
    return list(reversed(out))


def emit_preview(path, head_n=2, tail_n=8):
    head = head_messages(path, head_n, only_user=True) or head_messages(path, 1)
    if not head:
        print("(no readable messages)")
        return
    for label, text in head:
        sys.stdout.write(f"{label}\n{text[:900]}\n\n")
    # recent tail, minus anything already shown as the opening (short sessions)
    seen = {t for _, t in head}
    tail = [m for m in tail_messages(path, tail_n) if m[1] not in seen]
    if tail:
        print(f"\033[38;5;240m─── recent ───{RESET}\n")
        for label, text in tail:
            sys.stdout.write(f"{label}\n{text[:900]}\n\n")


def collect(browse):
    mains = {}
    if browse:
        for main in glob.glob(os.path.join(BASE, "*", "*.jsonl")):
            sid = os.path.splitext(os.path.basename(main))[0]
            if UUID_RE.match(sid):
                mains[sid] = main
    else:
        for f in (ln.strip() for ln in sys.stdin if ln.strip()):
            after = f.split(os.sep + "projects" + os.sep, 1)
            m = UUID_ANY.search(after[-1] if len(after) > 1 else f)
            if not m:
                continue
            sid = m.group(0)
            projdir = f[: f.index(sid)].rstrip(os.sep)
            mains[sid] = os.path.join(projdir, f"{sid}.jsonl")
    return mains


def main():
    argv = sys.argv[1:]
    if argv and argv[0] == "--preview":
        if len(argv) > 1:
            emit_preview(argv[1])
        return

    tsv = browse = False
    rest = []
    for a in argv:
        if a == "--tsv":
            tsv = True
        elif a == "--browse":
            browse = True
        else:
            rest.append(a)
    max_results = int(rest[0]) if rest and rest[0].isdigit() else 300

    # stat everything (cheap), sort/slice, THEN parse metadata only for survivors
    stated = []
    for sid, main in collect(browse).items():
        try:
            st = os.stat(main)
        except OSError:
            continue
        stated.append((st.st_mtime, st.st_size, sid, main))
    stated.sort(reverse=True)
    stated = stated[:max_results]

    if not stated:
        if not tsv:
            print("No sessions found.")
        return

    for mtime, size, sid, main in stated:
        cwd, branch, name = read_meta(main)
        cwd = cwd or os.path.basename(os.path.dirname(main))
        title = re.sub(r"\s+", " ", name or "(untitled session)").strip()
        proj = "/".join(cwd.rstrip("/").split("/")[-2:])
        meta = f"{rel_time(mtime)} · {branch or '-'} · {human_size(size)} · {proj}"
        if tsv:
            visual = f"{BOLD}{title}{RESET}\n{GRAY}{meta}{RESET}"
            sys.stdout.write(f"{sid}\t{cwd}\t{visual}\t{main}\0")
        else:
            print(f"{BOLD}{title}{RESET}")
            print(f"    {GRAY}{meta}{RESET}")
            print(f"    \033[36mcd {cwd} && claude --resume {sid}{RESET}\n")


if __name__ == "__main__":
    main()
