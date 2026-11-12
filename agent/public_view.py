"""
agent/public_view.py
What the public MCP server returns, shaped for a reader rather than for the
database.

The local REST API (agent/api.R) keeps returning everything: every match with
its method, confidence and review status, which is what curation needs. The
public tools return a cleaner view of the same data:

- plain field names, and no empty fields;
- only the strong matches: trials that name the program as an intervention,
  papers its trials cite or that carry its name in the title, grants with its
  name in the title; each with one plain-English `matched_by`;
- no scores, review statuses or unreviewed candidates (they stay local, in the
  review report).

Pure functions with no I/O, so they are tested offline
(tracker/tests/test_public_view.py).
"""

SITE = "https://abstractinator.me/registry/"

PROGRAM_ABOUT = (
    "One therapy program from The Abstractinator registry (CC BY 4.0; credit \"The Abstractinator "
    "program registry\"). Its facts are curated, each with a source. Trials and papers are matched to "
    "the program by name in ClinicalTrials.gov and PubMed; only strong matches are listed here. "
    "Corrections are welcome on the program's page."
)

TRIAL_MATCH = {
    "intervention_name": "named as an intervention",
    "intervention_text": "named within an intervention",
}
PAPER_MATCH = {"title": "named in the title"}       # trial_reference is written per paper
GRANT_MATCH = {"title": "named in the title"}
MAX_PAPERS = 25
MAX_GRANTS = 25
CLINICAL_KINDS = ("clinical_trial", "case_report", "clinical_other")

ROLE = {
    "oncolytic": "oncolytic virus",
    "in_vivo_gene_transfer": "in vivo gene delivery",
    "ex_vivo_gene_transfer": "ex vivo gene delivery (cells modified outside the body)",
    "phage": "phage therapy",
    "vaccine_vector": "vaccine vector",
}
ALIAS_ORDER = {"brand": 0, "inn": 1, "usan": 2, "code": 3, "former_code": 4, "synonym": 5}


def _clean(obj):
    """Drop empty values (None, "", [], {}) from dicts, recursively."""
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            v = _clean(v)
            if v is None or v == "" or v == [] or v == {}:
                continue
            out[k] = v
        return out
    if isinstance(obj, list):
        return [_clean(v) for v in obj]
    return obj


def _human(s):
    return (s or "").replace("_", " ").strip()


def _list(x):
    if x is None or x == "":
        return []
    if isinstance(x, list):
        return [v for v in x if v not in (None, "")]
    return [v.strip() for v in str(x).split(";") if v.strip()]


def _phases(p):
    return [x.replace("EARLY_PHASE1", "Early phase 1").replace("PHASE", "Phase ")
            for x in str(p or "").split("/") if x and x != "NA"]


def _developer(p):
    sponsor, origin = (p.get("sponsor") or "").strip(), (p.get("originator") or "").strip()
    if sponsor and origin and origin.lower() not in sponsor.lower():
        return "%s (originally %s)" % (sponsor, origin)
    return sponsor or origin


def public_trials(trials):
    out = []
    for t in trials or []:
        if t.get("link_status") != "auto" or t.get("link_method") not in TRIAL_MATCH:
            continue
        out.append({
            "nct_id": t.get("nct_id"),
            "url": "https://clinicaltrials.gov/study/%s" % t.get("nct_id"),
            "title": t.get("brief_title"),
            "phase": _phases(t.get("phases")),
            "status": _human(t.get("overall_status")).lower() or None,
            "start": t.get("start_date"),
            "primary_completion": t.get("primary_completion_date"),
            "enrollment": t.get("enrollment_count"),
            "results_posted": True if t.get("has_results") else None,
            "sponsor": t.get("lead_sponsor"),
            "matched_by": TRIAL_MATCH[t["link_method"]],
        })
    out.sort(key=lambda t: t.get("start") or "", reverse=True)
    return out


def public_papers(papers, limit=MAX_PAPERS):
    keep = [p for p in papers or [] if p.get("link_status") == "auto"
            and (p.get("link_method") == "trial_reference" or p.get("link_method") in PAPER_MATCH)]
    keep.sort(key=lambda p: (p.get("link_method") != "trial_reference",
                             p.get("kind") not in CLINICAL_KINDS, -(p.get("year") or 0), str(p.get("pmid"))))
    out = []
    for p in keep[:limit]:
        how = ("cited as results by its trial %s" % p["nct_id"] if p.get("link_method") == "trial_reference"
               and p.get("nct_id") else "cited by its trial" if p.get("link_method") == "trial_reference"
               else PAPER_MATCH[p["link_method"]])
        out.append({
            "pmid": p.get("pmid"),
            "url": "https://pubmed.ncbi.nlm.nih.gov/%s/" % p.get("pmid"),
            "title": p.get("title"),
            "journal": p.get("journal"),
            "year": p.get("year"),
            "type": _human(p.get("kind")) if p.get("kind") and p.get("kind") != "other" else None,
            "matched_by": how,
        })
    return out


def public_grants(grants, limit=MAX_GRANTS):
    keep = [g for g in grants or [] if g.get("link_status") == "auto" and g.get("link_method") in GRANT_MATCH]
    keep.sort(key=lambda g: (-(g.get("last_fy") or 0), str(g.get("core_project_num"))))
    out = []
    for g in keep[:limit]:
        years = "-".join(str(x) for x in (g.get("first_fy"), g.get("last_fy")) if x is not None)
        out.append({
            "project": g.get("core_project_num"),
            "url": g.get("url"),
            "title": g.get("title"),
            "organisation": g.get("org"),
            "investigator": g.get("pi"),
            "years": years,
            "matched_by": GRANT_MATCH[g["link_method"]],
        })
    return out


def public_program(raw):
    """The /program response, as the public sees it."""
    if not isinstance(raw, dict) or raw.get("error"):
        return raw
    p = raw.get("program")
    if not p:                                   # ambiguous name: a list of candidates
        return _clean({
            "registry_release": raw.get("registry_release"),
            "query": raw.get("query"),
            "message": "This name belongs to more than one program. Ask again with one of these IDs.",
            "matches": [{"id": c.get("axp_id"), "name": c.get("preferred_name")}
                        for c in raw.get("candidates") or []],
        })
    axp = p.get("axp_id")
    preferred = p.get("preferred_name") or ""
    aliases = sorted(raw.get("aliases") or [], key=lambda a: (ALIAS_ORDER.get(a.get("alias_type"), 9),
                                                              (a.get("alias") or "").lower()))
    names, name_sources = [], {}
    for a in aliases:
        n = a.get("alias") or ""
        if not n or n.lower() == preferred.lower() or a.get("alias_type") == "preferred":
            continue
        if n not in names:
            names.append(n)
        if a.get("evidence_url") and n not in name_sources:
            name_sources[n] = a["evidence_url"]

    v = raw.get("virus") or None
    virus = None
    if v:
        virus = {
            "role": ROLE.get(v.get("role"), _human(v.get("role"))),
            "family": v.get("virus_family"),
            "virus": v.get("virus"),
            "strain": v.get("strain"),
            "replication": _human(v.get("replication")).replace("non replicating", "non-replicating"),
            "design": v.get("modifications"),
            "transgenes": _list(v.get("transgenes")),
            "route": [_human(r) for r in _list(v.get("route"))],
            "carrier": v.get("carrier"),
            "ncbi_taxon": v.get("ncbi_taxon"),
            "source": v.get("evidence_url"),
        }

    approvals = [{
        "agency": a.get("agency"), "region": a.get("region"), "date": a.get("date"),
        "status": _human(a.get("status")), "brand": a.get("brand"), "indication": a.get("indication"),
        "source": a.get("evidence_url"),
    } for a in raw.get("approvals") or []]

    changes = [{
        "seen": e.get("snapshot_date"), "trial": e.get("nct_id"), "change": _human((e.get("type") or "")
                                                                                   .replace("trial.", "")),
        "significance": e.get("significance"), "before": e.get("before"), "after": e.get("after"),
    } for e in raw.get("recent_changes") or []]

    out = {
        "about": PROGRAM_ABOUT,
        "registry_release": raw.get("registry_release"),
        "id": axp,
        "version": "%s.%s" % (axp, p.get("entry_version")) if p.get("entry_version") else None,
        "page": SITE + "%s.html" % axp if axp else None,
        "redirected_from": raw.get("merged_from"),
        "name": preferred,
        "also_known_as": names,
        "type": p.get("modality"),
        "platform": p.get("platform"),
        "targets": _list(p.get("targets")),
        "developer": _developer(p),
        "status": None if p.get("status") == "active" else p.get("status"),
        "virus": virus,
        "approvals": approvals,
        "trials": public_trials(raw.get("trials")),
        "key_papers": public_papers(raw.get("papers")),
        "grants": public_grants(raw.get("grants")),
        "recent_changes": changes,
        "identifiers": {"ncit": p.get("ncit"), "wikidata": p.get("wikidata"), "unii": p.get("unii")},
        "name_sources": name_sources,
        "notes": p.get("notes"),
    }
    cleaned = _clean(out)
    # Say "none" explicitly where an empty list is itself the answer.
    for k in ("approvals", "trials"):
        cleaned.setdefault(k, [])
    return cleaned


# --- search --------------------------------------------------------------------

UNTAGGED = ("non-descript", "nondescript", "none", "")
SEARCH_DROP = ("merged_from",)


def public_record(r):
    """One search result, without placeholders or fields that don't apply."""
    tags = {}
    for key, name in (("primary_virus", "virus"), ("primary_cell", "cell"),
                      ("primary_bacteria", "bacterium"), ("primary_modality", "therapy")):
        val = r.get(key)
        if val is not None and str(val).strip().lower() not in UNTAGGED:
            tags[name] = val
    if r.get("is_bioinformatics"):
        tags["computational"] = True
    out = {}
    for k, v in r.items():
        if k.startswith("primary_") or k in SEARCH_DROP or k == "is_bioinformatics":
            continue
        if k == "is_retracted":
            if v:
                out["retracted"] = True
            continue
        if k == "is_open_access":
            if v == "Y":
                out["open_access"] = True
            continue
        out[k] = v
    out["tags"] = tags
    return _clean(out)


def public_search(raw):
    if not isinstance(raw, dict) or raw.get("error") or not isinstance(raw.get("results"), list):
        return raw
    out = dict(raw)
    out["results"] = [public_record(r) for r in raw["results"] if isinstance(r, dict)]
    return out
