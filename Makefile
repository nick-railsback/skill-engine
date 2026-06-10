.PHONY: hooks-audit ci-local

hooks-audit:
	bash plugin/skill-engine/tests/hooks-audit.sh

# Everything .github/workflows/lint.yml runs, locally. The /release skill's
# Phase 5 runs this same target; scripts/ci-local.sh is the one inventory
# all three consumers share.
ci-local:
	bash scripts/ci-local.sh all
