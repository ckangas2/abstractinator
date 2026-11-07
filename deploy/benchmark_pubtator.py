#!/usr/bin/env python3
"""Benchmark The Abstractinator's virus and bacterium tags against PubTator3.

PubTator3 (NCBI) annotates every PubMed abstract with species, normalised to
NCBI Taxonomy IDs. This script runs a fixed set of searches through the local
API, looks up the PubTator3 annotations for every result that has a PMID, maps
each annotated taxon onto our categories through its NCBI lineage, and writes a
report of where the two agree and disagree.

PubTator3 is itself a model, not ground truth, so the numbers are AGREEMENT,
not accuracy. It has no cell types (only cell lines), so the cell axis is not
covered. Only PubMed records are compared: trials, grants and preprints have no
PMID.

Run on the server, from the repo root (stdlib only, ~15 minutes):
    python3 deploy/benchmark_pubtator.py
Writes benchmark/pubtator.md and benchmark/pubtator_disagreements.csv.
"""
import collections, csv, datetime, json, re, sys, time, urllib.parse, urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

API_PORTS = [8100, 8101, 8102]          # spread over the API processes
PER_QUERY = 40                          # results per search (split across sources)
SEARCH_PAUSE = 4.0                      # seconds between searches: ~15/min, under the 20/min cap
PUBTATOR = "https://www.ncbi.nlm.nih.gov/research/pubtator3-api/publications/export/biocjson"
EUTILS = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
UA = "Abstractinator-benchmark/1.0 (+https://abstractinator.me)"
VIRUSES, BACTERIA = "10239", "2"        # NCBI taxids of the two superkingdoms

QUERIES = [
    # viruses
    "chronic hepatitis B T cell exhaustion", "HIV reservoir latency", "cytomegalovirus NK cells",
    "Epstein-Barr virus B cell lymphoma", "RSV vaccine older adults", "influenza vaccine antibody response",
    "SARS-CoV-2 T cell immunity", "HPV cervical cancer immunotherapy", "Zika dengue cross-reactive antibodies",
    "LCMV chronic infection CD8", "oncolytic adenovirus", "oncolytic herpes simplex virus",
    "vaccinia virus vector vaccine", "oncolytic measles virus", "AAV gene therapy immune response",
    "lentiviral vector CAR-T", "norovirus infection", "rotavirus vaccine", "herpes zoster vaccine",
    "mpox", "Ebola vaccine",
    # bacteria
    "Mycobacterium tuberculosis macrophage", "Salmonella cancer therapy", "Listeria monocytogenes vaccine",
    "Staphylococcus aureus neutrophils", "Helicobacter pylori gastric inflammation",
    "Clostridioides difficile infection", "Akkermansia immunotherapy response",
    # negative controls: acronyms that used to be mis-tagged as viruses
    "Alzheimer's disease AD microglia", "right ventricle RV failure",
]

# Search names for each category's anchor taxa. Resolved by name at run time
# (NCBI keeps old names as synonyms), and printed in the report so a wrong
# match is visible. A taxon maps to the category with the DEEPEST matching
# anchor in its lineage, so HIV beats Lentivirus beats Retrovirus.
VIRUS_ANCHORS = {
    "Adeno-Associated Virus": ["Dependoparvovirus", "adeno-associated virus"],
    "Vesicular Stomatitis Virus": ["vesicular stomatitis virus", "Vesicular stomatitis Indiana virus"],
    "Newcastle Disease Virus": ["Newcastle disease virus"],
    "Seneca Valley Virus": ["Senecavirus A"],
    "Myxoma Virus": ["Myxoma virus"],
    "ECHO-7 virus": ["Echovirus E7"],
    "Maraba Virus": ["Maraba virus"],
    "Semliki Forest virus": ["Semliki Forest virus"],
    "Sindbis virus": ["Sindbis virus"],
    "Venezuelan equine encephalitis virus": ["Venezuelan equine encephalitis virus"],
    "West Nile Virus": ["West Nile virus"],
    "Simian virus 40": ["Simian virus 40"],
    "Rabies Virus": ["rabies virus", "Rabies lyssavirus"],
    "Human Immunodeficiency Virus": ["Human immunodeficiency virus 1", "Human immunodeficiency virus 2"],
    "Herpes Simplex Virus": ["Human alphaherpesvirus 1", "herpes simplex virus 1"],
    "Herpes Simplex Virus 2": ["Human alphaherpesvirus 2", "herpes simplex virus 2"],
    "Vaccinia Virus": ["Vaccinia virus"],
    "Measles Virus": ["Measles morbillivirus", "measles virus"],
    "Lentivirus": ["Lentivirus"],
    "Retrovirus": ["Retroviridae"],
    "Adenovirus": ["Adenoviridae"],
    "Reovirus": ["Orthoreovirus", "Mammalian orthoreovirus"],
    "Poliovirus": ["poliovirus", "Human poliovirus 1"],
    "Coxsackievirus": ["Coxsackievirus A21", "Coxsackievirus B3"],
    "Parvovirus": ["Parvoviridae"],
    "Baculovirus": ["Baculoviridae"],
    "Foamy Virus": ["Spumaretrovirinae"],
    "Alphavirus": ["Alphavirus"],
    "Flavivirus": ["Orthoflavivirus", "Flavivirus"],
    "Polyomavirus": ["Polyomaviridae"],
    "Rhabdovirus": ["Rhabdoviridae"],
    "SARS-CoV-2": ["Severe acute respiratory syndrome coronavirus 2"],
    "Norovirus": ["Norovirus"],
    "Rotavirus": ["Rotavirus"],
    "Sapovirus": ["Sapovirus"],
    "Influenza": ["Influenza A virus", "Influenza B virus"],
    "Hepatitis B Virus": ["Hepatitis B virus"],
    "Hepatitis C Virus": ["Hepatitis C virus"],
    "Cytomegalovirus": ["Human betaherpesvirus 5", "human cytomegalovirus", "Murid betaherpesvirus 1"],
    "Epstein-Barr Virus": ["Human gammaherpesvirus 4", "Epstein-Barr virus"],
    "Varicella-Zoster Virus": ["Human alphaherpesvirus 3", "varicella-zoster virus"],
    "Kaposi's Sarcoma-Associated Herpesvirus": ["Human gammaherpesvirus 8"],
    "Respiratory Syncytial Virus": ["Human orthopneumovirus", "human respiratory syncytial virus"],
    "Human Metapneumovirus": ["Human metapneumovirus"],
    "Human Papillomavirus": ["Papillomaviridae"],
    "MERS-CoV": ["Middle East respiratory syndrome-related coronavirus"],
    "Simian Immunodeficiency Virus": ["Simian immunodeficiency virus"],
    "Lymphocytic Choriomeningitis Virus": ["Lymphocytic choriomeningitis virus", "Mammarenavirus choriomeningitidis"],
    "Dengue Virus": ["Dengue virus"],
    "Zika Virus": ["Zika virus"],
    "Yellow Fever Virus": ["Yellow fever virus"],
    "Chikungunya Virus": ["Chikungunya virus"],
    "Ebola Virus": ["Orthoebolavirus", "Ebolavirus"],
    "Mpox Virus": ["Monkeypox virus"],
    "Enterovirus": ["Enterovirus"],
    "Bacteriophage": [],   # phages span many taxa with no common ancestor below "Viruses"
}
# Bacterial categories are named after their taxon, so the name is the anchor.
BACTERIA_ANCHORS = {
    "Mycobacterium bovis BCG": ["Mycobacterium bovis"],
    "Borrelia burgdorferi": ["Borreliella burgdorferi", "Borrelia burgdorferi"],
}
BACTERIA_CATEGORIES = [
    "Salmonella", "Clostridium", "Listeria", "Bifidobacterium", "Mycobacterium bovis BCG",
    "Escherichia coli", "Lactobacillus", "Lactococcus", "Mycobacterium tuberculosis",
    "Mycobacterium leprae", "Staphylococcus aureus", "Streptococcus pneumoniae",
    "Streptococcus pyogenes", "Pseudomonas aeruginosa", "Klebsiella pneumoniae",
    "Acinetobacter baumannii", "Helicobacter pylori", "Neisseria meningitidis",
    "Neisseria gonorrhoeae", "Chlamydia trachomatis", "Borrelia burgdorferi",
    "Clostridioides difficile", "Enterococcus", "Haemophilus influenzae", "Bacteroides",
    "Fusobacterium", "Akkermansia", "Vibrio cholerae", "Shigella", "Yersinia",
    "Francisella tularensis", "Bacillus anthracis", "Legionella pneumophila",
    "Campylobacter jejuni", "Treponema pallidum",
]
for c in BACTERIA_CATEGORIES:
    BACTERIA_ANCHORS.setdefault(c, [c])


def get(url, params=None, headers=None, timeout=120):
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except Exception as e:
            if attempt == 2:
                raise
            print(f"    retrying after: {e}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))


# --- 1. Our results ---------------------------------------------------------
def run_searches():
    records = {}
    for i, q in enumerate(QUERIES):
        port = API_PORTS[i % len(API_PORTS)]
        print(f"[search {i+1}/{len(QUERIES)}] {q}")
        try:
            body = get(f"http://127.0.0.1:{port}/search",
                       {"q": q, "limit": PER_QUERY, "sources": "papers", "abstract_chars": 0},
                       {"X-Client-Name": "abstractinator-probe-benchmark"}, timeout=240)
            res = json.loads(body).get("results", [])
        except Exception as e:
            print(f"    failed: {e}")
            res = []
        for r in res:
            pmid = str(r.get("pmid") or "").strip()
            if pmid.isdigit() and pmid not in records:
                records[pmid] = {"pmid": pmid, "query": q, "title": r.get("title") or "",
                                 "virus": r.get("primary_virus") or "Non-descript",
                                 "bacterium": r.get("primary_bacteria") or "Non-descript"}
        time.sleep(SEARCH_PAUSE)
    return records


# --- 2. PubTator3 species ---------------------------------------------------
def pubtator_species(pmids):
    """pmid -> list of (taxid, mention text, weight). Title mentions weigh 20,
    abstract mentions 3, the same weighting our own tagger uses."""
    out = collections.defaultdict(list)
    pmids = list(pmids)
    for i in range(0, len(pmids), 100):
        batch = pmids[i:i + 100]
        print(f"[pubtator] {i + len(batch)}/{len(pmids)}")
        data = json.loads(get(PUBTATOR, {"pmids": ",".join(batch)}))
        docs = data.get("PubTator3", data) if isinstance(data, dict) else data
        for doc in docs if isinstance(docs, list) else []:
            pmid = str(doc.get("id") or "")
            for p in doc.get("passages", []):
                ptype = str(p.get("infons", {}).get("type", "")).lower()
                if not pmid:
                    pmid = str(p.get("infons", {}).get("article-id_pmid", ""))
                w = 20 if ptype.startswith("title") else 3
                for a in p.get("annotations", []):
                    inf = a.get("infons", {})
                    if str(inf.get("type", "")).lower() != "species":
                        continue
                    for tid in re.findall(r"\d+", str(inf.get("identifier", ""))):
                        out[pmid].append((tid, a.get("text", ""), w))
        time.sleep(2.5)   # PubTator3 asks for ~30 requests/minute at most
    return out


# --- 3. NCBI Taxonomy -------------------------------------------------------
_lineage = {}   # taxid -> (scientific name, [lineage taxids, root first, self last])

def fetch_lineages(taxids):
    todo = [t for t in dict.fromkeys(taxids) if t not in _lineage]
    for i in range(0, len(todo), 150):
        batch = todo[i:i + 150]
        root = ET.fromstring(get(f"{EUTILS}/efetch.fcgi",
                                 {"db": "taxonomy", "id": ",".join(batch), "tool": "abstractinator-benchmark"}))
        for tx in root.findall("Taxon"):
            tid = tx.findtext("TaxId")
            entry = (tx.findtext("ScientificName"),
                     [t.findtext("TaxId") for t in tx.findall("LineageEx/Taxon")] + [tid])
            _lineage[tid] = entry
            for aka in tx.findall("AkaTaxIds/TaxId"):   # merged IDs
                _lineage[aka.text] = entry
        time.sleep(0.4)


def resolve_anchors(anchor_names, kingdom):
    """category -> list of (taxid, scientific name); unresolved names reported."""
    resolved, unresolved = {}, []
    for cat, names in anchor_names.items():
        ids = []
        for n in names:
            js = json.loads(get(f"{EUTILS}/esearch.fcgi", {"db": "taxonomy", "term": f'"{n}"[All Names]',
                                                           "retmode": "json", "tool": "abstractinator-benchmark"}))
            ids += js.get("esearchresult", {}).get("idlist", [])
            time.sleep(0.4)
        fetch_lineages(ids)
        # Same name in another kingdom (a plant genus called Clostridium, say) is dropped.
        ids = [t for t in dict.fromkeys(ids) if t in _lineage and kingdom in _lineage[t][1]]
        if ids:
            resolved[cat] = [(t, _lineage[t][0]) for t in ids]
        else:
            unresolved.append(cat)
    return resolved, unresolved


def classify(taxid, anchors):
    """Category whose anchor is deepest in this taxon's lineage, or None."""
    if taxid not in _lineage:
        return None
    lin = _lineage[taxid][1]
    best, depth = None, -1
    for cat, pairs in anchors.items():
        for t, _ in pairs:
            if t in lin and lin.index(t) > depth:
                best, depth = cat, lin.index(t)
    return best


# --- 4. Compare and report --------------------------------------------------
def compare(records, species, anchors, kingdom, field):
    rows, gaps, missed = [], collections.Counter(), collections.Counter()
    stats = collections.Counter()
    for pmid, rec in records.items():
        score, gap_score = collections.Counter(), collections.Counter()
        for tid, _text, w in species.get(pmid, []):
            if tid not in _lineage or kingdom not in _lineage[tid][1]:
                continue
            cat = classify(tid, anchors)
            if cat:
                score[cat] += w
            else:
                gap_score[_lineage[tid][0]] += w
        ours = rec[field]
        tagged = ours != "Non-descript"
        pt_top = score.most_common(1)[0][0] if score else None
        stats["compared"] += 1
        if tagged:
            stats["tagged"] += 1
            if ours in score:
                stats["supported"] += 1
                outcome = "agree" if ours == pt_top else "supported (not PubTator's top)"
            elif score or gap_score:
                stats["conflict"] += 1; outcome = "conflict"
            else:
                stats["unsupported"] += 1; outcome = "PubTator found none"
        else:
            if pt_top:
                stats["missed"] += 1; missed[pt_top] += 1; outcome = "missed"
            elif gap_score:
                stats["gap"] += 1; outcome = "no category"
            else:
                stats["both_none"] += 1; outcome = "both none"
        for name in gap_score:
            gaps[name] += 1
        if pt_top:
            stats["pt_top"] += 1
            if ours == pt_top:
                stats["pt_top_matched"] += 1
        if outcome not in ("agree", "both none"):
            rows.append({"axis": field, "outcome": outcome, "pmid": pmid, "ours": ours,
                         "pubtator": "; ".join(f"{c} ({s})" for c, s in score.most_common()) or
                                     "; ".join(f"[{n}] ({s})" for n, s in gap_score.most_common()),
                         "title": rec["title"][:140], "query": rec["query"]})
    return stats, rows, gaps, missed


def pct(a, b):
    return f"{100 * a / b:.0f}%" if b else "n/a"


def main():
    out_dir = Path("benchmark"); out_dir.mkdir(exist_ok=True)
    records = run_searches()
    print(f"{len(records)} unique PubMed records")
    species = pubtator_species(records.keys())
    fetch_lineages({t for v in species.values() for t, _, _ in v})
    v_anchors, v_unres = resolve_anchors(VIRUS_ANCHORS, VIRUSES)
    b_anchors, b_unres = resolve_anchors(BACTERIA_ANCHORS, BACTERIA)

    results = {"Virus": compare(records, species, v_anchors, VIRUSES, "virus"),
               "Bacterium": compare(records, species, b_anchors, BACTERIA, "bacterium")}

    today = datetime.date.today().isoformat()
    L = [f"# Tag agreement with PubTator3 ({today})", "",
         f"{len(QUERIES)} searches, {len(records)} PubMed records. Our `primary_virus` and "
         "`primary_bacteria` are compared with the species PubTator3 annotates in the same "
         "title and abstract, mapped onto our categories through NCBI Taxonomy lineages. "
         "PubTator3 is itself a model, so these are agreement rates, not accuracy. "
         "Cell types are not covered (PubTator3 has none). Generated by "
         "`deploy/benchmark_pubtator.py`.", "",
         "| | Virus | Bacterium |", "|---|---|---|"]
    S = {k: v[0] for k, v in results.items()}
    def row(label, f):
        L.append(f"| {label} | {f(S['Virus'])} | {f(S['Bacterium'])} |")
    row("Records compared", lambda s: s["compared"])
    row("We tagged one", lambda s: s["tagged"])
    row("…and PubTator3 found it too (**tag support**)", lambda s: f"{s['supported']} ({pct(s['supported'], s['tagged'])})")
    row("…PubTator3 found a different one", lambda s: s["conflict"])
    row("…PubTator3 found none of this kind", lambda s: s["unsupported"])
    row("PubTator3's main one is a category we have", lambda s: s["pt_top"])
    row("…and we tagged that same one (**coverage**)", lambda s: f"{s['pt_top_matched']} ({pct(s['pt_top_matched'], s['pt_top'])})")
    row("…we tagged nothing (missed)", lambda s: s["missed"])
    row("PubTator3 found one we have no category for", lambda s: s["gap"])
    L += ["", "**Tag support** is how often a tag we assign is backed by PubTator3. "
          "**Coverage** is how often PubTator3's most-mentioned organism, when we have a "
          "category for it, is also our tag.", ""]

    for axis, (stats, rows, gaps, missed) in results.items():
        L += [f"## {axis}", ""]
        if missed:
            L += ["Most often missed (PubTator3 found it, we tagged nothing):", ""]
            L += [f"- {c}: {n}" for c, n in missed.most_common(10)] + [""]
        if gaps:
            L += ["Organisms PubTator3 found that have no category (candidates for the alias lists):", ""]
            L += [f"- {n}: {c} records" for n, c in gaps.most_common(15)] + [""]
        for outcome in ("conflict", "PubTator found none"):
            ex = [r for r in rows if r["outcome"] == outcome][:12]
            if ex:
                L += [f"Examples, {outcome}:", "", "| PMID | Ours | PubTator3 | Title |", "|---|---|---|---|"]
                L += [f"| [{r['pmid']}](https://pubmed.ncbi.nlm.nih.gov/{r['pmid']}/) | {r['ours']} | "
                      f"{r['pubtator']} | {r['title'].replace('|', '/')} |" for r in ex] + [""]

    L += ["## Category anchors", "",
          "Each category was matched to these NCBI taxa by name. A taxon counts toward the "
          "category whose anchor is deepest in its lineage.", "", "| Category | NCBI taxa |", "|---|---|"]
    for cat, pairs in list(v_anchors.items()) + list(b_anchors.items()):
        L.append(f"| {cat} | " + ", ".join(f"{n} ([{t}](https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id={t}))" for t, n in pairs) + " |")
    if v_unres or b_unres:
        L += ["", "Not resolved (excluded from the comparison): " + ", ".join(v_unres + b_unres)]

    (out_dir / "pubtator.md").write_text("\n".join(L) + "\n")
    with open(out_dir / "pubtator_disagreements.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["axis", "outcome", "pmid", "ours", "pubtator", "title", "query"])
        w.writeheader()
        for _, rows, _, _ in results.values():
            w.writerows(rows)
    print("\n".join(L[:len(L)]) if len(L) < 40 else "\n".join(L[:30]))
    print(f"\nWrote {out_dir/'pubtator.md'} and {out_dir/'pubtator_disagreements.csv'}")


if __name__ == "__main__":
    main()
