#!/usr/bin/env python3
"""Fill the host_taxon column of registry/virus.tsv from NCBI Taxonomy.

Every distinct name in the host column is resolved to an NCBI Taxonomy id and
written into host_taxon in the same order as host.  Nothing else changes.

Each id is checked twice before it is used:
  * esearch for "<name>[Scientific Name]" must return exactly one id, and
  * esummary for that id must come back with the same scientific name, at
    genus or species rank.
Anything else stops the run and prints what NCBI said.

--map FILE reads "name<TAB>taxid" lines instead of asking NCBI.  It exists so
the script can be dry-run in a sandbox that has no route to NCBI; on bigtop it
is not used.
"""

import argparse
import json
import os
import shutil
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime
from xml.etree import ElementTree

EUTILS = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/"
OK_RANKS = ("genus", "species")

HEADER = [
    "axp_id", "role", "virus_family", "virus", "ncbi_taxon", "host",
    "host_taxon", "strain", "replication", "modifications", "transgenes",
    "route", "carrier", "evidence_url",
]
HOST = HEADER.index("host")
HOST_TAXON = HEADER.index("host_taxon")

CHANGELOG_SENTINEL = "resolved from NCBI and checked against the scientific name"

CHANGELOG_ENTRY = """### Added
- Every target bacterium in virus.tsv now carries its NCBI Taxonomy id in
  `host_taxon`, resolved from NCBI and checked against the scientific name and
  rank it comes back with, so phage can be grouped by taxon rather than by the
  spelling of a name.

"""


def stop(message):
    sys.exit("STOP: " + message)


def fetch_bytes(url):
    last = ""
    for attempt in (1, 2, 3):
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                return response.read()
        except Exception as exc:                      # noqa: BLE001
            last = "%s: %s" % (type(exc).__name__, exc)
            if attempt < 3:
                time.sleep(2 * attempt)
    stop("NCBI did not answer %s (%s)" % (url, last))


def fetch(url):
    raw = fetch_bytes(url)
    try:
        return json.loads(raw.decode("utf-8"))
    except ValueError:
        stop("NCBI answered %s with something that is not JSON" % url)


def search(term):
    """Taxonomy ids for a search term, in the order NCBI returns them."""
    found = fetch(EUTILS + "esearch.fcgi?db=taxonomy&retmode=json&term="
                  + urllib.parse.quote(term))
    time.sleep(0.4)
    return found.get("esearchresult", {}).get("idlist", [])


def other_names(taxid):
    """Every name NCBI records for a taxon: the scientific name and all synonyms."""
    raw = fetch_bytes(EUTILS + "efetch.fcgi?db=taxonomy&retmode=xml&id=" + taxid)
    time.sleep(0.4)
    try:
        root = ElementTree.fromstring(raw)
    except ElementTree.ParseError as exc:
        stop("could not read the taxonomy record for %s: %s" % (taxid, exc))
    names = set()
    for taxon in root.iter("Taxon"):
        science = taxon.findtext("ScientificName")
        if science:
            names.add(science.strip())
        for element in taxon.iter():
            if element.tag in ("Synonym", "GenbankSynonym", "EquivalentName",
                               "Anamorph", "Teleomorph", "Misspelling",
                               "Misnomer", "Inpart", "Acronym", "Includes",
                               "CommonName", "GenbankCommonName", "Name"):
                if element.text and element.text.strip():
                    names.add(element.text.strip())
        break                                         # the queried taxon only
    return names


def resolve(name):
    """An NCBI Taxonomy id for a host name, checked against what NCBI calls it.

    A name that is NCBI's current scientific name is taken straight. A name
    NCBI has reclassified -- Mycobacterium abscessus is now Mycobacteroides
    abscessus -- is matched as a synonym instead, and only if the taxonomy
    record itself lists the name we hold. The registry keeps the name the
    trials and papers use; the id points at the taxon.
    """
    ids = search(name + "[Scientific Name]")
    if len(ids) > 1:
        stop("%r is the scientific name of %d taxa (%s); a host name must match one"
             % (name, len(ids), ", ".join(ids)))
    synonym = not ids
    if synonym:
        ids = search(name + "[All Names]")
        if len(ids) != 1:
            stop("%r matched %d taxonomy ids under any name (%s); a host name must "
                 "match exactly one" % (name, len(ids), ", ".join(ids) or "none"))
    taxid = ids[0]

    summary = fetch(EUTILS + "esummary.fcgi?db=taxonomy&retmode=json&id=" + taxid)
    time.sleep(0.4)
    record = summary.get("result", {}).get(taxid, {})
    science = record.get("scientificname", "")
    rank = record.get("rank", "")
    if not science:
        stop("NCBI returned no scientific name for taxid %s (%s)" % (taxid, name))
    if rank not in OK_RANKS:
        stop("taxid %s (%s) has rank %r; expected genus or species" % (taxid, name, rank))
    if science == name:
        return taxid, rank, ""
    if not synonym:
        stop("taxid %s is %r, not %r" % (taxid, science, name))
    known = other_names(taxid)
    if name not in known:
        stop("taxid %s is %r and does not list %r among its names (%s); not using it"
             % (taxid, science, name, "; ".join(sorted(known)) or "none"))
    return taxid, rank, "synonym of " + science


def read_map(path):
    pairs = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            name, taxid = line.rstrip("\n").split("\t")
            pairs[name] = (taxid, "from --map")
    return pairs


def split_hosts(value):
    return [piece.strip() for piece in value.split(";") if piece.strip()]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, help="repository root")
    parser.add_argument("--map", help="offline name<TAB>taxid file, for the dry run")
    parser.add_argument("--backups", default=os.path.expanduser("~/abstractinator-backups"))
    args = parser.parse_args()

    repo = os.path.abspath(args.repo)
    for needed in ("tracker/registry.py", "registry/virus.tsv", "CHANGELOG.md"):
        if not os.path.isfile(os.path.join(repo, needed)):
            stop("%s is not in %s; this is not the repository root" % (needed, repo))

    virus_path = os.path.join(repo, "registry", "virus.tsv")
    with open(virus_path, encoding="utf-8") as handle:
        text = handle.read()
    if "\r" in text:
        stop("virus.tsv has carriage returns; this script expects plain newlines")
    if not text.endswith("\n"):
        stop("virus.tsv does not end with a newline")

    lines = text.split("\n")
    trailing = lines.pop()                            # the empty piece after the last newline
    if trailing != "":
        stop("unexpected bytes after the final newline")
    rows = [line.split("\t") for line in lines]
    if rows[0] != HEADER:
        stop("virus.tsv header is not the schema 4 header:\n  %s" % "\t".join(rows[0]))
    for index, row in enumerate(rows[1:], start=2):
        if len(row) != len(HEADER):
            stop("line %d has %d fields, expected %d" % (index, len(row), len(HEADER)))

    names = []
    for row in rows[1:]:
        for name in split_hosts(row[HOST]):
            if name not in names:
                names.append(name)
    if not names:
        stop("no host names to resolve")

    offline = read_map(args.map) if args.map else None
    print("resolving %d distinct host names" % len(names))
    taxa = {}
    notes = []
    for name in names:
        if offline is not None:
            if name not in offline:
                stop("--map has no id for %r" % name)
            taxid, rank = offline[name]
            note = ""
        else:
            taxid, rank, note = resolve(name)
        if not taxid.isdigit():
            stop("id for %r is not digits: %r" % (name, taxid))
        taxa[name] = taxid
        print("  %-28s %-9s %-8s %s" % (name, taxid, rank, note))
        if note:
            notes.append("%s -> taxid %s, %s" % (name, taxid, note))

    if notes:
        print()
        print("names NCBI has reclassified, matched as synonyms:")
        for line in notes:
            print("  " + line)
        print()

    filled = 0
    kept = 0
    for index, row in enumerate(rows[1:], start=2):
        hosts = split_hosts(row[HOST])
        if not hosts:
            if row[HOST_TAXON].strip():
                stop("line %d has host_taxon %r but no host" % (index, row[HOST_TAXON]))
            continue
        want = "; ".join(taxa[name] for name in hosts)
        have = row[HOST_TAXON].strip()
        if have and have != want:
            stop("line %d (%s) already has host_taxon %r, which is not %r; "
                 "nothing is overwritten" % (index, row[0], have, want))
        if have:
            kept += 1
            continue
        row[HOST_TAXON] = want
        filled += 1

    rows_with_host = sum(1 for row in rows[1:] if split_hosts(row[HOST]))
    if filled + kept != rows_with_host:
        stop("filled %d and kept %d, but %d rows have a host" % (filled, kept, rows_with_host))
    for row in rows[1:]:
        hosts = split_hosts(row[HOST])
        ids = split_hosts(row[HOST_TAXON])
        if len(hosts) != len(ids):
            stop("%s has %d host name(s) and %d id(s)" % (row[0], len(hosts), len(ids)))

    new_text = "\n".join("\t".join(row) for row in rows) + "\n"

    # nothing but host_taxon may differ
    old_rows = [line.split("\t") for line in text.split("\n")[:-1]]
    for old, new in zip(old_rows, rows):
        for column, (before, after) in enumerate(zip(old, new)):
            if column != HOST_TAXON and before != after:
                stop("column %s of %s changed from %r to %r" % (HEADER[column], new[0], before, after))

    os.makedirs(args.backups, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = os.path.join(args.backups, "virus.tsv.bak-" + stamp)
    if os.path.exists(backup):
        stop("%s already exists" % backup)
    shutil.copy2(virus_path, backup)
    print("backup: %s" % backup)

    temporary = virus_path + ".new"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(new_text)
    os.replace(temporary, virus_path)
    print("virus.tsv: %d row(s) given a host_taxon, %d already had one" % (filled, kept))

    changelog_path = os.path.join(repo, "CHANGELOG.md")
    with open(changelog_path, encoding="utf-8") as handle:
        changelog = handle.read()
    marker = "## [Unreleased]\n\n"
    if marker not in changelog:
        stop("CHANGELOG.md has no '## [Unreleased]' heading")
    if CHANGELOG_SENTINEL in changelog:
        print("CHANGELOG: an entry for host_taxon is already there, left alone")
    else:
        changelog = changelog.replace(marker, marker + CHANGELOG_ENTRY, 1)
        with open(changelog_path, "w", encoding="utf-8") as handle:
            handle.write(changelog)
        print("CHANGELOG: entry added under Unreleased")


if __name__ == "__main__":
    main()
