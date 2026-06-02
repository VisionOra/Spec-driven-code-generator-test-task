#!/usr/bin/env python3
"""
Usage:
  python generator/generate.py --lang swift  --output clients/swift/Sources/messaging-cli/
  python generator/generate.py --lang kotlin --output clients/kotlin/app/src/main/kotlin/com/messaging/
"""
import argparse, subprocess, sys
from pathlib import Path

SPEC      = Path("spec/protocol-spec.md")
PROMPTS   = Path("generator/prompts")
MAX_RETRY = 2

def build_prompt(lang: str, spec: str, out_dir: Path, errors: str = "") -> str:
    template = (PROMPTS / f"{lang}_prompt.md").read_text()
    prompt = template.replace("{{SPEC}}", spec).replace("{{OUTPUT_DIR}}", str(out_dir))
    if errors:
        prompt += f"\n\n## COMPILATION ERRORS — fix these\n```\n{errors[:1500]}\n```\nRewrite only the files that have errors and save them to the same output directory."
    return prompt

def call_claude(prompt: str, out_dir: Path) -> None:
    result = subprocess.run(
        ["claude", "--print", "--dangerously-skip-permissions",
         "--add-dir", str(out_dir.resolve())],
        input=prompt, capture_output=True, text=True, timeout=600
    )
    print(result.stdout[-2000:] if len(result.stdout) > 2000 else result.stdout)
    if result.returncode != 0:
        print(f"Claude error:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)

def compile_check(lang: str, out_dir: Path) -> tuple[bool, str]:
    if lang == "swift":
        # out_dir = clients/swift/Sources/messaging-cli/ → parents[1] = clients/swift/
        r = subprocess.run(["swift", "build"], cwd=out_dir.parents[1],
                           capture_output=True, text=True, timeout=300)
    else:
        # out_dir = clients/kotlin/src/main/kotlin/com/messaging/ → parents[5] = clients/kotlin/
        r = subprocess.run(["./gradlew", "compileKotlin"], cwd=out_dir.parents[5],
                           capture_output=True, text=True, timeout=300)
    return r.returncode == 0, r.stderr + r.stdout

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang",   required=True, choices=["swift", "kotlin"])
    ap.add_argument("--output", required=True, type=Path)
    args = ap.parse_args()

    out_dir = args.output.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    spec   = SPEC.read_text()
    errors = ""

    for attempt in range(1, MAX_RETRY + 1):
        print(f"[{args.lang}] attempt {attempt}/{MAX_RETRY} — calling Claude...")
        call_claude(build_prompt(args.lang, spec, out_dir, errors), out_dir)

        files = list(out_dir.glob(f"*.{'swift' if args.lang == 'swift' else 'kt'}"))
        if not files:
            print(f"No {'Swift' if args.lang == 'swift' else 'Kotlin'} files found in {out_dir}", file=sys.stderr)
            sys.exit(1)
        print(f"  found: {[f.name for f in files]}")

        ok, errors = compile_check(args.lang, out_dir)
        if ok:
            print(f"[{args.lang}] ✓ compiled successfully")
            return
        print(f"[{args.lang}] compile failed:\n{errors[:500]}")

    print(f"[{args.lang}] failed after {MAX_RETRY} attempts — fix prompts and retry")
    sys.exit(1)

if __name__ == "__main__":
    main()
