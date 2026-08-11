# CI

GitHub Actions 워크플로 원본: [github-actions.yml](./github-actions.yml)

저장소 기본 브랜치에 적용하려면 (PAT에 `workflow` scope 필요):

```bash
mkdir -p .github/workflows
cp docs/ci/github-actions.yml .github/workflows/ci.yml
git add .github/workflows/ci.yml
git commit -m "ci: enable GitHub Actions for synthetic unit tests"
git push
```

로컬 스모크는 저장소 루트에서:

```bash
./scripts/smoke.sh
```
