#!/usr/bin/env python3
"""
ICM Backfill — Enrich rtk icm database from Claude Code and Codex CLI session data.

The hook already extracts facts live during sessions (extraction.enabled=true,
extract_every=3 -> context-<project> topics). This script backfills the signals
the live hook does NOT capture: instruction files, per-session metrics, plans,
usage aggregates, /insights facets, and research notes. Full-conversation import
is available but OFF by default (--import-sessions) so it doesn't double-capture
what the live hook already stored.

Sources (Claude Code — ~/.claude/):
  1. Memory files (projects/*/memory/*.md) — legacy project knowledge (migrated)
  2. CLAUDE.md + RTK.md — global and per-project coding instructions
  3. usage-data/session-meta/*.json — per-session metrics (duration, tools, git, errors)
  4. Plans (plans/*.md) — architectural decisions, root cause analyses
  5. History index (history.jsonl) — prompt patterns, project usage frequency
  6. Sessions index (sessions-index.json) — session summaries with git branches
  7. usage-data/facets/*.json — /insights: goals, satisfaction, friction
  8. research/*.md — saved research notes
  9. [--import-sessions] projects/*/*.jsonl via `icm import --format claude-code`

Sources (Codex CLI — ~/.codex/):
  10. Session JSONL files — failed shell commands, error patterns
  11. AGENTS.md — global and per-project agent instructions
  12. state_*.sqlite — threads + stage1_outputs (rollout summaries / extracted memories)

Reconciliation (always, idempotent): forgets legacy topics superseded by the
current naming scheme (bare errors/<cat>, usage/patterns, sessions/<x>) once
their replacement exists — a no-op once the store is clean.

Maintenance (--maintain): decay -> prune -> consolidate noisy aggregate topics.

Usage:
  python3 icm-backfill.py [--dry-run] [--verbose] [--source claude|codex|all]
                          [--import-sessions] [--full] [--maintain]

  --full            Ignore the watermark; reprocess everything.
  --import-sessions Backfill full conversations via `icm import` (historical only;
                    the live hook already captures ongoing sessions).
  --maintain        Run decay/prune/consolidate after ingestion.
  --verify          Compare the live DB against the git-HEAD baseline and report
                    any hand-curated memory that went missing. Exits non-zero if
                    curated data was lost. Does not ingest.
"""

import ast
import json
import os
import re
import subprocess
import sys
import glob
from pathlib import Path
from collections import Counter, defaultdict

HOME = Path.home()
CLAUDE_DIR = HOME / ".claude"
CODEX_DIR = HOME / ".codex"
CODE_DIR = HOME / "Code"
DOTFILES_DIR = HOME / ".dotfiles"
DB_REL = ".config/icm/memories.db"
STATE_FILE = CLAUDE_DIR / ".icm-backfill-state.json"

DRY_RUN = "--dry-run" in sys.argv
VERBOSE = "--verbose" in sys.argv
FULL = "--full" in sys.argv
IMPORT_SESSIONS = "--import-sessions" in sys.argv
MAINTAIN = "--maintain" in sys.argv
VERIFY = "--verify" in sys.argv

# Topics that are machine-regenerable; losing/transforming them between the git
# baseline and the live DB is expected, so --verify ignores them and only flags
# hand-curated content.
REGEN_TOPIC_PREFIXES = (
    "context-", "usage/", "insights/", "errors/",
    "sessions/", "instructions/", "plans", "research", "memory/",
)

# Topics that are regenerable machine aggregates: replaced wholesale each run
# rather than appended, and consolidated during --maintain.
AGGREGATE_TOPICS = {
    "usage/claude-patterns", "usage/claude-projects", "usage/claude-session-metrics",
    "usage/codex-sessions", "usage/codex-threads",
    "insights/goals", "insights/satisfaction", "insights/helpfulness",
    "insights/session-types", "insights/outcomes",
}

# Legacy topics from earlier script versions, superseded by the current scheme.
# Reconciliation forgets a legacy topic only when its replacement exists, so the
# step is safe and idempotent (once removed, there is nothing left to match).
LEGACY_EXACT = {
    "usage/patterns": "usage/claude-patterns",
    "usage/projects": "usage/claude-projects",
    "usage/claude-sessions": "usage/claude-session-metrics",
}
ERROR_CATS = {
    "command-not-found", "file-not-found", "git-errors", "npm-errors",
    "other-errors", "permission-errors", "syntax-errors", "terraform-errors",
    "timeouts", "connection-errors",
}

# Parse --source flag
_source_arg = "all"
for i, arg in enumerate(sys.argv):
    if arg == "--source" and i + 1 < len(sys.argv):
        _source_arg = sys.argv[i + 1]
RUN_CLAUDE = _source_arg in ("all", "claude")
RUN_CODEX = _source_arg in ("all", "codex")

stats = Counter()
SKIP_DIRS = {"node_modules", ".git", "vendor", "dist", "build", "__pycache__"}


def log(msg, level="info"):
    if level == "debug" and not VERBOSE:
        return
    prefix = {"info": "->", "ok": "ok", "warn": "!!", "err": "XX", "debug": "  "}
    print(f"  {prefix.get(level, '->')} {msg}")


# -----------------------------------------------------------------------------
# Watermark state — track what's already been ingested so re-runs are incremental
# -----------------------------------------------------------------------------

def load_state():
    if FULL or not STATE_FILE.exists():
        return {"files": {}, "sessions": [], "history_ts": 0}
    try:
        s = json.loads(STATE_FILE.read_text())
        s.setdefault("files", {})
        s.setdefault("sessions", [])
        s.setdefault("history_ts", 0)
        return s
    except Exception:
        return {"files": {}, "sessions": [], "history_ts": 0}


def save_state(state):
    if DRY_RUN:
        return
    try:
        STATE_FILE.write_text(json.dumps(state, indent=2))
    except Exception as e:
        log(f"Could not save state: {e}", "warn")


def file_changed(state, path):
    """True if the file is new or modified since last processed run."""
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return False
    if FULL:
        return True
    return state["files"].get(str(path), 0) < mtime


def mark_file(state, path):
    try:
        state["files"][str(path)] = os.path.getmtime(path)
    except OSError:
        pass


# -----------------------------------------------------------------------------
# ICM wrappers
# -----------------------------------------------------------------------------

def _run(cmd, **kw):
    kw.setdefault("capture_output", True)
    kw.setdefault("text", True)
    kw.setdefault("timeout", 60)
    return subprocess.run(cmd, **kw)


def icm_store(topic, content, importance="medium", keywords=None, raw=None):
    """Store a memory in ICM via rtk icm store."""
    stats["stored"] += 1
    if DRY_RUN:
        log(f"[DRY-RUN] store '{topic}': {content[:80]}...", "debug")
        return True

    cmd = ["rtk", "icm", "store", "-t", topic, "-c", content[:3000], "-i", importance]
    if keywords:
        cmd.extend(["-k", keywords])
    if raw:
        cmd.extend(["-r", raw[:2000]])

    try:
        result = _run(cmd)
        if result.returncode != 0:
            stderr = result.stderr.lower()
            if "similar" in stderr or "duplicate" in stderr or "exists" in stderr:
                stats["duplicates"] += 1
                log(f"Duplicate skipped: {content[:60]}...", "debug")
                return False
            log(f"Store failed: {result.stderr.strip()[:100]}", "warn")
            stats["errors"] += 1
            return False
        return True
    except subprocess.TimeoutExpired:
        log(f"Store timeout (topic={topic}), skipping", "warn")
        stats["errors"] += 1
        return False
    except Exception as e:
        log(f"Store error: {e}", "err")
        stats["errors"] += 1
        return False


def icm_replace_topic(topic, content, importance="low", keywords=None):
    """Replace a regenerable aggregate topic: forget the old contents, store fresh.

    Aggregates (usage/*, insights/*) are recomputed from scratch every run, so
    appending would pile up stale copies. Wholesale replace keeps exactly one.
    """
    stats["replaced"] += 1
    if DRY_RUN:
        log(f"[DRY-RUN] replace '{topic}': {content[:80]}...", "debug")
        return True
    try:
        _run(["rtk", "icm", "forget", "-t", topic])
    except Exception:
        pass
    return icm_store(topic, content, importance, keywords)


def icm_extract(text, project):
    """Rule-based fact extraction via rtk icm extract (zero LLM cost)."""
    if DRY_RUN:
        stats["extracted"] += 1
        log(f"[DRY-RUN] extract '{project}': {len(text)} chars", "debug")
        return True
    try:
        result = _run(["rtk", "icm", "extract", "-p", project],
                      input=text[:10000])
        if result.returncode == 0:
            stats["extracted"] += 1
            if result.stdout.strip():
                log(f"Extracted from '{project}': {result.stdout.strip()[:100]}", "debug")
            return True
        stats["errors"] += 1
        return False
    except Exception as e:
        log(f"Extract error: {e}", "err")
        stats["errors"] += 1
        return False


def icm_import(path, project):
    """Import a full conversation via the native claude-code importer."""
    if DRY_RUN:
        stats["imported"] += 1
        result = _run(["rtk", "icm", "import", str(path),
                       "--format", "claude-code", "-p", project, "--dry-run"])
        log(f"[DRY-RUN] import {Path(path).name}: {result.stdout.strip().splitlines()[-1] if result.stdout.strip() else '(no output)'}", "debug")
        return True
    try:
        result = _run(["rtk", "icm", "import", str(path),
                       "--format", "claude-code", "-p", project], timeout=120)
        if result.returncode == 0:
            stats["imported"] += 1
            return True
        log(f"Import failed ({Path(path).name}): {result.stderr.strip()[:100]}", "warn")
        stats["errors"] += 1
        return False
    except Exception as e:
        log(f"Import error: {e}", "err")
        stats["errors"] += 1
        return False


# -----------------------------------------------------------------------------
# Shared helpers
# -----------------------------------------------------------------------------

def project_from_path(p):
    """Authoritative project name from a real cwd/originalPath.

    Prefers the last two path segments under Code/ (org-repo) so distinct repos
    with a common leaf ('main', 'master', '.bare') stay distinguishable.
    """
    if not p:
        return "unknown"
    parts = Path(p).parts
    for i, seg in enumerate(parts):
        if seg in ("Code", "code") and i + 1 < len(parts):
            return "-".join(parts[i + 1:]).replace("/", "-")
    return Path(p).name or "unknown"


def derive_project_name(encoded_dir):
    """Fallback for the encoded projects/ dir name when no real path is available.

    Claude Code encodes '/Users/x/Code/org/repo' as '-Users-x-Code-org-repo', but
    literal hyphens/dots in the path also become '-', so this is lossy. Use only
    when projectPath/cwd is unavailable.
    """
    parts = encoded_dir.split("-")
    for i, seg in enumerate(parts):
        if seg in ("Code", "code") and i + 1 < len(parts):
            return "-".join(parts[i + 1:])
    return encoded_dir


def should_skip_path(path_str):
    return any(f"/{d}/" in path_str or path_str.endswith(f"/{d}") for d in SKIP_DIRS)


def canonical_instruction_files(filename):
    """One canonical instruction file per org/repo under Code/.

    A bare+worktree repo has the same CLAUDE.md/AGENTS.md copied across every
    branch and worktree; keying a topic by full path (the old behaviour) spawned
    ~85 near-duplicate instructions/* topics. Collapse to org-repo, keeping the
    shallowest path so it survives when worktrees come and go.
    """
    best = {}
    for path in CODE_DIR.rglob(filename):
        if should_skip_path(str(path)):
            continue
        parent = path.relative_to(CODE_DIR).parts[:-1]  # drop the filename
        if not parent:
            continue
        org_repo = "-".join(parent[:2])  # Org/repo, or a flat top-level repo
        cur = best.get(org_repo)
        if cur is None or len(path.parts) < len(cur.parts):
            best[org_repo] = path
    return best


def categorize_error(error_text):
    e = error_text.lower()
    if "permission denied" in e:
        return "permission-errors"
    if "command not found" in e or ("not found" in e and "no such" not in e):
        return "command-not-found"
    if "no such file" in e:
        return "file-not-found"
    if "timeout" in e or "timed out" in e:
        return "timeouts"
    if "syntax error" in e or "syntaxerror" in e:
        return "syntax-errors"
    if "connection refused" in e or "econnrefused" in e:
        return "connection-errors"
    if "npm err" in e or "npm warn" in e:
        return "npm-errors"
    if "git" in e:
        return "git-errors"
    if "terraform" in e:
        return "terraform-errors"
    return "other-errors"


def store_error_categories(failed_commands, source_label):
    """Deduplicate and store categorized errors (low importance — regenerable)."""
    categories = defaultdict(list)
    for fc in failed_commands:
        categories[categorize_error(fc["error"])].append(fc)

    log(f"[{source_label}] {len(failed_commands)} failed calls across {len(categories)} categories", "info")

    for category, errors in categories.items():
        seen, unique = set(), []
        for e in errors:
            key = e["error"][:100]
            if key not in seen:
                seen.add(key)
                unique.append(e)
        if not unique:
            continue

        summary_lines = [f"[{e['project']}] {e['error'][:200]}" for e in unique[:20]]
        content = (
            f"[{source_label}] Failed commands: '{category}' "
            f"({len(errors)} total, {len(unique)} unique):\n"
            + "\n---\n".join(summary_lines)
        )
        icm_replace_topic(
            topic=f"errors/{source_label.lower()}/{category}",
            content=content,
            importance="low",
            keywords=f"errors,{category},{source_label.lower()}",
        )
        log(f"  {category}: {len(unique)} unique errors", "ok")


# =============================================================================
# Claude Code sources
# =============================================================================

def claude_memory_files(state):
    print("\n[Claude] Legacy memory files...")
    for mf in glob.glob(str(CLAUDE_DIR / "projects" / "*" / "memory" / "*.md")):
        path = Path(mf)
        if path.name == "MEMORY.md" or not file_changed(state, path):
            continue

        project_name = derive_project_name(path.parent.parent.name)
        try:
            content = path.read_text().strip()
            if not content or len(content) < 20:
                continue
        except Exception:
            continue

        mem_type, description = "project", path.stem
        if content.startswith("---"):
            fm_end = content.find("---", 3)
            if fm_end > 0:
                for line in content[3:fm_end].strip().split("\n"):
                    if line.startswith("type:"):
                        mem_type = line.split(":", 1)[1].strip()
                    elif line.startswith("description:") or line.startswith("name:"):
                        description = line.split(":", 1)[1].strip()
                content = content[fm_end + 3:].strip() or content

        importance = {"feedback": "high", "user": "high"}.get(mem_type, "medium")
        icm_store(
            topic=f"memory/{project_name}",
            content=f"[{mem_type}] {description}: {content[:1500]}",
            importance=importance,
            keywords=f"{mem_type},{project_name},{path.stem}",
        )
        mark_file(state, path)
        log(f"{path.name} -> memory/{project_name}", "ok")


def claude_instruction_files(state):
    print("\n[Claude] Instruction files (CLAUDE.md, RTK.md)...")

    for name, importance in [("CLAUDE.md", "critical"), ("RTK.md", "high")]:
        path = CLAUDE_DIR / name
        # Resolve symlink so mtime reflects the real dotfiles target.
        real = path.resolve() if path.exists() else path
        if real.exists() and file_changed(state, real):
            content = real.read_text().strip()
            if content:
                icm_store(
                    topic="instructions/global",
                    content=f"Global {name}: {content}",
                    importance=importance,
                    keywords=f"claude-md,instructions,global,{name.lower()}",
                )
                mark_file(state, real)
                log(f"Global {name}", "ok")

    if CODE_DIR.exists():
        for org_repo, cmd_path in canonical_instruction_files("CLAUDE.md").items():
            if not file_changed(state, cmd_path):
                continue
            try:
                content = cmd_path.read_text().strip()
                if not content or len(content) < 20:
                    continue
            except Exception:
                continue
            icm_replace_topic(
                topic=f"instructions/{org_repo}",
                content=f"Project CLAUDE.md for {org_repo}: {content[:2000]}",
                importance="high",
                keywords=f"claude-md,instructions,{org_repo}",
            )
            mark_file(state, cmd_path)
            log(f"CLAUDE.md: {org_repo} ({cmd_path})", "ok")


def claude_session_meta():
    """usage-data/session-meta/*.json — per-session metrics the live hook doesn't
    aggregate: duration, tool mix, git activity, error categories, MCP/web usage."""
    print("\n[Claude] Session metrics (session-meta)...")
    meta_dir = CLAUDE_DIR / "usage-data" / "session-meta"
    if not meta_dir.exists():
        log("No session-meta directory", "warn")
        return

    files = list(meta_dir.glob("*.json"))
    log(f"Found {len(files)} session-meta files", "info")

    by_project = defaultdict(list)
    tool_totals = Counter()
    error_cats = Counter()
    totals = Counter()
    for ff in files:
        try:
            m = json.loads(ff.read_text())
        except Exception:
            continue
        project = project_from_path(m.get("project_path", "")) or "unknown"
        by_project[project].append(m)
        for t, c in (m.get("tool_counts") or {}).items():
            tool_totals[t] += c
        for c, n in (m.get("tool_error_categories") or {}).items():
            error_cats[c] += n
        totals["sessions"] += 1
        totals["commits"] += m.get("git_commits", 0)
        totals["pushes"] += m.get("git_pushes", 0)
        totals["lines_added"] += m.get("lines_added", 0)
        totals["lines_removed"] += m.get("lines_removed", 0)
        totals["duration_min"] += m.get("duration_minutes", 0)
        totals["interruptions"] += m.get("user_interruptions", 0)
        if m.get("uses_mcp"):
            totals["mcp_sessions"] += 1
        if m.get("uses_web_search") or m.get("uses_web_fetch"):
            totals["web_sessions"] += 1

    if not totals["sessions"]:
        return

    overview = (
        f"Claude Code session metrics ({totals['sessions']} sessions):\n"
        f"  duration: {totals['duration_min']} min total\n"
        f"  git: {totals['commits']} commits, {totals['pushes']} pushes\n"
        f"  diff: +{totals['lines_added']} / -{totals['lines_removed']} lines\n"
        f"  interruptions: {totals['interruptions']}\n"
        f"  mcp sessions: {totals['mcp_sessions']}, web sessions: {totals['web_sessions']}\n"
        f"  top tools: {dict(tool_totals.most_common(10))}\n"
        f"  tool error categories: {dict(error_cats.most_common())}"
    )
    icm_replace_topic("usage/claude-session-metrics", overview, "low",
                      "usage,metrics,sessions,claude")
    log(f"Session metrics: {totals['sessions']} sessions across {len(by_project)} projects", "ok")

    # Per-project rollup for the busiest projects (medium — actionable).
    ranked = sorted(by_project.items(), key=lambda kv: len(kv[1]), reverse=True)
    lines = []
    for project, sessions in ranked[:15]:
        commits = sum(s.get("git_commits", 0) for s in sessions)
        mins = sum(s.get("duration_minutes", 0) for s in sessions)
        lines.append(f"  {len(sessions):3d} sessions, {mins:5d} min, {commits} commits  {project}")
    icm_replace_topic(
        "usage/claude-projects",
        "Claude Code project activity (from session-meta):\n" + "\n".join(lines),
        "low", "usage,projects,claude",
    )


def claude_plans(state):
    print("\n[Claude] Plans...")
    plans_dir = CLAUDE_DIR / "plans"
    if not plans_dir.exists():
        log("No plans directory", "warn")
        return

    plan_files = list(plans_dir.glob("*.md"))
    log(f"Found {len(plan_files)} plan files", "info")

    for pf in plan_files:
        if not file_changed(state, pf):
            continue
        try:
            content = pf.read_text().strip()
            if not content or len(content) < 50:
                continue
        except Exception:
            continue

        title = pf.stem
        for line in content.split("\n"):
            if line.startswith("# "):
                title = line[2:].strip()
                break

        icm_store(
            topic="plans",
            content=f"Plan: {title}\n\n{content[:1500]}",
            importance="medium",
            keywords=f"plans,architecture,{pf.stem}",
        )
        mark_file(state, pf)
        log(f"{title[:60]}", "ok")


def claude_history(state):
    print("\n[Claude] History patterns...")
    history_file = CLAUDE_DIR / "history.jsonl"
    if not history_file.exists():
        log("No history.jsonl", "warn")
        return

    project_usage = Counter()
    prompt_patterns = Counter()
    count = 0
    max_ts = state["history_ts"]

    with open(history_file) as f:
        for line in f:
            try:
                obj = json.loads(line.strip())
            except json.JSONDecodeError:
                continue
            ts = obj.get("timestamp", 0)
            max_ts = max(max_ts, ts)
            count += 1
            display = obj.get("display", "")
            project = obj.get("project", "")
            if project:
                project_usage[project.replace(str(HOME), "~")] += 1

            d = display.lower().strip()
            if d.startswith("!") or d.startswith("run "):
                prompt_patterns["shell-commands"] += 1
            elif d.startswith("/"):
                prompt_patterns["slash-commands"] += 1
            elif "fix" in d or "bug" in d:
                prompt_patterns["bug-fixes"] += 1
            elif "test" in d:
                prompt_patterns["testing"] += 1
            elif "refactor" in d:
                prompt_patterns["refactoring"] += 1
            elif "add" in d or "implement" in d or "create" in d:
                prompt_patterns["new-features"] += 1
            elif "explain" in d or "how" in d or "what" in d or "why" in d:
                prompt_patterns["questions"] += 1

    log(f"Analyzed {count} history entries", "info")

    if prompt_patterns:
        pattern_text = "Claude Code prompt patterns:\n" + "\n".join(
            f"  {c:3d}x  {p}" for p, c in prompt_patterns.most_common()
        )
        icm_replace_topic("usage/claude-patterns", pattern_text, "low", "usage,patterns,claude")
        log(f"Patterns: {dict(prompt_patterns)}", "ok")

    state["history_ts"] = max_ts


def claude_session_summaries():
    print("\n[Claude] Session summaries...")
    index_files = glob.glob(str(CLAUDE_DIR / "projects" / "*" / "sessions-index.json"))
    all_sessions = []

    for idx_file in index_files:
        try:
            with open(idx_file) as f:
                data = json.load(f)
        except Exception:
            continue

        for entry in data.get("entries", []):
            summary = entry.get("summary", "")
            if entry.get("messageCount", 0) < 5:
                continue
            if not summary or len(summary) < 20 or summary.startswith("API Error"):
                continue
            # Prefer per-entry projectPath (authoritative) over the index header.
            project = project_from_path(
                entry.get("projectPath") or data.get("originalPath", "")
            )
            all_sessions.append({
                "project": project,
                "summary": summary,
                "first_prompt": entry.get("firstPrompt", ""),
                "messages": entry.get("messageCount", 0),
                "branch": entry.get("gitBranch", ""),
                "date": entry.get("created", "")[:10],
            })

    log(f"Found {len(all_sessions)} non-trivial sessions", "info")

    by_project = defaultdict(list)
    for s in all_sessions:
        by_project[s["project"]].append(s)

    for project, sessions in by_project.items():
        lines = []
        for s in sessions[:30]:
            line = f"[{s['date']}] ({s['branch']}, {s['messages']} msgs) {s['first_prompt'][:80]}"
            if s["summary"]:
                line += f"\n  Summary: {s['summary'][:200]}"
            lines.append(line)
        icm_replace_topic(
            topic=f"sessions/claude/{project}",
            content=f"Claude sessions for {project} ({len(sessions)}):\n\n" + "\n\n".join(lines),
            importance="medium",
            keywords=f"sessions,claude,{project}",
        )
        log(f"{project}: {len(sessions)} sessions", "ok")


def claude_insights():
    """Ingest /insights facet data — pre-analyzed session metadata (Haiku-generated)."""
    print("\n[Claude] Insights facets...")
    facets_dir = CLAUDE_DIR / "usage-data" / "facets"
    if not facets_dir.exists():
        log("No facets directory (run /insights first)", "warn")
        return

    facet_files = list(facets_dir.glob("*.json"))
    log(f"Found {len(facet_files)} facet files", "info")

    all_friction = []
    goal_categories = Counter()
    satisfaction = Counter()
    helpfulness = Counter()
    session_types = Counter()
    outcomes = Counter()
    primary_success = Counter()
    summaries = []

    for ff in facet_files:
        try:
            facet = json.loads(ff.read_text())
        except Exception:
            continue

        for cat, c in facet.get("goal_categories", {}).items():
            goal_categories[cat] += c
        for level, c in facet.get("user_satisfaction_counts", {}).items():
            satisfaction[level] += c
        if facet.get("claude_helpfulness"):
            helpfulness[facet["claude_helpfulness"]] += 1
        if facet.get("session_type"):
            session_types[facet["session_type"]] += 1
        if facet.get("outcome"):
            outcomes[facet["outcome"]] += 1
        if facet.get("primary_success"):
            primary_success[facet["primary_success"]] += 1

        friction = facet.get("friction_detail", "")
        if friction and len(friction) > 10:
            all_friction.append({
                "detail": friction,
                "counts": facet.get("friction_counts", {}),
                "goal": facet.get("underlying_goal", ""),
                "session_id": facet.get("session_id", ff.stem),
            })
        if facet.get("brief_summary"):
            summaries.append(facet["brief_summary"])

    def agg(topic, label, counter, kw):
        if counter:
            content = f"{label}:\n" + "\n".join(f"  {c:3d}x  {k}" for k, c in counter.most_common())
            icm_replace_topic(topic, content, "low", kw)
            log(f"{topic}: {len(counter)} keys", "ok")

    agg("insights/goals", "Claude Code goal categories (/insights)", goal_categories, "insights,goals,claude")
    agg("insights/satisfaction", "Claude Code user satisfaction (/insights)", satisfaction, "insights,satisfaction,claude")
    agg("insights/helpfulness", "Claude Code helpfulness ratings", helpfulness, "insights,helpfulness,claude")
    agg("insights/session-types", "Claude Code session types", session_types, "insights,session-types,claude")
    agg("insights/outcomes", "Claude Code outcomes + primary success",
        outcomes + primary_success, "insights,outcomes,claude")

    # Friction is the highest-value learning signal — keep it, high importance.
    if all_friction:
        friction_lines = []
        for fr in all_friction:
            counts_str = ", ".join(f"{k}: {v}" for k, v in fr["counts"].items()) if fr["counts"] else ""
            line = f"Goal: {fr['goal'][:100]}\n  Friction: {fr['detail'][:300]}"
            if counts_str:
                line += f"\n  Counts: {counts_str}"
            friction_lines.append(line)
        content = (
            f"Claude Code friction points ({len(all_friction)} sessions with friction):\n\n"
            + "\n\n".join(friction_lines[:30])
        )
        icm_replace_topic("insights/friction", content, "high",
                          "insights,friction,mistakes,learning,claude")
        log(f"Friction: {len(all_friction)} entries", "ok")


def claude_research(state):
    print("\n[Claude] Research notes...")
    research_dir = CLAUDE_DIR / "research"
    if not research_dir.exists():
        log("No research directory", "warn")
        return
    for rf in research_dir.glob("*.md"):
        real = rf.resolve()
        if not real.exists() or not file_changed(state, real):
            continue
        try:
            content = real.read_text().strip()
            if len(content) < 50:
                continue
        except Exception:
            continue
        title = rf.stem
        for line in content.split("\n"):
            if line.startswith("# "):
                title = line[2:].strip()
                break
        icm_store(
            topic="research",
            content=f"Research: {title}\n\n{content[:1800]}",
            importance="medium",
            keywords=f"research,{rf.stem}",
        )
        mark_file(state, real)
        log(f"{title[:60]}", "ok")


def claude_import_sessions(state):
    """Historical full-conversation backfill via the native claude-code importer.

    Off by default: the live hook (extraction.enabled) already captures ongoing
    sessions into context-<project>. Use only to backfill the pre-hook archive.
    """
    print("\n[Claude] Importing full sessions (--import-sessions)...")
    session_files = glob.glob(str(CLAUDE_DIR / "projects" / "*" / "*.jsonl"))
    log(f"Found {len(session_files)} session files", "info")
    imported = 0
    for sf in session_files:
        path = Path(sf)
        if not file_changed(state, path):
            continue
        project = derive_project_name(path.parent.name)
        if icm_import(path, project):
            imported += 1
        mark_file(state, path)
    log(f"Imported {imported} new/changed sessions", "ok")


# =============================================================================
# Codex CLI sources
# =============================================================================

def _parse_codex_payload(raw_payload):
    if isinstance(raw_payload, dict):
        return raw_payload
    if isinstance(raw_payload, str):
        try:
            return json.loads(raw_payload)
        except json.JSONDecodeError:
            try:
                return ast.literal_eval(raw_payload)
            except (ValueError, SyntaxError):
                return None
    return None


def codex_sessions(state):
    print("\n[Codex] Session data (failed commands, errors)...")
    if not CODEX_DIR.exists():
        log("No ~/.codex/ directory found, skipping", "warn")
        return

    session_files = (
        glob.glob(str(CODEX_DIR / "sessions" / "**" / "*.jsonl"), recursive=True)
        + glob.glob(str(CODEX_DIR / "archived_sessions" / "**" / "*.jsonl"), recursive=True)
    )
    log(f"Found {len(session_files)} Codex session files", "info")

    failed_commands = []
    session_metas = []

    for sf in session_files:
        if not file_changed(state, sf):
            continue
        try:
            with open(sf) as f:
                current_project = "unknown"
                pending_calls = {}
                for line in f:
                    try:
                        obj = json.loads(line.strip())
                    except json.JSONDecodeError:
                        continue

                    msg_type = obj.get("type", "")
                    payload = _parse_codex_payload(obj.get("payload"))
                    if not payload:
                        continue

                    if msg_type == "session_meta":
                        cwd = payload.get("cwd", "")
                        if cwd:
                            current_project = Path(cwd).name
                        session_metas.append({
                            "project": current_project,
                            "cwd": cwd,
                            "originator": payload.get("originator", ""),
                            "timestamp": obj.get("timestamp", ""),
                        })
                    elif msg_type == "response_item":
                        ptype = payload.get("type", "")
                        if ptype == "function_call":
                            call_id = payload.get("call_id", "")
                            args = payload.get("arguments", "")
                            try:
                                args_parsed = json.loads(args) if isinstance(args, str) else args
                            except json.JSONDecodeError:
                                args_parsed = {}
                            cmd = args_parsed.get("command", "") if isinstance(args_parsed, dict) else ""
                            if call_id and cmd:
                                pending_calls[call_id] = cmd
                        elif ptype == "function_call_output":
                            call_id = payload.get("call_id", "")
                            output_raw = payload.get("output", "")
                            output_text = output_raw
                            exit_code = None
                            try:
                                output_parsed = json.loads(output_raw) if isinstance(output_raw, str) else output_raw
                                if isinstance(output_parsed, dict):
                                    output_text = output_parsed.get("output", output_raw)
                                    metadata = output_parsed.get("metadata", {})
                                    if isinstance(metadata, dict):
                                        exit_code = metadata.get("exit_code")
                            except (json.JSONDecodeError, TypeError):
                                pass

                            is_error = False
                            if exit_code is not None and exit_code != 0:
                                is_error = True
                            elif isinstance(output_text, str) and any(
                                kw in output_text.lower()
                                for kw in ["error:", "fatal:", "traceback", "panic:"]
                            ):
                                is_error = True

                            if is_error and output_text and len(str(output_text)) > 10:
                                cmd = pending_calls.get(call_id, "")
                                error_str = str(output_text)[:500]
                                if cmd:
                                    error_str = f"Command: {cmd[:200]}\nOutput: {error_str}"
                                failed_commands.append({
                                    "project": current_project,
                                    "error": error_str,
                                })
        except Exception as e:
            log(f"Error reading {sf}: {e}", "debug")
        mark_file(state, sf)

    store_error_categories(failed_commands, "Codex")

    if session_metas:
        by_originator = Counter(m["originator"] for m in session_metas)
        by_project = Counter(m["project"] for m in session_metas)
        overview = (
            f"Codex session overview ({len(session_metas)} sessions):\n"
            f"By originator: {dict(by_originator)}\n"
            f"Top projects: {dict(by_project.most_common(10))}"
        )
        icm_replace_topic("usage/codex-sessions", overview, "low", "usage,codex,sessions")
        log(f"Session overview: {len(session_metas)} sessions", "ok")


def codex_instruction_files(state):
    print("\n[Codex] Instruction files (AGENTS.md)...")
    if not CODEX_DIR.exists():
        log("No ~/.codex/ directory, skipping", "warn")
        return

    for fname, importance, kw in [
        ("AGENTS.md", "critical", "agents-md,instructions,global,codex"),
        ("RTK.md", "high", "rtk,instructions,codex"),
    ]:
        path = CODEX_DIR / fname
        if path.exists() and file_changed(state, path):
            content = path.read_text().strip()
            if content and len(content) > 10:
                icm_store("instructions/global", f"Codex {fname}: {content}",
                          importance, kw)
                mark_file(state, path)
                log(f"Global {fname}", "ok")

    if CODE_DIR.exists():
        for org_repo, agents_path in canonical_instruction_files("AGENTS.md").items():
            if not file_changed(state, agents_path):
                continue
            try:
                content = agents_path.read_text().strip()
                if not content or len(content) < 20:
                    continue
            except Exception:
                continue
            icm_replace_topic(
                topic=f"instructions/{org_repo}-agents",
                content=f"Project AGENTS.md for {org_repo}: {content[:2000]}",
                importance="high",
                keywords=f"agents-md,instructions,codex,{org_repo}",
            )
            mark_file(state, agents_path)
            log(f"AGENTS.md: {org_repo}-agents ({agents_path})", "ok")


def codex_insights():
    """Ingest Codex threads (session metadata) and stage1_outputs (rollout summaries)."""
    print("\n[Codex] Insights (threads + stage1_outputs)...")
    candidates = sorted(CODEX_DIR.glob("state_*.sqlite"))
    if not candidates:
        log("No Codex state database found, skipping", "warn")
        return
    state_db = candidates[-1]

    import sqlite3 as sqlite3_mod
    try:
        conn = sqlite3_mod.connect(str(state_db))
        conn.row_factory = sqlite3_mod.Row
    except Exception as e:
        log(f"Cannot open {state_db}: {e}", "err")
        return

    try:
        rows = conn.execute(
            "SELECT title, cwd, tokens_used, git_branch, first_user_message, "
            "source, created_at FROM threads WHERE tokens_used > 0 "
            "ORDER BY created_at DESC LIMIT 100"
        ).fetchall()
    except Exception:
        rows = []

    if rows:
        log(f"Found {len(rows)} Codex threads with token usage", "info")
        lines = []
        project_usage = Counter()
        for r in rows:
            project = Path(r["cwd"]).name if r["cwd"] else "unknown"
            project_usage[project] += 1
            title = r["title"] or (r["first_user_message"] or "")[:80] or "(untitled)"
            lines.append(f"  [{r['git_branch'] or ''}] {title[:80]} ({r['tokens_used']} tokens)")
        overview = (
            f"Codex thread overview ({len(rows)} sessions):\n"
            f"By project: {dict(project_usage.most_common(10))}\n\n" + "\n".join(lines[:30])
        )
        icm_replace_topic("usage/codex-threads", overview, "low", "usage,codex,threads")
        log(f"Thread overview: {len(rows)} sessions", "ok")

    try:
        s1_rows = conn.execute(
            "SELECT thread_id, rollout_slug, raw_memory, rollout_summary, "
            "usage_count, generated_at FROM stage1_outputs "
            "ORDER BY generated_at DESC LIMIT 100"
        ).fetchall()
    except Exception:
        s1_rows = []

    if s1_rows:
        log(f"Found {len(s1_rows)} stage1 outputs (rollout summaries)", "info")
        summaries, memories = [], []
        for r in s1_rows:
            slug = r["rollout_slug"] or r["thread_id"]
            if r["rollout_summary"] and len(r["rollout_summary"]) > 20:
                summaries.append(f"[{slug}] {r['rollout_summary'][:300]}")
            if r["raw_memory"] and len(r["raw_memory"]) > 20:
                memories.append(r["raw_memory"])
        if summaries:
            content = f"Codex rollout summaries ({len(summaries)}):\n\n" + "\n\n".join(summaries[:30])
            icm_replace_topic("insights/codex-summaries", content, "medium",
                              "insights,codex,summaries,rollouts")
            log(f"Rollout summaries: {len(summaries)}", "ok")
        if memories:
            icm_extract("\n\n".join(memories[:50]), "codex-extracted-memories")
            log(f"Extracted from {len(memories)} raw memories", "ok")

    conn.close()


# =============================================================================
# Reconciliation — remove legacy topics superseded by the current scheme
# =============================================================================

def get_topics():
    """Return the set of current topic names from `rtk icm topics`."""
    try:
        r = _run(["rtk", "icm", "topics"], timeout=30)
    except Exception:
        return set()
    topics = set()
    for line in r.stdout.splitlines():
        m = re.match(r"^(.*\S)\s+\d+\s*$", line)
        if m and m.group(1).strip().lower() != "topic":
            topics.add(m.group(1).strip())
    return topics


def reconcile_topics():
    """Forget legacy topics whose current-scheme replacement already exists.

    Only touches known regenerable machine aggregates — never hand-curated
    topics. Runs on every invocation; a no-op once the store is clean.
    """
    print("\n[Reconcile] removing superseded legacy topics...")
    topics = get_topics()
    if not topics:
        log("could not read topics; skipping reconcile", "warn")
        return

    orphans = set()
    for old, new in LEGACY_EXACT.items():
        if old in topics and new in topics:
            orphans.add(old)
    # Bare errors/<cat> superseded by errors/{claude,codex}/<cat>.
    for cat in ERROR_CATS:
        if f"errors/{cat}" in topics and (
            f"errors/claude/{cat}" in topics or f"errors/codex/{cat}" in topics
        ):
            orphans.add(f"errors/{cat}")
    # Bare sessions/<x> superseded by sessions/claude/<x>.
    for t in topics:
        if t.startswith("sessions/") and not t.startswith("sessions/claude/"):
            leaf = t[len("sessions/"):]
            if "/" not in leaf and f"sessions/claude/{leaf}" in topics:
                orphans.add(t)

    if CODE_DIR.exists():
        canonical = set(canonical_instruction_files("CLAUDE.md"))
        canonical |= set(canonical_instruction_files("AGENTS.md"))
        valid = set(canonical) | {c + "-agents" for c in canonical}
        # Only drop a fragment when its canonical org-repo topic already exists.
        present = {c for c in canonical
                   if f"instructions/{c}" in topics or f"instructions/{c}-agents" in topics}
        for t in topics:
            if not t.startswith("instructions/") or t == "instructions/global":
                continue
            name = t[len("instructions/"):]
            if name in valid:
                continue
            if any(name.startswith(c + "-") for c in present):
                orphans.add(t)

    if not orphans:
        log("no legacy topics to remove", "ok")
        return

    for t in sorted(orphans):
        stats["reconciled"] += 1
        if DRY_RUN:
            log(f"[DRY-RUN] would forget legacy topic '{t}'", "info")
        else:
            _run(["rtk", "icm", "forget", "-t", t])
            log(f"forgot legacy topic '{t}'", "ok")


# =============================================================================
# Verify — prove no hand-curated memory was lost vs the git baseline
# =============================================================================

def _decrypt_head_db(out_path):
    """Write the decrypted git-HEAD copy of the memories DB to out_path.

    The committed DB is git-crypt encrypted at rest; smudge it back to plaintext
    using the already-unlocked repo. Returns True on success.
    """
    try:
        show = subprocess.run(["git", "-C", str(DOTFILES_DIR), "show", f"HEAD:{DB_REL}"],
                              capture_output=True, timeout=60)
        if show.returncode != 0 or not show.stdout:
            log(f"git show failed: {show.stderr.decode()[:100]}", "err")
            return False
        blob = show.stdout
        if blob[:9] == b"\x00GITCRYPT":
            smudge = subprocess.run(["git-crypt", "smudge"], input=blob,
                                    capture_output=True, cwd=str(DOTFILES_DIR), timeout=60)
            if smudge.returncode != 0:
                log(f"git-crypt smudge failed: {smudge.stderr.decode()[:100]}", "err")
                return False
            blob = smudge.stdout
        Path(out_path).write_bytes(blob)
        return True
    except FileNotFoundError as e:
        log(f"missing tool for verify ({e}); skipping", "warn")
        return False
    except Exception as e:
        log(f"verify baseline error: {e}", "err")
        return False


def _norm(s):
    return " ".join((s or "").split())


def verify_against_baseline():
    """Confirm every hand-curated memory in the git-HEAD baseline survives in the
    live DB (present by id, merged into another row, or on-disk-regenerable)."""
    print("\n[Verify] curated memory vs git HEAD baseline...")
    import sqlite3 as sq
    import tempfile

    cur_db = DOTFILES_DIR / DB_REL
    if not cur_db.exists():
        log(f"live DB not found at {cur_db}", "err")
        return 1

    base_path = Path(tempfile.gettempdir()) / "icm-backfill-verify-head.db"
    if not _decrypt_head_db(base_path):
        return 1

    def load(db):
        c = sq.connect(str(db)); c.row_factory = sq.Row
        rows = c.execute("SELECT id, topic, summary, raw_excerpt FROM memories").fetchall()
        c.close()
        return rows

    try:
        head = load(base_path)
        cur = load(cur_db)
    except Exception as e:
        log(f"cannot read a DB: {e}", "err")
        return 1

    cur_ids = {r["id"] for r in cur}
    cur_blob = _norm("\n".join((r["summary"] or "") + " " + (r["raw_excerpt"] or "") for r in cur))

    preserved = regen = 0
    lost = []
    for r in head:
        if r["id"] in cur_ids:
            preserved += 1
            continue
        body = _norm(r["summary"])
        frag = body[:80]
        if body and (body in cur_blob or (frag and frag in cur_blob)):
            preserved += 1
        elif r["topic"].startswith(REGEN_TOPIC_PREFIXES):
            regen += 1
        else:
            lost.append(r)

    print(f"  baseline={len(head)}  current={len(cur)}  preserved={preserved}  regenerable={regen}")
    if lost:
        log(f"CURATED MEMORY MISSING: {len(lost)}", "err")
        for r in lost:
            print(f"     [{r['topic']}] {_norm(r['summary'])[:100]}")
        return 1
    log("no curated memory lost — baseline fully accounted for", "ok")
    return 0


# =============================================================================
# Maintenance
# =============================================================================

def maintenance():
    print("\n[Maintain] decay -> prune -> consolidate...")
    if DRY_RUN:
        log("[DRY-RUN] would decay(0.95), prune(<0.1), consolidate aggregate topics", "info")
        return
    try:
        _run(["rtk", "icm", "decay"], timeout=120)
        log("decay applied", "ok")
    except Exception as e:
        log(f"decay failed: {e}", "warn")
    try:
        r = _run(["rtk", "icm", "prune", "--threshold", "0.1"], timeout=120)
        log(f"prune: {r.stdout.strip()[:120]}", "ok")
    except Exception as e:
        log(f"prune failed: {e}", "warn")
    # Lexical consolidation (provider=none) — no LLM cost, collapses churn.
    for topic in sorted(AGGREGATE_TOPICS):
        try:
            _run(["rtk", "icm", "consolidate", "-t", topic,
                  "--summarizer-provider", "none"], timeout=120)
        except Exception:
            pass
    log(f"consolidated {len(AGGREGATE_TOPICS)} aggregate topics", "ok")


# =============================================================================
# Main
# =============================================================================

def main():
    print("=" * 60)
    print("  ICM Backfill")
    print("=" * 60)

    if VERIFY:
        sys.exit(verify_against_baseline())

    sources = []
    if RUN_CLAUDE:
        sources.append("Claude Code")
    if RUN_CODEX:
        sources.append("Codex CLI")
    print(f"  Sources: {', '.join(sources)}")
    print(f"  Mode:    {'DRY RUN' if DRY_RUN else 'LIVE'}"
          f"{' | FULL' if FULL else ' | incremental'}"
          f"{' | +import' if IMPORT_SESSIONS else ''}"
          f"{' | +maintain' if MAINTAIN else ''}")

    try:
        result = _run(["rtk", "icm", "health"], timeout=15)
        if result.returncode != 0:
            print(f"\n  Error: rtk icm health failed: {result.stderr.strip()}")
            sys.exit(1)
        lines = result.stdout.strip().split("\n")
        print(f"  ICM:     {lines[-1] if lines else ''}")
    except FileNotFoundError:
        print("\n  Error: 'rtk' not found. Install RTK first.")
        sys.exit(1)

    state = load_state()

    if RUN_CLAUDE:
        claude_memory_files(state)
        claude_instruction_files(state)
        claude_session_meta()
        claude_plans(state)
        claude_history(state)
        claude_session_summaries()
        claude_insights()
        claude_research(state)
        if IMPORT_SESSIONS:
            claude_import_sessions(state)

    if RUN_CODEX:
        codex_instruction_files(state)
        codex_sessions(state)
        codex_insights()

    save_state(state)

    if not DRY_RUN and (stats["stored"] or stats["replaced"] or stats["imported"]):
        print("\n  Generating embeddings...")
        try:
            result = _run(["rtk", "icm", "embed"], timeout=300)
            if result.stdout.strip():
                log(result.stdout.strip(), "ok")
        except Exception as e:
            log(f"Embedding error: {e}", "warn")

    # Reconcile after new-scheme topics are freshly written this run, so their
    # legacy twins are guaranteed present to match against.
    reconcile_topics()

    if MAINTAIN:
        maintenance()

    print("\n" + "=" * 60)
    print(f"  Stored:      {stats['stored']}")
    print(f"  Replaced:    {stats['replaced']}")
    print(f"  Imported:    {stats['imported']}")
    print(f"  Extracted:   {stats['extracted']}")
    print(f"  Reconciled:  {stats['reconciled']}")
    print(f"  Duplicates:  {stats['duplicates']}")
    print(f"  Errors:      {stats['errors']}")
    print("=" * 60)
    print("\n  Dry run. Re-run without --dry-run to store." if DRY_RUN
          else "\n  Done! Run 'rtk icm health' to verify.")


if __name__ == "__main__":
    main()
