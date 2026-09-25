# ADR-0001: Event tag values are verbatim display labels

- **Date:** 2026-09-25
- **Status:** Accepted

## Context

The extraction phase grows a topical, non-exclusive `EventTags` axis alongside the closed `Categories` enum. Categories are internal enum keys: lowercase snake_case descriptive strings (`club_and_society_registration_week`) that feed the category→`is_event` mapping, precedence rules, and the CSRW guard — pure code, never shown verbatim to users.

Event tags are the opposite: informational labels the future public-site filter shows to visitors verbatim. The maintainer's settled list is 37 values whose meaningful differences are presentation-level ("Interest/Affinity" vs "interest_affinity", "Residential Colleges" vs "residential_colleges"). Normalizing them to snake_case would force a second display-mapping layer with no payoff — the values are already exactly what a filter UI wants to render.

## Decision

`EventTags::ALL` stores the maintainer's labels **verbatim** (Title Case, spaces and slashes intact, e.g. `"Academic"`, `"Interest/Affinity"`, `"Social/Recreational"`). The same literal strings are the response-schema enum the extraction LLM picks from, and the exact values persisted in `events.tags`. There is no value normalization anywhere: schema enum, stored rows, and future site filter all share the one constant.

## Consequences

- The model anchors on human display labels directly; a tag is never rewritten after extraction.
- A data migration plus a prompt `VERSION` bump would be needed to re-case values later — this is why the choice is a recorded ADR rather than an unwritten convention.
- Normalization would be reintroduced only if a tag is ever *referenced* internally by name (no such use exists today — nothing control-flows on a tag).
- Out-of-list model output is dropped leniently by `ExtractionParser` (`map_tags`), not treated as a parse failure — consistent with tags being a filter-UI convenience, never a business gate.