#!/usr/bin/env bash
# 真实 TypeScript 验收：编译、跨模块运行、TSX 转译及类型错误拒绝；不下载项目依赖。
set -euo pipefail

for tool in node tsc tsx; do
    command -v "$tool" >/dev/null || { printf 'Missing TypeScript tool: %s\n' "$tool" >&2; exit 1; }
done
tsc --version
tsx --version

project="$(mktemp -d)"
trap 'rm -rf -- "$project"' EXIT
mkdir -p "$project/src"
printf '%s\n' '{"type":"module"}' > "$project/package.json"
printf '%s\n' \
    '{"compilerOptions":{"target":"ES2022","module":"NodeNext","strict":true,"rootDir":"src","outDir":"dist"},"include":["src/**/*.ts"]}' \
    > "$project/tsconfig.json"
# enum 需要真正的转译，不能只靠 Node 的类型擦除蒙混过关。
printf '%s\n' 'export enum Answer { Value = 42 }' > "$project/src/answer.ts"
printf '%s\n' \
    'import { Answer } from "./answer.js";' \
    'const answer: number = Answer.Value;' \
    'console.log("typescript:" + answer);' > "$project/src/main.ts"

tsc --project "$project/tsconfig.json"
output="$(node "$project/dist/main.js")"
test "$output" = 'typescript:42'
output="$(tsx --no-cache --tsconfig "$project/tsconfig.json" "$project/src/main.ts")"
test "$output" = 'typescript:42'

# 使用无依赖 JSX factory 验证 .tsx，不把 React 等框架全局塞进镜像。
printf '%s\n' \
    '/** @jsx render */' \
    'const render = (name: string): string => "tsx:" + name;' \
    'console.log(<smoke />);' > "$project/view.tsx"
output="$(tsx --no-cache --tsconfig "$project/tsconfig.json" "$project/view.tsx")"
test "$output" = 'tsx:smoke'

printf '%s\n' 'const invalid: number = "not a number";' > "$project/src/invalid.ts"
if tsc --project "$project/tsconfig.json" --noEmit > "$project/type-error.log" 2>&1; then
    printf 'TypeScript accepted an invalid string-to-number assignment\n' >&2
    exit 1
fi
grep -q 'error TS2322:' "$project/type-error.log"
printf '=== TYPESCRIPT COMPILE, EXECUTION AND TYPE CHECKS PASSED ===\n'
