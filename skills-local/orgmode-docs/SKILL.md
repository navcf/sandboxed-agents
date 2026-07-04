---
name: orgmode-docs
description: Author Orgmode documents that export cleanly from Emacs (C-c C-e) to self-contained HTML or GitHub-flavored Markdown for sharing via Slack, email, or GitHub. Use when writing .org files meant for export, or when Org exports show subscripts from underscores, missing images, dropped equations, or broken diagrams.
---

# Orgmode documents that export cleanly from Emacs

This skill **authors the .org file**; the user reviews it in Emacs and
exports it themselves via the export dispatcher:

- `C-c C-e h o` → HTML (ox-html + htmlize): one self-contained file for
  Slack/email — inline highlight CSS, local images (PNG/SVG/JPEG/…)
  embedded as data URIs.
- `C-c C-e g o` → GitHub-flavored Markdown (ox-gfm): pipe tables,
  language-tagged fences, working TOC anchors, `$…$`/`$$…$$` math.

Do NOT write export wrapper scripts — export happens inside Emacs.

## Authoring rules (what the skill must produce)

Start every document with `templates/header.org`. The rules that matter:

1. **`#+OPTIONS: ^:nil` in the header — always.** Without it both exporters
   turn `user_name` into user<sub>name</sub> and `x^2` into a superscript.
   Only omit (or set `^:t`) when subscripts are genuinely wanted.
2. **Wrap code-ish tokens in verbatim**: `~my_func~` or `=CONFIG_PATH=`.
   Mandatory for tokens wrapped in emphasis characters — bare `__init__`
   parses as Org *underline* markup; write `=__init__=`.
3. **Diagrams go in `#+BEGIN_EXAMPLE` blocks.** ASCII and Unicode
   box-drawing survive verbatim in both formats.
4. **Code goes in `#+BEGIN_SRC <lang>`** — htmlize highlights it in HTML;
   ox-gfm emits ```` ```lang ```` fences for GitHub.
5. **Images**: `[[file:diagram.png]]` (+ optional `#+CAPTION:`). HTML
   export embeds them (data URIs, via the config filter below); for
   Markdown, ship the image files alongside the `.md` — GitHub strips
   `data:` URIs in Markdown, embedding is impossible there.
6. **SVG** works as `[[file:icon.svg]]` (embedded in HTML) or as raw
   markup in `#+BEGIN_EXPORT html` (HTML export only).
7. **Entities**: `\alpha`, `\rarr`, `---` (em dash) export correctly in
   both formats (as glyphs or HTML entities, which GitHub decodes).
8. **Math**: `$inline$`, `\[display\]`, and `equation`/`align`/`gather`
   environments all render — GitHub gets `$…$`/`$$…$$` via the config
   filter; HTML uses MathJax. **Caveat**: MathJax loads from a CDN, the
   one external reference — math needs internet to render. Skip math for
   strictly-offline recipients.

## Sharing

- **Slack / email**: attach the exported `.html` — self-contained, opens
  in any browser. Don't paste Markdown into Slack (mrkdwn ≠ GFM).
- **GitHub / GitLab / wikis**: the `.md` plus any linked image files.
  Escaped underscores (`user\_name`) and `<a id>` anchors in the output
  are correct CommonMark and render properly.

## Emacs configuration this relies on (already installed)

- `orgmode-docs.el` (canonical copy in this skill; loaded from
  `~/.config/doom/orgmode-docs.el` via `(load! "orgmode-docs")`):
  - data-URI embedding filter for HTML-derived backends
  - LaTeX display environments → `$$…$$` for Markdown-derived backends
- `(package! ox-gfm)` in Doom `packages.el` (run `doom sync` once).
- htmlize ships with Doom's org module.

## Verifying

Regression harness: `./.auto/measure.sh` (repo root) batch-emulates the
`h o` / `g o` exports over `.auto/fixtures/torture.org` and runs the 47
assertions in `.auto/check_fidelity.py`.
