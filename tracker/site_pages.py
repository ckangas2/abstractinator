#!/usr/bin/env python3
"""Static website pages for the program registry (abstractinator.me/registry/).

Reads data/registry/registry.sqlite (read-only; layout in REGISTRY_DB.md) and
writes plain HTML into www/registry/, which Shiny serves as static files:

  index.html                    what the registry is, counts, every program
                                grouped by virus family (viruses) or modality
  AXP000001.html, ...           one page per ID: names, virus, cross-references,
                                approvals, trials, changes, papers, grants, how
                                to cite. Merged and retired IDs get a short page
                                pointing on, so a once-valid ID never 404s.
  disease/<slug>.html           programs with trials in one disease
                                (DISEASE_VIEWS), e.g. pancreatic cancer

Every link is relative, so the pages work under any URL prefix. The site is
built in a temporary directory next to the output and swapped in whole, so
readers never see a half-written site.

Standard library only (Python 3.8+). Usually run by build_registry.py (--site);
by hand: python3 tracker/site_pages.py [--db FILE] [--out DIR]
"""

import argparse
import html
import json
import os
import shutil
import sqlite3
import sys
from urllib.parse import quote

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import build_registry as br  # noqa: E402  (shared CSS tokens and change labels)
import atlas_page  # noqa: E402  (the atlases: atlas.html, atlas-phage.html)

DEFAULT_DB = os.path.join(REPO, "data", "registry", "registry.sqlite")
DEFAULT_SITE = os.path.join(REPO, "www", "registry")

GITHUB_REGISTRY = "https://github.com/ckangas2/abstractinator/tree/main/registry"
ISSUE_URL = "https://github.com/ckangas2/abstractinator/issues/new?title="
SITE_URL = "https://abstractinator.me/registry/"

# Disease views: (slug, label, lower-case fragments matched in a trial's
# conditions or title). Add a row to publish another view.
DISEASE_VIEWS = [
    ("pancreatic-cancer", "Pancreatic cancer", ["pancrea"]),
]

ROLE_ORDER = ["oncolytic", "in_vivo_gene_transfer", "ex_vivo_gene_transfer", "vaccine_vector", "phage", "other"]
ROLE_LABEL = {"oncolytic": "Oncolytic", "in_vivo_gene_transfer": "In vivo gene transfer",
              "ex_vivo_gene_transfer": "Ex vivo gene transfer", "vaccine_vector": "Vaccine vector",
              "phage": "Phage", "other": "Other"}
ALIAS_TYPE_LABEL = {"preferred": "preferred name", "inn": "INN", "usan": "USAN", "brand": "brand",
                    "code": "code", "former_code": "former code", "former_name": "former name",
                    "synonym": "synonym"}
# Which names to show first as "also known as".
ALIAS_PRIORITY = {"brand": 0, "inn": 1, "usan": 2, "code": 3, "synonym": 4, "former_code": 5, "former_name": 6}
LINK_METHOD_LABEL = {"intervention_name": "intervention named", "intervention_text": "name in intervention",
                     "title": "name in title", "trial_reference": "cited by trial", "abstract": "name in abstract",
                     "terms": "name in project terms"}
PHASE_RANK = {"EARLY_PHASE1": 0.5, "PHASE1": 1, "PHASE2": 2, "PHASE3": 3, "PHASE4": 4}
MAX_CHANGES = 50

SITE_CSS = br.PAGE_CSS + """
main{max-width:980px}h1{line-height:1.25}h2{border-bottom:1px solid var(--line);padding-bottom:4px}
.crumb{font-size:.88rem;color:var(--muted);margin:0 0 18px}.crumb a{text-decoration:none}
.lead{font-size:1.02rem;max-width:760px}.id{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.88em}
.tw{overflow-x:auto;-webkit-overflow-scrolling:touch;margin:8px 0 16px}.tw table{min-width:600px}
th{font-weight:600;white-space:nowrap}td.nw{white-space:nowrap}caption{text-align:left;font-weight:600;padding:6px 0}
.box{border:1px solid var(--line);border-radius:8px;padding:10px 16px;margin:8px 0 16px}
dl.kv{display:grid;grid-template-columns:max-content 1fr;gap:4px 18px;margin:6px 0}dl.kv dt{color:var(--muted)}dl.kv dd{margin:0}
.flag{display:inline-block;border:1px solid var(--accent);color:var(--accent);border-radius:4px;padding:0 5px;font-size:.78em}
h4 .muted{font-weight:400}#filter{margin:16px 0}.stats{display:flex;flex-wrap:wrap;gap:8px 22px;margin:12px 0}.stats b{font-size:1.25rem;display:block}
details{margin:10px 0}summary{cursor:pointer;color:var(--accent)}
input[type=search]{width:100%;max-width:440px;padding:8px 10px;font:inherit;color:var(--fg);background:var(--bg);
border:1px solid var(--line);border-radius:6px}
blockquote{margin:6px 0;padding:8px 12px;background:var(--chip);border-radius:6px}
@media (max-width:600px){dl.kv{grid-template-columns:1fr;gap:0}dl.kv dd{margin-bottom:8px}}
"""

FILTER_JS = """
(function(){var b=document.getElementById('filter');if(!b)return;b.hidden=false;
var q=b.querySelector('input'),n=document.getElementById('filter-count');
q.addEventListener('input',function(){var t=q.value.trim().toLowerCase(),shown=0;
document.querySelectorAll('tr[data-s]').forEach(function(r){var ok=!t||r.getAttribute('data-s').indexOf(t)>=0;
r.hidden=!ok;if(ok)shown++;});
document.querySelectorAll('[data-group]').forEach(function(g){g.hidden=!g.querySelector('tr[data-s]:not([hidden])');});
n.textContent=t?shown+' shown':'';});})();
"""

esc = html.escape


# --- small formatting helpers --------------------------------------------------

def safe_url(u):
    """A URL from the data, only if it is http(s) (never javascript: and friends)."""
    u = (u or "").strip()
    return u if u.lower().startswith(("https://", "http://")) else ""


def link(href, text, ext=False):
    if not href:
        return esc(text)
    rel = ' rel="noopener"' if ext else ""
    return '<a href="%s"%s>%s</a>' % (esc(href), rel, esc(text))


def nct_link(nct):
    return link("https://clinicaltrials.gov/study/%s" % quote(nct or ""), nct or "", True)


def split_list(s):
    return [x.strip() for x in (s or "").split(";") if x.strip()]


def plural(n, word):
    return "%d %s%s" % (n, word, "" if n == 1 else "s")


def slug(s):
    return "".join(c if c.isalnum() else "-" for c in (s or "").lower()).strip("-")


def human(s):
    """ACTIVE_NOT_RECRUITING -> Active not recruiting; conditionally_replicating -> conditionally replicating."""
    s = (s or "").replace("_", " ").strip()
    return s[:1].upper() + s[1:].lower() if s.isupper() else s


def phase_label(phases):
    """'PHASE1/PHASE2' -> 'Phase 1/2'; 'EARLY_PHASE1' -> 'Early phase 1'; '' or NA -> ''."""
    parts = [p for p in (phases or "").split("/") if p in PHASE_RANK]
    if not parts:
        return ""
    if parts == ["EARLY_PHASE1"]:
        return "Early phase 1"
    return "Phase " + "/".join(p.replace("EARLY_PHASE", "early ").replace("PHASE", "") for p in parts)


def phase_rank(phases):
    ranks = [PHASE_RANK[p] for p in (phases or "").split("/") if p in PHASE_RANK]
    return (max(ranks), min(ranks)) if ranks else (0, 0)


def conditions_of(t):
    try:
        v = json.loads(t.get("conditions") or "[]")
        return [str(c) for c in v] if isinstance(v, list) else []
    except ValueError:
        return []


def matches_disease(t, terms):
    hay = [c.lower() for c in conditions_of(t)] + [(t.get("brief_title") or "").lower()]
    return any(term in h for term in terms for h in hay)


def by_start_desc(trials):
    return sorted(trials, key=lambda t: (t.get("start_date") or "", t.get("nct_id") or ""), reverse=True)


def approval_summary(apps):
    live = [a for a in apps if a["status"] in ("approved", "conditional")]
    agencies = []
    for a in sorted(live, key=lambda a: a["date"] or ""):
        if a["agency"] not in agencies:
            agencies.append(a["agency"])
    if agencies:
        return "yes (%s)" % ", ".join(agencies)
    if apps:
        return "withdrawn"
    return ""


# --- reading the database ------------------------------------------------------

def _rows(con, sql, args=()):
    cur = con.execute(sql, args)
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def load(db_path):
    """Everything the pages need, as plain dicts (one read-only connection)."""
    con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
    try:
        tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        get = lambda t, sql, args=(): _rows(con, sql, args) if t in tables else []
        d = {"meta": dict(con.execute("SELECT key, value FROM meta"))}
        d["programs"] = {p["axp_id"]: p for p in _rows(con, "SELECT * FROM program ORDER BY axp_id")}
        d["aliases"] = group(get("alias", "SELECT * FROM alias ORDER BY axp_id, alias"))
        d["virus"] = {v["axp_id"]: v for v in get("virus", "SELECT * FROM virus")}
        d["approvals"] = group(get("approval", "SELECT * FROM approval ORDER BY axp_id, date"))
        d["trials"] = group(get("trial_link",
            "SELECT l.axp_id, l.nct_id, l.method, l.matched, l.confidence, l.status AS link_status, "
            "t.brief_title, t.overall_status, t.phases, t.start_date, t.primary_completion_date, "
            "t.enrollment_count, t.has_results, %s AS conditions "
            "FROM trial_link l LEFT JOIN trial t ON t.nct_id = l.nct_id"
            % ("t.conditions" if "conditions" in table_columns(con, "trial") else "NULL")))
        events = get("change_event",
                     "SELECT e.*, t.brief_title FROM change_event e LEFT JOIN trial t ON t.nct_id = e.nct_id "
                     "ORDER BY e.snapshot_date DESC, e.significance, e.nct_id, e.type")
        d["changes"] = {}
        for e in events:
            try:
                axps = json.loads(e["axp_ids"] or "[]")
            except ValueError:
                axps = []
            for a in axps:
                d["changes"].setdefault(a, []).append(e)
        d["papers"] = group(get("paper_link",
            "SELECT l.*, p.title, p.journal, p.year, p.kind, p.pmid AS have_paper "
            "FROM paper_link l LEFT JOIN paper p ON p.pmid = l.pmid" if "paper" in tables else
            "SELECT l.*, NULL AS title, NULL AS journal, NULL AS year, NULL AS kind, NULL AS have_paper "
            "FROM paper_link l"))
        d["grants"] = group(get("grant_link",
            "SELECT l.*, g.title, g.org, g.pi, g.first_fy, g.last_fy, g.url "
            "FROM grant_link l LEFT JOIN grant_award g ON g.core_project_num = l.core_project_num"
            if "grant_award" in tables else
            "SELECT l.*, NULL AS title, NULL AS org, NULL AS pi, NULL AS first_fy, NULL AS last_fy, "
            "NULL AS url FROM grant_link l"))
    finally:
        con.close()
    return d


def table_columns(con, table):
    return {r[1] for r in con.execute("PRAGMA table_info(%s)" % table)}


def group(rows, key="axp_id"):
    out = {}
    for r in rows:
        out.setdefault(r[key], []).append(r)
    return out


def auto_trials(d, axp):
    return [t for t in d["trials"].get(axp, []) if t["link_status"] == "auto"]


def key_names(d, p, n=3):
    """A few other names for a program: brand, INN, codes first; no ambiguous ones."""
    seen = {next((a["alias_key"] for a in d["aliases"].get(p["axp_id"], []) if a["alias_type"] == "preferred"), "")}
    out = []
    for a in sorted(d["aliases"].get(p["axp_id"], []),
                    key=lambda a: (ALIAS_PRIORITY.get(a["alias_type"], 9), a["alias"].lower())):
        if a["alias_type"] == "preferred" or a["ambiguous"] or a["alias_key"] in seen:
            continue
        if a["alias"].strip().lower() == (p["preferred_name"] or "").strip().lower():
            continue
        seen.add(a["alias_key"])
        out.append(a["alias"])
        if len(out) == n:
            break
    return out


def grouped(d, axp_ids):
    """[(heading, [(subheading, [program])])]: viruses by family then role, then
    everything else by modality."""
    virus_groups, other_groups = {}, {}
    for axp in axp_ids:
        p = d["programs"][axp]
        v = d["virus"].get(axp)
        if v:
            fam = v["virus_family"] or "Family not recorded"
            virus_groups.setdefault(fam, {}).setdefault(v["role"] or "other", []).append(p)
        else:
            other_groups.setdefault(p["modality"] or "Other", []).append(p)
    name = lambda p: (p["preferred_name"] or "").lower()
    out = []
    for fam in sorted(virus_groups):
        roles = virus_groups[fam]
        subs = [(ROLE_LABEL.get(r, human(r)), sorted(roles[r], key=name))
                for r in sorted(roles, key=lambda r: (ROLE_ORDER.index(r) if r in ROLE_ORDER else 99, r))]
        out.append(("virus", fam, subs))
    for mod in sorted(other_groups):
        out.append(("other", mod, [("", sorted(other_groups[mod], key=name))]))
    return out


# --- page frame ------------------------------------------------------------------

def frame(title, body, meta, root, crumbs=()):
    """A whole page. root is the relative path to the registry index's folder
    ('' or '../'); crumbs are (href or None, text) after 'Registry'."""
    trail = ['<a href="%s../">The Abstractinator</a>' % root, '<a href="%sindex.html">Registry</a>' % root]
    trail += [link(h, t) if h else esc(t) for h, t in crumbs]
    foot = ("Registry release %s. The registry is licensed under "
            '<a href="%s" rel="noopener">CC BY 4.0</a>: reuse it freely, with credit to the Abstractinator. '
            'Source: ClinicalTrials.gov; not endorsed by NLM. '
            '<a href="%s../changes.html">What changed this week</a> · <a href="%s../">The Abstractinator</a>'
            % (esc(meta.get("registry_release", "")), "https://creativecommons.org/licenses/by/4.0/", root, root))
    return ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            "<title>%s · Program registry · The Abstractinator</title><style>%s</style></head><body><main>"
            '<nav class="crumb" aria-label="Breadcrumb">%s</nav>\n%s\n<footer>%s</footer></main></body></html>\n'
            % (esc(title), SITE_CSS, " › ".join(trail), "\n".join(body), foot))


def table(headers, rows, cls=""):
    """rows are lists of ready HTML cells; headers plain text ('#' prefix = numeric)."""
    th = "".join('<th class=num>%s</th>' % esc(h[1:]) if h.startswith("#") else "<th>%s</th>" % esc(h)
                 for h in headers)
    return '<div class="tw"><table%s><tr>%s</tr>%s</table></div>' % (
        ' class="%s"' % cls if cls else "", th, "".join(rows))


def kv(pairs):
    items = ["<dt>%s</dt><dd>%s</dd>" % (esc(k), v) for k, v in pairs if v]
    return '<dl class="kv">%s</dl>' % "".join(items) if items else ""


# --- index -----------------------------------------------------------------------

def program_row(d, p, virus_cols):
    axp = p["axp_id"]
    autos = auto_trials(d, axp)
    best = max(autos, key=lambda t: phase_rank(t["phases"]), default=None)
    names = key_names(d, p)
    every = [p["preferred_name"], axp] + [a["alias"] for a in d["aliases"].get(axp, [])]
    v = d["virus"].get(axp) or {}
    every += [v.get("virus_family", ""), v.get("virus", ""), v.get("strain", ""), p["modality"], p["targets"],
              p["platform"]]
    cells = ['<td>%s</td>' % link("%s.html" % axp, p["preferred_name"]),
             '<td class="id nw">%s</td>' % esc(axp),
             "<td>%s</td>" % esc(", ".join(names))]
    if virus_cols:
        strain = " · ".join(x for x in (v.get("virus", ""), v.get("strain", "")) if x)
        cells += ["<td>%s</td>" % esc(strain), "<td>%s</td>" % esc(human(v.get("replication", "")))]
    else:
        cells.append("<td>%s</td>" % esc(" · ".join(x for x in (p["platform"], p["targets"]) if x)))
    cells += ["<td class=nw>%s</td>" % esc(phase_label(best["phases"]) if best else ""),
              "<td>%s</td>" % esc(approval_summary(d["approvals"].get(axp, []))),
              "<td class=num>%d</td>" % len(autos)]
    return '<tr data-s="%s">%s</tr>' % (esc(" ".join(x for x in every if x).lower()), "".join(cells))


def program_tables(d, groups, heading="h2"):
    out = []
    sub = "h3" if heading == "h2" else "h4"
    for kind, title, subs in groups:
        n = sum(len(ps) for _, ps in subs)
        out.append('<section data-group id="%s"><%s>%s <span class="muted">(%d)</span></%s>'
                   % (esc(slug(title)), heading, esc(title), n, heading))
        virus_cols = kind == "virus"
        headers = (["Program", "ID", "Also known as"]
                   + (["Virus · strain", "Replication"] if virus_cols else ["Platform · targets"])
                   + ["Highest phase", "Approved", "#Trials"])
        for label, ps in subs:
            out.append('<div data-group>')
            if label:
                out.append("<%s>%s</%s>" % (sub, esc(label), sub))
            out.append(table(headers, [program_row(d, p, virus_cols) for p in ps]))
            out.append("</div>")
        out.append("</section>")
    return out


def index_page(d):
    meta = d["meta"]
    active = [a for a, p in d["programs"].items() if p["status"] == "active"]
    n_virus = sum(1 for a in active if a in d["virus"])
    n_names = sum(len(d["aliases"].get(a, [])) for a in active)
    trials = {t["nct_id"] for a in active for t in auto_trials(d, a)}
    n_approved = sum(1 for a in active if approval_summary(d["approvals"].get(a, [])).startswith("yes"))
    body = ["<h1>Program registry</h1>",
            '<p class="lead">An open registry of therapeutic viruses and other investigational therapies, '
            "licensed under CC BY 4.0. Each program has a stable ID (AXP000001) and lists every "
            "name it has gone by, its virus and construct where it is virus-based, its regulatory approvals, "
            "the ClinicalTrials.gov trials that name it, and what changed in them week by week.</p>",
            '<p>The curated data and its rules live in the '
            '<a href="%s" rel="noopener">registry folder on GitHub</a>; '
            'this week\'s trial changes are in <a href="../changes.html">What changed</a>.</p>' % GITHUB_REGISTRY,
            '<div class="stats">%s</div>' % "".join(
                "<div><b>%d</b>%s</div>" % (n, esc(t)) for n, t in (
                    (len(active), "programs"), (n_virus, "therapeutic viruses"), (n_names, "names"),
                    (len(trials), "linked trials"), (n_approved, "approved programs"))),
            '<p class="muted">Trials as of the ClinicalTrials.gov snapshot of %s. Phase and trial counts use '
            "confirmed (automatic) links only.</p>" % esc(meta.get("latest_snapshot") or "(none yet)")]
    body.append('<h2>Explore</h2><p><a href="atlas.html">Oncolytic virus atlas</a>: every oncolytic virus as a '
                "map, joined to its virus family, transgenes, the cancers its trials enrol and more. "
                '<a href="atlas-phage.html">Phage therapy atlas</a>: the same map for phage therapies, '
                "joined to the infections their trials enrol.</p>")
    body.append("<h2>By disease</h2><ul>%s</ul>" % "".join(
        '<li><a href="disease/%s.html">%s</a></li>' % (esc(slug), esc(label)) for slug, label, _ in DISEASE_VIEWS))
    body.append('<div id="filter" hidden><label for="q">Filter programs</label><br>'
                '<input id="q" type="search" placeholder="name, code, virus, target..." autocomplete="off"> '
                '<span id="filter-count" class="muted"></span></div>')
    groups = grouped(d, active)
    body.append('<p class="muted">Jump to: %s</p>' % " · ".join(
        '<a href="#%s">%s</a>' % (esc(slug(title)), esc(title)) for _, title, _ in groups))
    body += program_tables(d, groups)
    body.append("<script>%s</script>" % FILTER_JS)
    return frame("Programs", body, meta, "")


# --- program pages ---------------------------------------------------------------

def trial_rows(trials, with_method=False):
    rows = []
    for t in trials:
        conds = conditions_of(t)
        cells = [nct_link(t["nct_id"]), esc(t.get("brief_title") or ""), esc(human(t.get("overall_status") or "")),
                 esc(phase_label(t.get("phases"))), esc(t.get("start_date") or ""),
                 esc(t.get("primary_completion_date") or ""),
                 "" if t.get("enrollment_count") is None else esc(str(t["enrollment_count"])),
                 esc("; ".join(conds))]
        if with_method:
            cells.append("%s: %s" % (esc(LINK_METHOD_LABEL.get(t["method"], t["method"])), esc(t.get("matched") or "")))
        rows.append("<tr>%s</tr>" % "".join(
            "<td%s>%s</td>" % (" class=num" if i == 6 else " class=nw" if i in (0, 3, 4, 5) else "", c)
            for i, c in enumerate(cells)))
    return rows


TRIAL_HEADERS = ["Trial", "Title", "Status", "Phase", "Start", "Primary completion", "#Enrolment", "Conditions"]


CLINICAL_KINDS = ("clinical_trial", "case_report", "clinical_other")
MAX_OTHER_PAPERS = 100


def is_clinical(p):
    """A clinical paper: tagged clinical by PubMed, or a results paper a linked trial cites."""
    return p.get("kind") in CLINICAL_KINDS or p.get("method") == "trial_reference"


def paper_rows(papers):
    rows = []
    for p in papers:
        pm = link("https://pubmed.ncbi.nlm.nih.gov/%s/" % quote(p["pmid"]), "PMID " + p["pmid"], True)
        how = esc(LINK_METHOD_LABEL.get(p["method"], p["method"]))
        if p.get("nct_id"):
            how += " " + nct_link(p["nct_id"])
        elif p.get("matched"):
            how += ": " + esc(p["matched"])
        rows.append("<tr><td class=nw>%s</td><td>%s</td><td>%s</td><td class=nw>%s</td><td>%s</td></tr>" % (
            pm, esc(p.get("title") or ""), esc(p.get("journal") or ""),
            esc("" if p.get("year") is None else str(p["year"])), how))
    return rows


def grant_rows(grants):
    rows = []
    for g in grants:
        num = g["core_project_num"]
        url = safe_url(g.get("url")) or "https://reporter.nih.gov/project-details/%s" % quote(num)
        fy = "–".join(str(x) for x in (g.get("first_fy"), g.get("last_fy")) if x is not None)
        how = "%s: %s" % (esc(LINK_METHOD_LABEL.get(g["method"], g["method"])), esc(g.get("matched") or ""))
        rows.append("<tr><td class=nw>%s</td><td>%s</td><td>%s</td><td>%s</td><td class=nw>%s</td><td>%s</td></tr>" % (
            link(url, num, True), esc(g.get("title") or ""), esc(g.get("org") or ""), esc(g.get("pi") or ""),
            esc(fy), how))
    return rows


def auto_then_candidates(items, rows_fn, headers, what):
    auto = [x for x in items if x["status"] == "auto"]
    cand = [x for x in items if x["status"] != "auto"]
    out = []
    if auto:
        out.append(table(headers, rows_fn(auto)))
    else:
        out.append('<p class="muted">No confirmed %s yet.</p>' % what)
    if cand:
        out.append("<details><summary>Unconfirmed matches (%d)</summary>"
                   '<p class="muted">Found by a weaker match (an ambiguous or short name, or a name only in the '
                   "abstract); not counted. Corrections welcome.</p>%s</details>" % (len(cand), table(headers, rows_fn(cand))))
    return out


def program_page(d, p):
    meta, axp = d["meta"], p["axp_id"]
    vid = "%s.%s" % (axp, p["entry_version"])
    body = ["<h1>%s</h1>" % esc(p["preferred_name"]),
            '<p><span class="id">%s</span> · %s</p>' % (esc(vid), esc(p["modality"] or ""))]
    body.append(kv([("Platform", esc(p["platform"] or "")), ("Targets", esc(p["targets"] or "")),
                    ("Originator", esc(p["originator"] or "")), ("Sponsor", esc(p["sponsor"] or ""))]))

    names = sorted(d["aliases"].get(axp, []),
                   key=lambda a: (a["alias_type"] != "preferred", ALIAS_PRIORITY.get(a["alias_type"], 9),
                                  a["alias"].lower()))
    body.append("<h2>Names</h2>")
    spellings = []   # one row per spelling: the preferred name is often also the INN
    for a in names:
        same = next((m for m in spellings if m[0]["alias"] == a["alias"]), None)
        if same:
            same.append(a)
        else:
            spellings.append([a])
    rows = []
    for spelling in spellings:
        a = spelling[0]
        flag = ' <span class="flag" title="This name also means something else; it never links a document '\
               'on its own">ambiguous</span>' if any(x["ambiguous"] for x in spelling) else ""
        types = ", ".join(ALIAS_TYPE_LABEL.get(x["alias_type"], x["alias_type"] or "") for x in spelling)
        srcs = []
        for x in spelling:
            ev = safe_url(x["evidence_url"])
            src = link(ev, x["source"] or "source", True) if ev else esc(x["source"] or "")
            if src and src not in srcs:
                srcs.append(src)
        rows.append("<tr><td>%s%s</td><td>%s</td><td>%s</td></tr>" % (esc(a["alias"]), flag, esc(types), ", ".join(srcs)))
    body.append(table(["Name", "Type", "Source"], rows))

    v = d["virus"].get(axp)
    if v:
        taxon = v["ncbi_taxon"]
        taxon_html = link("https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=%s" % quote(taxon),
                          "NCBI Taxonomy %s" % taxon, True) if taxon else ""
        virus_html = esc(v["virus"] or "") + (" (%s)" % taxon_html if taxon_html else "")
        ev = safe_url(v["evidence_url"])
        body.append("<h2>Virus</h2>")
        body.append('<div class="box">%s</div>' % kv([
            ("Role", esc(ROLE_LABEL.get(v["role"], human(v["role"] or "")))),
            ("Family", "<i>%s</i>" % esc(v["virus_family"]) if v["virus_family"] else ""),
            ("Virus", virus_html), ("Strain", esc(v["strain"] or "")),
            ("Replication", esc(human(v["replication"] or ""))),
            ("Modifications", esc(v["modifications"] or "")),
            ("Transgenes", esc(", ".join(split_list(v["transgenes"])))),
            ("Route", esc(", ".join(human(r) for r in split_list(v["route"])))),
            ("Carrier", esc(v["carrier"] or "")),
            ("Source", link(ev, "evidence", True) if ev else "")]))

    xrefs = []
    if p["ncit"]:
        xrefs.append(("NCI Thesaurus", link("https://evsexplore.semantics.cancer.gov/evsexplore/concept/ncit/%s"
                                            % quote(p["ncit"]), p["ncit"], True)))
    if p["wikidata"]:
        xrefs.append(("Wikidata", link("https://www.wikidata.org/wiki/%s" % quote(p["wikidata"]), p["wikidata"], True)))
    if p["unii"]:
        xrefs.append(("FDA UNII", link("https://precision.fda.gov/uniisearch/srs/unii/%s" % quote(p["unii"]),
                                       p["unii"], True)))
    if xrefs:
        body.append("<h2>Cross-references</h2>" + kv(xrefs))

    apps = d["approvals"].get(axp, [])
    body.append("<h2>Approvals</h2>")
    if apps:
        body.append(table(["Agency", "Region", "Date", "Status", "Brand", "Indication", "Source"], [
            "<tr><td>%s</td><td>%s</td><td class=nw>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>" % (
                esc(a["agency"] or ""), esc(a["region"] or ""), esc(a["date"] or ""), esc(human(a["status"] or "")),
                esc(a["brand"] or ""), esc(a["indication"] or ""),
                link(safe_url(a["evidence_url"]), "source", True) if safe_url(a["evidence_url"]) else "")
            for a in apps]))
    else:
        body.append('<p class="muted">No regulatory approval recorded.</p>')

    trials = d["trials"].get(axp, [])
    auto = by_start_desc([t for t in trials if t["link_status"] == "auto"])
    cand = by_start_desc([t for t in trials if t["link_status"] != "auto"])
    body.append("<h2>Clinical trials <span class=\"muted\">(%d)</span></h2>" % len(auto))
    if auto:
        body.append(table(TRIAL_HEADERS, trial_rows(auto)))
    else:
        body.append('<p class="muted">No trial in the latest ClinicalTrials.gov snapshot names this program.</p>')
    if cand:
        body.append("<details><summary>Unconfirmed matches (%d)</summary>"
                    '<p class="muted">Trials that mention one of the names in a weaker way (a code only in the '
                    "title, a short or ambiguous name). Not counted above.</p>%s</details>"
                    % (len(cand), table(TRIAL_HEADERS + ["Matched by"], trial_rows(cand, with_method=True))))

    changes = d["changes"].get(axp, [])[:MAX_CHANGES]
    body.append("<h2>Recent changes</h2>")
    if changes:
        rows = []
        for e in changes:
            change = "" if e["type"] in ("trial.results_posted", "trial.new", "trial.dropped") else \
                "%s → %s" % (esc(e["before"] or "–"), esc(e["after"] or "–"))
            rows.append("<tr><td class=nw>%s</td><td class=nw>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>" % (
                esc(e["snapshot_date"]), nct_link(e["nct_id"]),
                '<span class="chip">%s</span>' % esc(br.TYPE_LABEL.get(e["type"], e["type"])),
                change, esc(e.get("brief_title") or "")))
        body.append(table(["Seen", "Trial", "Change", "Detail", "Title"], rows))
    else:
        body.append('<p class="muted">No changes recorded in its trials yet.</p>')

    papers = sorted(d["papers"].get(axp, []), key=lambda x: (-(x.get("year") or 0), x["pmid"]))
    if papers:
        heads = ["PubMed", "Title", "Journal", "Year", "Linked by"]
        clinical = [x for x in papers if is_clinical(x)]
        other = [x for x in papers if not is_clinical(x)]
        body.append("<h2>Clinical papers</h2>")
        body += auto_then_candidates(clinical, paper_rows, heads, "clinical papers")
        if other:
            body.append("<h2>Other papers</h2>")
            body.append('<p class="muted">Preclinical studies, reviews and other papers that name it'
                        "%s.</p>" % (", newest %d shown" % MAX_OTHER_PAPERS if len(other) > MAX_OTHER_PAPERS else ""))
            body += auto_then_candidates(other[:MAX_OTHER_PAPERS], paper_rows, heads, "other papers")
    grants = sorted(d["grants"].get(axp, []), key=lambda x: (-(x.get("last_fy") or 0), x["core_project_num"]))
    if grants:
        body.append("<h2>NIH grants</h2>")
        body += auto_then_candidates(grants, grant_rows, ["Project", "Title", "Organisation", "PI", "Years",
                                                          "Linked by"], "grants")
    if p["notes"]:
        body.append("<h2>Notes</h2><p>%s</p>" % esc(p["notes"]))

    release = meta.get("registry_release", "")
    body.append("<h2>How to cite</h2><blockquote>%s (%s). The Abstractinator program registry, release %s. "
                "%s%s.html</blockquote>" % (esc(p["preferred_name"]), esc(vid), esc(release), SITE_URL, esc(axp)))
    body.append('<p>Something wrong or missing? <a href="%s" rel="noopener">Suggest a correction</a> '
                "(a GitHub issue; please link your evidence). Entry created %s, updated %s.</p>"
                % (esc(ISSUE_URL + quote("Registry correction: %s" % axp, safe="")), esc(p["created"] or ""),
                   esc(p["updated"] or "")))
    return frame("%s (%s)" % (p["preferred_name"], axp), body, meta, "", [(None, axp)])


def retired_page(d, p):
    axp = p["axp_id"]
    body = ["<h1>%s</h1>" % esc(axp)]
    if p["status"] == "merged" and p["replaced_by"] in d["programs"]:
        s = d["programs"][p["replaced_by"]]
        body.append("<p>%s (%s) was merged into %s: the two IDs turned out to be one product. "
                    'Use <a href="%s.html">%s (%s)</a>; its page lists every name.</p>'
                    % (esc(axp), esc(p["preferred_name"] or ""), esc(s["axp_id"]), esc(s["axp_id"]),
                       esc(s["preferred_name"] or ""), esc(s["axp_id"])))
    else:
        body.append("<p>%s (%s) was retired from the registry: it was entered in error or is not a "
                    'program. The ID is never reused. <a href="index.html">All programs</a>.</p>'
                    % (esc(axp), esc(p["preferred_name"] or "")))
    if p["notes"]:
        body.append("<p>%s</p>" % esc(p["notes"]))
    return frame(axp, body, d["meta"], "", [(None, axp)])


# --- disease views -----------------------------------------------------------------

def disease_page(d, slug, label, terms):
    meta = d["meta"]
    hits = {}
    for axp, p in d["programs"].items():
        if p["status"] != "active":
            continue
        ts = [t for t in auto_trials(d, axp) if matches_disease(t, terms)]
        if ts:
            hits[axp] = by_start_desc(ts)
    n_trials = len({t["nct_id"] for ts in hits.values() for t in ts})
    body = ["<h1>%s</h1>" % esc(label),
            '<p class="lead">Programs in the registry with at least one linked ClinicalTrials.gov trial in %s '
            "(the trial's conditions or title mention it): %s, %s. Only confirmed (automatic) "
            "trial links are counted; each program's page has the rest.</p>"
            % (esc(label.lower()), plural(len(hits), "program"), plural(n_trials, "trial"))]
    if not hits:
        body.append('<p class="muted">No linked trials yet.</p>')
    for kind, title, subs in grouped(d, sorted(hits)):
        body.append("<h2>%s</h2>" % esc(title))
        for sublabel, ps in subs:
            if sublabel:
                body.append("<h3>%s</h3>" % esc(sublabel))
            for p in ps:
                names = key_names(d, p)
                body.append('<h4><a href="../%s.html">%s</a> <span class="id muted">%s</span>%s</h4>' % (
                    esc(p["axp_id"]), esc(p["preferred_name"]), esc(p["axp_id"]),
                    ' <span class="muted">· %s</span>' % esc(", ".join(names)) if names else ""))
                body.append(table(["Trial", "Title", "Phase", "Status", "Start"], [
                    "<tr><td class=nw>%s</td><td>%s</td><td class=nw>%s</td><td>%s</td><td class=nw>%s</td></tr>" % (
                        nct_link(t["nct_id"]), esc(t.get("brief_title") or ""), esc(phase_label(t.get("phases"))),
                        esc(human(t.get("overall_status") or "")), esc(t.get("start_date") or ""))
                    for t in hits[p["axp_id"]]]))
    return frame(label, body, meta, "../", [(None, label)])


# --- writing -----------------------------------------------------------------------

def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def write_site(db_path, out_dir=DEFAULT_SITE, log=print):
    """Write the registry's pages into out_dir, replacing what was there in one swap."""
    d = load(db_path)
    out_dir = os.path.abspath(out_dir).rstrip(os.sep)
    tmp, old = out_dir + ".tmp", out_dir + ".old"
    for leftover in (tmp, old):
        if os.path.isdir(leftover):
            shutil.rmtree(leftover)
    try:
        os.makedirs(tmp)
        _write(os.path.join(tmp, "index.html"), index_page(d))
        n = 0
        for axp, p in d["programs"].items():
            page = program_page(d, p) if p["status"] == "active" else retired_page(d, p)
            _write(os.path.join(tmp, "%s.html" % axp), page)
            n += 1
        for slug, label, terms in DISEASE_VIEWS:
            _write(os.path.join(tmp, "disease", "%s.html" % slug), disease_page(d, slug, label, terms))
        for f in atlas_page.FIELDS:
            _write(os.path.join(tmp, f["page"]), atlas_page.atlas_page(d, esc, frame, FILTER_JS, table, f["key"]))
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    if os.path.exists(out_dir):
        os.rename(out_dir, old)
    os.rename(tmp, out_dir)
    shutil.rmtree(old, ignore_errors=True)
    log("wrote %s: index, %d program pages, %d disease views, atlases" % (out_dir, n, len(DISEASE_VIEWS)))
    return out_dir


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--out", default=DEFAULT_SITE)
    args = ap.parse_args(argv)
    write_site(args.db, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
