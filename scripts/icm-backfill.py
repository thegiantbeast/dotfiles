#!/usr/bin/env python3
"""
ICM Backfill — Enrich rtk icm database from Claude Code and Codex CLI session data.

Sources (Claude Code — ~/.claude/):
  1. Memory files (projects/*/memory/*.md) — project knowledge, feedback, user info
  2. CLAUDE.md + RTK.md — global and per-project coding instructions
  3. Session JSONL files — failed tool calls, error patterns
  4. Plans (plans/*.md) — architectural decisions, root cause analyses
  5. History index (history.jsonl) — prompt patterns, project usage frequency
  6. Sessions index (sessions-index.json) — session summaries with git branches

Sources (Codex CLI — ~/.codex/):
  7. Session JSONL files — failed shell commands, error patterns
  8. AGENTS.md — global and per-project agent instructions

Sources (Codex VSCode — ~/Library/Application Support/Code/):
  9. Global storage chat sessions

Usage:
  python3 icm-backfill.py [--dry-run] [--verbose] [--source claude|codex|all]
"""

import ast
import json
import os
import subprocess
import sys
import glob
from pathlib import Path
from collections import Counter, defaultdict

HOME = Path.home()
CLAUDE_DIR = HOME / ".claude"
CODEX_DIR = HOME / ".codex"
CODEX_VSCODE_GLOBAL = HOME / "Library" / "Application Support" / "Code" / "User" / "globalStorage"
CODE_DIR = HOME / "Code"

DRY_RUN = "--dry-run" in sys.argv
VERBOSE = "--verbose" in sys.argv

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
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            stderr = result.stderr.lower()
            if "similar" in stderr or "duplicate" in stderr:
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


def icm_extract(text, project):
    """Use rtk icm extract for rule-based fact extraction."""
    if DRY_RUN:
        stats["extracted"] += 1
        log(f"[DRY-RUN] extract '{project}': {len(text)} chars", "debug")
        return True

    try:
        result = subprocess.run(
            ["rtk", "icm", "extract", "-p", project],
            input=text[:10000], capture_output=True, text=True, timeout=60
        )
        if result.returncode == 0:
            stats["extracted"] += 1
            if result.stdout.strip():
                log(f"Extracted from '{project}': {result.stdout.strip()[:100]}", "debug")
            return True
        else:
            stats["errors"] += 1
            return False
    except Exception as e:
        log(f"Extract error: {e}", "err")
        stats["errors"] += 1
        return False


def derive_project_name(encoded_dir):
    """Turn e.g. '-Users-john-Code-myorg-myrepo-main' into 'myorg-myrepo-main'."""
    parts = encoded_dir.split("-")
    for i, p in enumerate(parts):
        if p in ("Code", "code") and i + 2 < len(parts):
            return "-".join(parts[i + 1:])
    return encoded_dir


def should_skip_path(path_str):
    """Check if any path component is in the skip list."""
    return any(f"/{d}/" in path_str or path_str.endswith(f"/{d}") for d in SKIP_DIRS)


def categorize_error(error_text):
    """Categorize an error string into a bucket."""
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
    """Deduplicate and store categorized errors."""
    categories = defaultdict(list)
    for fc in failed_commands:
        categories[categorize_error(fc["error"])].append(fc)

    log(f"[{source_label}] {len(failed_commands)} failed calls across {len(categories)} categories", "info")

    for category, errors in categories.items():
        seen = set()
        unique = []
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

        icm_store(
            topic=f"errors/{source_label.lower()}/{category}",
            content=content,
            importance="medium" if len(errors) < 5 else "high",
            keywords=f"errors,{category},{source_label.lower()}",
            raw="\n".join(e["error"][:200] for e in unique[:5]),
        )
        log(f"  {category}: {len(unique)} unique errors", "ok")


# =============================================================================
# Claude Code sources
# =============================================================================

def claude_memory_files():
    print("\n[Claude] Memory files...")
    for mf in glob.glob(str(CLAUDE_DIR / "projects" / "*" / "memory" / "*.md")):
        path = Path(mf)
        if path.name == "MEMORY.md":
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
        topic = f"memory/{project_name}"

        icm_store(
            topic=topic,
            content=f"[{mem_type}] {description}: {content[:1500]}",
            importance=importance,
            keywords=f"{mem_type},{project_name},{path.stem}",
        )
        log(f"{path.name} -> {topic}", "ok")


def claude_instruction_files():
    print("\n[Claude] Instruction files (CLAUDE.md, RTK.md)...")

    # Global files in ~/.claude/
    for name, importance in [("CLAUDE.md", "critical"), ("RTK.md", "high")]:
        path = CLAUDE_DIR / name
        if path.exists():
            content = path.read_text().strip()
            if content:
                icm_store(
                    topic="instructions/global",
                    content=f"Global {name}: {content}",
                    importance=importance,
                    keywords=f"claude-md,instructions,global,{name.lower()}",
                )
                log(f"Global {name}", "ok")

    # Project-level CLAUDE.md files
    if CODE_DIR.exists():
        for cmd_path in CODE_DIR.rglob("CLAUDE.md"):
            if should_skip_path(str(cmd_path)):
                continue
            try:
                content = cmd_path.read_text().strip()
                if not content or len(content) < 20:
                    continue
            except Exception:
                continue

            project_name = str(cmd_path.relative_to(CODE_DIR).parent).replace("/", "-")
            icm_store(
                topic=f"instructions/{project_name}",
                content=f"Project CLAUDE.md for {project_name}: {content[:2000]}",
                importance="high",
                keywords=f"claude-md,instructions,{project_name}",
            )
            log(f"CLAUDE.md: {cmd_path}", "ok")


def claude_sessions():
    print("\n[Claude] Session data (failed commands, errors)...")
    failed_commands = []

    session_files = glob.glob(str(CLAUDE_DIR / "projects" / "*" / "*.jsonl"))
    log(f"Found {len(session_files)} session files", "info")

    for sf in session_files:
        path = Path(sf)
        project_name = derive_project_name(path.parent.name)

        try:
            with open(sf) as f:
                for line in f:
                    try:
                        obj = json.loads(line.strip())
                    except json.JSONDecodeError:
                        continue

                    if obj.get("type") != "user":
                        continue

                    message = obj.get("message", {})
                    if not isinstance(message, dict):
                        continue
                    content = message.get("content", [])
                    if not isinstance(content, list):
                        continue

                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        if block.get("type") == "tool_result" and block.get("is_error"):
                            error_text = ""
                            bc = block.get("content", "")
                            if isinstance(bc, str):
                                error_text = bc
                            elif isinstance(bc, list):
                                error_text = "".join(
                                    c.get("text", "") for c in bc
                                    if isinstance(c, dict) and c.get("type") == "text"
                                )
                            if error_text and len(error_text) > 10:
                                failed_commands.append({
                                    "project": project_name,
                                    "error": error_text[:500],
                                })
        except Exception as e:
            log(f"Error reading {sf}: {e}", "debug")

    store_error_categories(failed_commands, "Claude")


def claude_plans():
    print("\n[Claude] Plans...")
    plans_dir = CLAUDE_DIR / "plans"
    if not plans_dir.exists():
        log("No plans directory", "warn")
        return

    plan_files = list(plans_dir.glob("*.md"))
    log(f"Found {len(plan_files)} plan files", "info")

    for pf in plan_files:
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

        icm_extract(content[:5000], "plans")
        icm_store(
            topic="plans",
            content=f"Plan: {title}\n\n{content[:1500]}",
            importance="medium",
            keywords=f"plans,architecture,{pf.stem}",
        )
        log(f"{title[:60]}", "ok")


def claude_history():
    print("\n[Claude] History patterns...")
    history_file = CLAUDE_DIR / "history.jsonl"
    if not history_file.exists():
        log("No history.jsonl", "warn")
        return

    project_usage = Counter()
    prompt_patterns = Counter()
    count = 0

    with open(history_file) as f:
        for line in f:
            try:
                obj = json.loads(line.strip())
            except json.JSONDecodeError:
                continue
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

    if project_usage:
        usage_text = "Claude Code project usage:\n" + "\n".join(
            f"  {c:3d}x  {p}" for p, c in project_usage.most_common(15)
        )
        icm_store("usage/claude-projects", usage_text, "medium", "usage,projects,claude")
        log(f"Project usage: {len(project_usage)} projects", "ok")

    if prompt_patterns:
        pattern_text = "Claude Code prompt patterns:\n" + "\n".join(
            f"  {c:3d}x  {p}" for p, c in prompt_patterns.most_common()
        )
        icm_store("usage/claude-patterns", pattern_text, "medium", "usage,patterns,claude")
        log(f"Patterns: {dict(prompt_patterns)}", "ok")


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

        original_path = data.get("originalPath", "")
        project_name = Path(original_path).name if original_path else "unknown"

        for entry in data.get("entries", []):
            summary = entry.get("summary", "")
            if entry.get("messageCount", 0) < 5:
                continue
            if not summary or len(summary) < 20 or summary.startswith("API Error"):
                continue

            all_sessions.append({
                "project": project_name,
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

        icm_store(
            topic=f"sessions/claude/{project}",
            content=f"Claude sessions for {project} ({len(sessions)}):\n\n" + "\n\n".join(lines),
            importance="medium",
            keywords=f"sessions,claude,{project}",
        )
        log(f"{project}: {len(sessions)} sessions", "ok")

    if all_sessions:
        combined = "\n".join(f"{s['project']}: {s['summary']}" for s in all_sessions if s["summary"])
        if combined:
            icm_extract(combined, "claude-session-summaries")


def claude_insights():
    """Ingest /insights facet data — pre-analyzed session metadata with goals,
    satisfaction, friction points, and summaries (generated by Haiku)."""
    print("\n[Claude] Insights facets...")
    facets_dir = CLAUDE_DIR / "usage-data" / "facets"
    if not facets_dir.exists():
        log("No facets directory (run /insights first)", "warn")
        return

    facet_files = list(facets_dir.glob("*.json"))
    log(f"Found {len(facet_files)} facet files", "info")

    # Aggregate across all facets
    all_friction = []
    goal_categories = Counter()
    satisfaction = Counter()
    helpfulness = Counter()
    session_types = Counter()
    summaries = []

    for ff in facet_files:
        try:
            with open(ff) as f:
                facet = json.load(f)
        except Exception:
            continue

        # Aggregate goal categories
        for cat, count in facet.get("goal_categories", {}).items():
            goal_categories[cat] += count

        # Aggregate satisfaction
        for level, count in facet.get("user_satisfaction_counts", {}).items():
            satisfaction[level] += count

        # Aggregate helpfulness
        h = facet.get("claude_helpfulness", "")
        if h:
            helpfulness[h] += 1

        # Aggregate session types
        st = facet.get("session_type", "")
        if st:
            session_types[st] += 1

        # Collect friction details (high-value learning signals)
        friction = facet.get("friction_detail", "")
        friction_counts = facet.get("friction_counts", {})
        if friction and len(friction) > 10:
            all_friction.append({
                "detail": friction,
                "counts": friction_counts,
                "goal": facet.get("underlying_goal", ""),
                "session_id": facet.get("session_id", ff.stem),
            })

        # Collect summaries
        summary = facet.get("brief_summary", "")
        if summary:
            summaries.append(summary)

    # Store aggregated insights
    if goal_categories:
        content = "Claude Code goal categories (from /insights):\n" + "\n".join(
            f"  {c:3d}x  {g}" for g, c in goal_categories.most_common()
        )
        icm_store("insights/goals", content, "medium", "insights,goals,claude")
        log(f"Goals: {len(goal_categories)} categories", "ok")

    if satisfaction:
        content = "Claude Code user satisfaction (from /insights):\n" + "\n".join(
            f"  {c:3d}x  {level}" for level, c in satisfaction.most_common()
        )
        icm_store("insights/satisfaction", content, "medium", "insights,satisfaction,claude")
        log(f"Satisfaction: {dict(satisfaction)}", "ok")

    if helpfulness:
        content = "Claude Code helpfulness ratings:\n" + "\n".join(
            f"  {c:3d}x  {h}" for h, c in helpfulness.most_common()
        )
        icm_store("insights/helpfulness", content, "medium", "insights,helpfulness,claude")
        log(f"Helpfulness: {dict(helpfulness)}", "ok")

    if session_types:
        content = "Claude Code session types:\n" + "\n".join(
            f"  {c:3d}x  {t}" for t, c in session_types.most_common()
        )
        icm_store("insights/session-types", content, "medium", "insights,session-types,claude")
        log(f"Session types: {dict(session_types)}", "ok")

    # Store friction details — these are the most actionable for learning
    if all_friction:
        # Store individual high-value friction entries
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
        icm_store(
            topic="insights/friction",
            content=content,
            importance="high",
            keywords="insights,friction,mistakes,learning,claude",
        )
        log(f"Friction: {len(all_friction)} entries", "ok")

        # Also extract patterns from friction details
        friction_text = "\n".join(fr["detail"] for fr in all_friction)
        if friction_text:
            icm_extract(friction_text, "claude-friction-patterns")

    # Extract from summaries batch
    if summaries:
        icm_extract("\n".join(summaries), "claude-insights-summaries")
        log(f"Extracted from {len(summaries)} session summaries", "ok")


# =============================================================================
# Codex CLI sources
# =============================================================================

def _parse_codex_payload(raw_payload):
    """Parse a Codex payload which may be a dict or a repr'd dict string."""
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


def codex_sessions():
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
        try:
            with open(sf) as f:
                current_project = "unknown"
                # Map call_id -> command for correlating errors
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

                    # Extract project from session_meta
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

                        # Track outgoing function calls
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

                        # Check function_call_output for errors
                        elif ptype == "function_call_output":
                            call_id = payload.get("call_id", "")
                            output_raw = payload.get("output", "")

                            # Parse output (may be JSON string with metadata)
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

                            # Detect errors: non-zero exit code or error keywords
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

    store_error_categories(failed_commands, "Codex")

    # Store session overview
    if session_metas:
        by_originator = Counter(m["originator"] for m in session_metas)
        by_project = Counter(m["project"] for m in session_metas)
        overview = (
            f"Codex session overview ({len(session_metas)} sessions):\n"
            f"By originator: {dict(by_originator)}\n"
            f"Top projects: {dict(by_project.most_common(10))}"
        )
        icm_store("usage/codex-sessions", overview, "medium", "usage,codex,sessions")
        log(f"Session overview: {len(session_metas)} sessions", "ok")


def codex_instruction_files():
    print("\n[Codex] Instruction files (AGENTS.md)...")
    if not CODEX_DIR.exists():
        log("No ~/.codex/ directory, skipping", "warn")
        return

    # Global AGENTS.md
    agents_md = CODEX_DIR / "AGENTS.md"
    if agents_md.exists():
        content = agents_md.read_text().strip()
        if content and len(content) > 10:
            icm_store(
                topic="instructions/global",
                content=f"Global Codex AGENTS.md: {content}",
                importance="critical",
                keywords="agents-md,instructions,global,codex",
            )
            log("Global AGENTS.md", "ok")

    # Codex RTK.md
    rtk_md = CODEX_DIR / "RTK.md"
    if rtk_md.exists():
        content = rtk_md.read_text().strip()
        if content and len(content) > 10:
            icm_store(
                topic="instructions/global",
                content=f"Codex RTK.md: {content}",
                importance="high",
                keywords="rtk,instructions,codex",
            )
            log("Codex RTK.md", "ok")

    # Project-level AGENTS.md files
    if CODE_DIR.exists():
        for agents_path in CODE_DIR.rglob("AGENTS.md"):
            if should_skip_path(str(agents_path)):
                continue
            try:
                content = agents_path.read_text().strip()
                if not content or len(content) < 20:
                    continue
            except Exception:
                continue

            project_name = str(agents_path.relative_to(CODE_DIR).parent).replace("/", "-")
            icm_store(
                topic=f"instructions/{project_name}",
                content=f"Project AGENTS.md for {project_name}: {content[:2000]}",
                importance="high",
                keywords=f"agents-md,instructions,codex,{project_name}",
            )
            log(f"AGENTS.md: {agents_path}", "ok")


def codex_insights():
    """Ingest Codex's stage1_outputs (rollout summaries and extracted memories)
    and threads table (session metadata with titles, tokens, branches)."""
    print("\n[Codex] Insights (threads + stage1_outputs)...")
    state_db = CODEX_DIR / "state_5.sqlite"
    if not state_db.exists():
        # Try other versioned names
        candidates = list(CODEX_DIR.glob("state_*.sqlite"))
        if candidates:
            state_db = candidates[-1]  # highest version
        else:
            log("No Codex state database found, skipping", "warn")
            return

    import sqlite3 as sqlite3_mod

    try:
        conn = sqlite3_mod.connect(str(state_db))
        conn.row_factory = sqlite3_mod.Row
    except Exception as e:
        log(f"Cannot open {state_db}: {e}", "err")
        return

    # --- Threads (session metadata) ---
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

        # Store session overview
        lines = []
        project_usage = Counter()
        for r in rows:
            project = Path(r["cwd"]).name if r["cwd"] else "unknown"
            project_usage[project] += 1
            title = r["title"] or r["first_user_message"][:80] or "(untitled)"
            branch = r["git_branch"] or ""
            tokens = r["tokens_used"]
            lines.append(f"  [{branch}] {title[:80]} ({tokens} tokens)")

        if project_usage:
            overview = (
                f"Codex thread overview ({len(rows)} sessions):\n"
                f"By project: {dict(project_usage.most_common(10))}\n\n"
                + "\n".join(lines[:30])
            )
            icm_store("usage/codex-threads", overview, "medium", "usage,codex,threads")
            log(f"Thread overview: {len(rows)} sessions", "ok")
    else:
        log("No threads with token usage found", "debug")

    # --- stage1_outputs (Codex's memory extraction / rollout summaries) ---
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

        summaries = []
        memories = []
        for r in s1_rows:
            summary = r["rollout_summary"]
            raw_mem = r["raw_memory"]
            slug = r["rollout_slug"] or r["thread_id"]

            if summary and len(summary) > 20:
                summaries.append(f"[{slug}] {summary[:300]}")
            if raw_mem and len(raw_mem) > 20:
                memories.append(raw_mem)

        if summaries:
            content = f"Codex rollout summaries ({len(summaries)}):\n\n" + "\n\n".join(summaries[:30])
            icm_store(
                topic="insights/codex-summaries",
                content=content,
                importance="medium",
                keywords="insights,codex,summaries,rollouts",
            )
            log(f"Rollout summaries: {len(summaries)}", "ok")

        if memories:
            # Extract facts from raw extracted memories
            combined = "\n\n".join(memories[:50])
            icm_extract(combined, "codex-extracted-memories")
            log(f"Extracted from {len(memories)} raw memories", "ok")
    else:
        log("No stage1_outputs found", "debug")

    conn.close()


# =============================================================================
# Main
# =============================================================================

def main():
    print("=" * 60)
    print("  ICM Backfill")
    print("=" * 60)
    sources = []
    if RUN_CLAUDE:
        sources.append("Claude Code")
    if RUN_CODEX:
        sources.append("Codex CLI/VSCode")
    print(f"  Sources: {', '.join(sources)}")
    print(f"  Mode:    {'DRY RUN' if DRY_RUN else 'LIVE'}")

    # Verify rtk icm is available
    try:
        result = subprocess.run(["rtk", "icm", "health"], capture_output=True, text=True, timeout=10)
        if result.returncode != 0:
            print(f"\n  Error: rtk icm health failed: {result.stderr.strip()}")
            sys.exit(1)
        # Print just the summary line
        lines = result.stdout.strip().split("\n")
        summary = lines[-1] if lines else ""
        print(f"  ICM:     {summary}")
    except FileNotFoundError:
        print("\n  Error: 'rtk' not found. Install RTK first.")
        sys.exit(1)

    if RUN_CLAUDE:
        claude_memory_files()
        claude_instruction_files()
        claude_sessions()
        claude_plans()
        claude_history()
        claude_session_summaries()
        claude_insights()

    if RUN_CODEX:
        codex_instruction_files()
        codex_sessions()
        codex_insights()

    # Post-processing: generate embeddings
    if not DRY_RUN and stats["stored"] > 0:
        print("\n  Generating embeddings...")
        try:
            result = subprocess.run(
                ["rtk", "icm", "embed"],
                capture_output=True, text=True, timeout=300
            )
            if result.stdout.strip():
                log(result.stdout.strip(), "ok")
        except Exception as e:
            log(f"Embedding error: {e}", "warn")

    print("\n" + "=" * 60)
    print(f"  Stored:     {stats['stored']}")
    print(f"  Extracted:  {stats['extracted']}")
    print(f"  Duplicates: {stats['duplicates']}")
    print(f"  Errors:     {stats['errors']}")
    print("=" * 60)

    if DRY_RUN:
        print("\n  Dry run. Re-run without --dry-run to store.")
    else:
        print("\n  Done! Run 'rtk icm health' to verify.")


if __name__ == "__main__":
    main()
