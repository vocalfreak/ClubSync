# ADR-0002: Compile Tailwind CSS v4 with the Rails gem

- **Date:** 2026-09-25
- **Status:** Accepted

## Context

Clubsync uses Rails 8, Propshaft, and importmap-rails but had no CSS compiler or local development stylesheet workflow. ProPro provides a proven Tailwind CSS v4 setup using `tailwindcss-rails`, a single CSS entrypoint, and a Foreman-managed Rails server plus Tailwind watcher. The applications are unrelated, so ProPro's theme tokens and component-specific CSS are not appropriate ClubSync assets.

The minimum useful port is the compiler and serving pipeline. Node is not required for core Tailwind v4, and ClubSync does not currently need npm packages or a JavaScript bundler.

## Decision

Clubsync uses `tailwindcss-rails` with Tailwind CSS v4's CSS-first workflow. `app/assets/tailwind/application.css` is the only Tailwind source and begins with `@import "tailwindcss";`. The gem compiles it to `app/assets/builds/tailwind.css`, which Propshaft serves through the `tailwind` logical asset.

`bin/dev` starts Rails and `tailwindcss:watch` through Foreman and `Procfile.dev`. Production image builds run `bin/rails assets:precompile`, which invokes the Tailwind build before Propshaft fingerprints the output.

The setup has no `tailwind.config.js`, PostCSS configuration, JavaScript CSS bundler, or Node package manifest. Tailwind's automatic source scanning is the initial source-discovery mechanism. A future npm-based Tailwind plugin requires a separate decision and corresponding setup.

## Consequences

- Tailwind utilities can be added to ERB or JavaScript without maintaining a content allowlist.
- Generated CSS remains ignored and is reproduced by the watcher or production precompile rather than committed.
- ClubSync keeps its importmap-based JavaScript architecture and avoids a Node runtime solely for core Tailwind.
- Installing an npm-only Tailwind plugin before introducing npm and its install path would silently produce CSS without that plugin's rules.
- Design tokens and component rules will be designed for ClubSync rather than inherited from ProPro.
