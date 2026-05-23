# oliverbrose.github.io

Source for the personal website at <https://oliverbrose.github.io>.

The site is built with [Quarto](https://quarto.org) and deployed to GitHub Pages. Articles are pulled from the separate content repository at <https://github.com/UnbiasedEstimation/content>, filtered by a `publish-to-website: true` frontmatter flag.

## Local development

Requirements:

- [Quarto CLI](https://quarto.org/docs/get-started/) (≥ 1.4)
- Python 3 (for the sync script's frontmatter parsing)
- Git access to `UnbiasedEstimation/content` (read access — the sync script clones it)

Workflow:

```bash
# 1. Pull all articles flagged `publish-to-website: true` from the content repo
./scripts/sync-content.sh

# 2. Render the site to _site/
quarto render

# 3. Preview locally (auto-reloads on changes to .qmd files)
quarto preview

# 4. Deploy to GitHub Pages (pushes to the gh-pages branch)
quarto publish gh-pages
```

The `_content/` directory is gitignored and populated only by the sync script. To re-sync after flipping `publish-to-website` on an article in the content repo, just run `./scripts/sync-content.sh` again.

## Repo layout

```
.
├── _quarto.yml                  Site-wide config (theme, navbar, etc.)
├── index.qmd                    Home page (bio + recent posts)
├── blog.qmd                     Blog listing (posts + long-form articles)
├── papers.qmd                   Papers listing (research papers)
├── cv.qmd                       CV page (text + link to cv.pdf)
├── cv.pdf                       Downloadable CV (generated from content repo's cv/ LaTeX)
├── styles.css                   Site-wide CSS tweaks
├── scripts/
│   └── sync-content.sh          Filter + copy from UnbiasedEstimation/content
├── _content/                    Synced articles (gitignored)
├── _content_src/                Source clone of content repo (gitignored)
├── _site/                       Built site output (gitignored)
└── .github/workflows/           CI (deferred — currently empty placeholder)
```

## Navigation

Top nav: **Home / Blog / Papers / CV** + GitHub and LinkedIn icons on the right. Matches the style of an academic personal site (e.g., kylebutts.com).

## Curation

To put an article on the site, edit its frontmatter in the `UnbiasedEstimation/content` repo and add:

```yaml
publish-to-website: true
```

To remove an article from the site, either delete that line or set it to `false`. Re-run the sync + render + publish cycle.

The site only includes articles with the flag set to `true`. Drafts, ideas, and `status: published` LinkedIn pieces are all opt-in independently.

## Deferred / TODO

- GitHub Actions workflow for automated rebuilds on push to either repo.
- Cross-repo `repository_dispatch` so content-repo pushes auto-trigger site rebuilds.
- Custom domain (e.g., `oliverbrose.com`) — DNS + CNAME.
- CV PDF integration (render `cv/` from the content repo on every build).
- Light/dark theme toggle.
