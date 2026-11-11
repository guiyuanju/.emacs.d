"""Print the material for one day's work report as Markdown.

Usage: iuiw-work-report.py DATE --repo DIR... --workspace DIR...
Gathers the user's commits, project.md log lines, Claude Code and Codex
prompts and, for today, uncommitted changes; strings that look like
secrets are masked.
"""

import argparse
import datetime as dt
import glob
import json
import os
import re
import subprocess

HOME = os.path.expanduser("~")
MAX_PROMPT = 300
MAX_PROMPTS = 15
MAX_FILES = 8

SECRETS = [
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S), "[私钥]"),
    (re.compile(r"\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}"), "[密钥]"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"), "[密钥]"),
    (re.compile(r"\bglpat-[A-Za-z0-9_-]{16,}"), "[密钥]"),
    (re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"), "[密钥]"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "[密钥]"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"), "[JWT]"),
    (re.compile(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{12,}"), r"\1 [密钥]"),
    (re.compile(r"(://[^/\s:@]+):[^/\s@]+@"), r"\1:[密码]@"),
    (re.compile(r"(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)"
                r"(\s*[:=]\s*)([\"']?)[^\s\"',;]{4,}\3"), r"\1\2[已隐去]"),
    (re.compile(r"\b(?:otpauth://\S+)"), "[OTP]"),
    (re.compile(r"(?<![\w/.+-])(?=[\w+/=-]*\d)(?=[\w+/=-]*[A-Z])(?=[\w+/=-]*[a-z])"
                r"[A-Za-z0-9+/_=-]{32,}"), "[长串]"),
]


def mask(text):
    for pattern, replacement in SECRETS:
        text = pattern.sub(replacement, text)
    return text


def git(repo, *args):
    result = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else ""


def short(path):
    return path.replace(HOME, "~", 1) if path.startswith(HOME) else path


def project_of(path, workspaces):
    """Name the project a directory belongs to, like okj/debug."""
    for ws in workspaces:
        prefix = os.path.join(ws, "projects") + os.sep
        if path.startswith(prefix):
            return f"{os.path.basename(ws)}/{path[len(prefix):].split(os.sep)[0]}"
    if path == os.path.join(HOME, ".emacs.d") or path.startswith(os.path.join(HOME, ".emacs.d") + os.sep):
        return "me/emacs"
    return short(path)


def commits(repos, workspaces, since, until):
    out = []
    for repo in repos:
        email = git(repo, "config", "user.email").strip()
        log = git(repo, "log", "--all", "--no-merges", f"--since={since}", f"--until={until}",
                  f"--author={email}", "--date=format:%H:%M", "--format=@@%ad\t%s", "--name-only")
        entries = []
        for block in log.split("@@")[1:]:
            lines = [line for line in block.splitlines() if line.strip()]
            time, subject = lines[0].split("\t", 1)
            files = lines[1:]
            more = f" 等 {len(files)} 个" if len(files) > MAX_FILES else ""
            entries.append(f"- {time} {subject}（{', '.join(files[:MAX_FILES])}{more}）")
        if entries:
            out.append(f"### {project_of(repo, workspaces)}（{short(repo)}）")
            out.extend(sorted(set(entries)))
    return out


def log_lines(workspaces, day):
    out = []
    for ws in workspaces:
        for card in sorted(glob.glob(os.path.join(ws, "projects", "*", "project.md"))):
            with open(card, encoding="utf-8") as f:
                lines = [line.rstrip() for line in f if line.startswith(f"- {day} ")]
            if lines:
                out.append(f"### {project_of(os.path.dirname(card), workspaces)}")
                out.extend(lines)
    return out


def uncommitted(repos, workspaces, day):
    out = []
    for repo in repos:
        files = []
        for line in git(repo, "status", "--porcelain").splitlines():
            name = line[3:].split(" -> ")[-1].strip('"')
            path = os.path.join(repo, name)
            if os.path.exists(path) and dt.date.fromtimestamp(os.path.getmtime(path)).isoformat() == day:
                files.append(name)
        if files:
            more = f" 等 {len(files)} 个" if len(files) > MAX_FILES else ""
            out.append(f"- {project_of(repo, workspaces)}：{', '.join(files[:MAX_FILES])}{more}")
    return out


def local_day(timestamp):
    """The local date of an ISO timestamp ending in Z."""
    when = dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    return when.astimezone().date().isoformat(), when.astimezone().strftime("%H:%M")


def prompt_text(text):
    text = text.strip()
    if (not text or text.startswith("<") or text.startswith("Base directory for this skill")
            or text.startswith("# AGENTS.md") or text.startswith("Caveat:")):
        return None
    text = re.sub(r"\s+", " ", text)
    return text[:MAX_PROMPT] + ("…" if len(text) > MAX_PROMPT else "")


def claude_sessions(day):
    sessions = []
    for path in glob.glob(os.path.join(HOME, ".claude", "projects", "*", "*.jsonl")):
        if dt.date.fromtimestamp(os.path.getmtime(path)).isoformat() < day:
            continue
        title, cwd, prompts = None, None, []
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                if record.get("type") == "ai-title":
                    title = record.get("aiTitle")
                if record.get("type") != "user" or record.get("isMeta") or record.get("isSidechain"):
                    continue
                stamp = record.get("timestamp")
                if not stamp or local_day(stamp)[0] != day:
                    continue
                cwd = cwd or record.get("cwd")
                content = record.get("message", {}).get("content")
                parts = [content] if isinstance(content, str) else [
                    c.get("text", "") for c in content or [] if c.get("type") == "text"]
                for part in parts:
                    if text := prompt_text(part):
                        prompts.append((local_day(stamp)[1], text))
        if prompts and cwd:
            sessions.append(("Claude", cwd, title, prompts))
    return sessions


def codex_sessions(day):
    sessions = []
    for path in glob.glob(os.path.join(HOME, ".codex", "sessions", *day.split("-"), "*.jsonl")):
        cwd, prompts = None, []
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                payload = record.get("payload") or {}
                if record.get("type") == "session_meta":
                    cwd = payload.get("cwd")
                elif payload.get("type") == "message" and payload.get("role") == "user":
                    stamp = record.get("timestamp")
                    if not stamp or local_day(stamp)[0] != day:
                        continue
                    for c in payload.get("content") or []:
                        if text := prompt_text(c.get("text", "")):
                            prompts.append((local_day(stamp)[1], text))
        if prompts and cwd:
            sessions.append(("Codex", cwd, None, prompts))
    return sessions


def sessions(workspaces, day):
    out = []
    found = claude_sessions(day) + codex_sessions(day)
    found.sort(key=lambda s: (project_of(s[1], workspaces), s[3][0][0]))
    for agent, cwd, title, prompts in found:
        out.append(f"### {project_of(cwd, workspaces)} · {agent}" + (f" · {title}" if title else ""))
        for time, text in prompts[:MAX_PROMPTS]:
            out.append(f"- {time} {text}")
        if len(prompts) > MAX_PROMPTS:
            out.append(f"- （另有 {len(prompts) - MAX_PROMPTS} 条）")
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("date")
    parser.add_argument("--repo", action="append", default=[])
    parser.add_argument("--workspace", action="append", default=[])
    args = parser.parse_args()
    day = args.date
    workspaces = [os.path.expanduser(w).rstrip(os.sep) for w in args.workspace]
    repos = [os.path.expanduser(r).rstrip(os.sep) for r in args.repo]
    for ws in workspaces:
        repos.append(ws)
        repos.extend(os.path.dirname(g) for g in
                     sorted(glob.glob(os.path.join(ws, "projects", "*", "*", ".git"))))
    repos = list(dict.fromkeys(r for r in repos if os.path.isdir(os.path.join(r, ".git"))))
    next_day = (dt.date.fromisoformat(day) + dt.timedelta(days=1)).isoformat()

    parts = [("项目日志", log_lines(workspaces, day)),
             ("提交", commits(repos, workspaces, f"{day} 00:00", f"{next_day} 00:00")),
             ("agent 会话里的提问", sessions(workspaces, day))]
    if day == dt.date.today().isoformat():
        parts.append(("今天改过但未提交", uncommitted(repos, workspaces, day)))
    body = "\n\n".join(f"## {name}\n" + "\n".join(lines) for name, lines in parts if lines)
    print(mask(body))


if __name__ == "__main__":
    main()
