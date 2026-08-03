.PHONY: hooks-audit ci-local sync

hooks-audit:
	bash plugin/skill-engine/tests/hooks-audit.sh

# Everything .github/workflows/lint.yml runs, locally. The /release skill's
# Phase 5 runs this same target; scripts/ci-local.sh is the one inventory
# all three consumers share.
ci-local:
	bash scripts/ci-local.sh all

# Propagates the verify.sh template into every stamped copy.
# doctrine.sh check 7 stays the drift detector; this is what fixes what it
# catches instead of a hand copy per contextualizer. Both read the same
# inventory rather than each mirroring the other's find — mirrored globs
# stopped being mirrors the moment a stamped copy appeared outside
# examples/, and this repo's own dogfood contextualizer then sat outside the
# detector and the fix simultaneously.
sync:
	@for f in $$(bash scripts/stamped-verify-copies.sh); do \
		cp plugin/skill-engine/engine-bootstrap-templates/verify.sh "$$f"; \
		echo "synced: $$f"; \
	done
