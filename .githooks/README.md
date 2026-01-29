# Git Hooks

This directory contains git hooks for local development.

## Setup

Option 1 - Configure git to use this directory (recommended):
```bash
git config core.hooksPath .githooks
```

Option 2 - Copy hooks to .git/hooks:
```bash
cp .githooks/* .git/hooks/
chmod +x .git/hooks/*
```

## Available Hooks

### pre-push

Runs before `git push`. Validates:
- Unit tests pass (`./test/unit/run.sh`)
- Bundle validation passes (`mcp-bash bundle --validate`)

To skip in emergencies: `SKIP_PRE_PUSH=1 git push`

## Pre-commit (separate tool)

The project also uses [pre-commit](https://pre-commit.com/) for commit-time checks.
See `.pre-commit-config.yaml` for configuration.

Install: `pre-commit install`
