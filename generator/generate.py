#!/usr/bin/env python3
"""
Usage:
  python generator/generate.py --lang swift  --output clients/swift/Sources/messaging-cli/
  python generator/generate.py --lang kotlin --output clients/kotlin/app/src/main/kotlin/com/messaging/
"""
import argparse, subprocess, sys, re
from pathlib import Path

SPEC      = Path("spec/protocol-spec.md")
PROMPTS   = Path("generator/prompts")
MAX_RETRY = 2

def build_prompt(lang: str, spec: str, errors: str = "") -> str:
    template = (PROMPTS / f"{lang}_prompt.md").read_text()
    prompt = template.replace("{{SPEC}}", spec)
    if errors:
        prompt += f"\n\n## COMPILATION ERRORS — fix these\n```\n{errors[:1500]}\n```\nRegenerate all files with fixes applied."
    return prompt

def call_claude(prompt: str) -> str:
    result = subprocess.run(
        ["claude", "--print"],
        input=prompt, capture_output=True, text=True, timeout=300
    )
    if result.returncode != 0:
        print(f"Claude error:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    return result.stdout

def extract_files(output: str) -> dict[str, str]:
    # Matches: ```swift\n// filename: Foo.swift\ncontent\n```
    pattern = r'```(?:swift|kotlin)\n// filename: ([^\n]+)\n(.*?)```'
    files = {}
    for m in re.finditer(pattern, output, re.DOTALL):
        files[m.group(1).strip()] = m.group(2)
    return files

def write_files(files: dict[str, str], out_dir: Path):
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        header = f"// GENERATED — regenerate: python generator/generate.py --lang {'swift' if name.endswith('.swift') else 'kotlin'} --output {out_dir}\n"
        (out_dir / name).write_text(header + content)
        print(f"  wrote {out_dir / name}")

def compile_check(lang: str, root: Path) -> tuple[bool, str]:
    if lang == "swift":
        r = subprocess.run(["swift", "build"], cwd=root.parents[2],
                           capture_output=True, text=True)
    else:
        r = subprocess.run(["./gradlew", "compileKotlin"], cwd=root.parents[3],
                           capture_output=True, text=True)
    return r.returncode == 0, r.stderr + r.stdout

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang",   required=True, choices=["swift", "kotlin"])
    ap.add_argument("--output", required=True, type=Path)
    args = ap.parse_args()

    spec   = SPEC.read_text()
    errors = ""

    for attempt in range(1, MAX_RETRY + 1):
        print(f"[{args.lang}] attempt {attempt}/{MAX_RETRY}...")
        output = call_claude(build_prompt(args.lang, spec, errors))
        files  = extract_files(output)

        if not files:
            print("No files extracted — check prompt output format", file=sys.stderr)
            print(output[:500])
            sys.exit(1)

        write_files(files, args.output)
        ok, errors = compile_check(args.lang, args.output)

        if ok:
            print(f"[{args.lang}] ✓ compiled successfully")
            return

        print(f"[{args.lang}] compile failed:\n{errors[:300]}")

    print(f"[{args.lang}] failed after {MAX_RETRY} attempts — fix prompts and retry")
    sys.exit(1)

if __name__ == "__main__":
    main()
