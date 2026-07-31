.PHONY: hooks-audit ci-local sync

hooks-audit:
	bash plugin/skill-engine/tests/hooks-audit.sh

# Everything .github/workflows/lint.yml runs, locally. The /release skill's
# Phase 5 runs this same target; scripts/ci-local.sh is the one inventory
# all three consumers share.
ci-local:
	bash scripts/ci-local.sh all

# Propagates the verify.sh template into every shipped example.
# doctrine.sh check 7 stays the drift detector; this is what fixes what it
# catches instead of a hand copy per example. Dynamic discovery, not a
# hardcoded list, mirrors check 7's own find so a later-added example is
# covered without editing this target.
sync:
	@for f in $$(find examples -mindepth 2 -maxdepth 2 -name verify.sh); do \
		cp plugin/skill-engine/engine-bootstrap-templates/verify.sh "$$f"; \
		echo "synced: $$f"; \
	done
