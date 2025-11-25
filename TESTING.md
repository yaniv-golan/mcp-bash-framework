# Testing Guide

## Linting
Run shell lint/format checks (requires `shellcheck` and `shfmt` on PATH):
```
find . -name '*.sh' -print0 | xargs -0 shellcheck
shfmt -d -i 2 -ci $(find . -name '*.sh')
```

## Smoke Tests
```
./test/examples/test_examples.sh
```

## Unit Tests
```
./test/unit/test_paginate.sh
```

## Integration Tests
```
./test/integration/test_capabilities.sh
./test/integration/test_minimal_mode.sh
```

These commands align with the CI workflow under `.github/workflows/ci.yml`.

Last verified locally: 2025-10-17 using `shellcheck`, `shfmt`, `test/unit/test_paginate.sh`, `test/integration/test_capabilities.sh`, and `test/examples/test_examples.sh`.
