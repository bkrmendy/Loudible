#!/usr/bin/env python3
"""Scaffold a repo-local skill shared by Codex and Claude Code."""

import argparse
import json
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name", help="Lowercase letters, digits and hyphens; fewer than 64 characters")
    parser.add_argument("description", help="What the skill does and when to use it")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", args.name) or len(args.name) >= 64:
        parser.error("name must contain lowercase words or digits separated by single hyphens, under 64 characters")
    if args.name in {"synced", "anthropic-skills"}:
        parser.error("that name is reserved by Claude Code")
    if not args.description.strip():
        parser.error("description must not be empty")

    root = Path(__file__).resolve().parent.parent
    skill = root / ".agents" / "skills" / args.name
    alias = root / ".claude" / "skills" / args.name
    for path in (skill, alias):
        if path.exists() or path.is_symlink():
            parser.error(f"refusing to overwrite {path.relative_to(root)}")

    skill.mkdir(parents=True)
    # JSON strings are valid YAML scalars and safely quote punctuation and newlines.
    (skill / "SKILL.md").write_text(
        f"---\nname: {args.name}\ndescription: {json.dumps(args.description.strip())}\n---\n\n"
        "TODO: Replace this paragraph with the workflow-specific instructions.\n"
        "Keep shared repository rules in AGENTS.md. Use relative links for supporting files.\n",
        encoding="utf-8",
    )
    alias.parent.mkdir(parents=True, exist_ok=True)
    alias.symlink_to(f"../../.agents/skills/{args.name}", target_is_directory=True)
    print(f"Created {skill.relative_to(root)}/SKILL.md")
    print(f"Linked {alias.relative_to(root)} -> ../../.agents/skills/{args.name}")
    print("Replace the TODO instructions before using the skill, then commit the folder and symlink.")


if __name__ == "__main__":
    main()
