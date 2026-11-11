#!/usr/bin/env python3
"""Program registry: alias keys, loading and validation.

Standard library only, so it runs anywhere Python 3.8+ does (bigtop's cron,
CI) with nothing to install. The rules implemented here are written down in
registry/SPEC.md; keep the two in step.

Usage:
    python3 tracker/registry.py validate [REGISTRY_DIR]
    python3 tracker/registry.py next-id [REGISTRY_DIR]
    python3 tracker/registry.py key "MRTX-1133"
"""

import csv
import os
import re
import sys
import unicodedata
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_DIR = os.path.join(REPO, "registry")

PROGRAM_COLUMNS = [
    "axp_id", "status", "replaced_by", "preferred_name", "modality", "platform",
    "targets", "originator", "sponsor", "ncit", "wikidata", "unii",
    "entry_version", "created", "updated", "notes",
]
ALIAS_COLUMNS = [
    "axp_id", "alias", "alias_type", "source", "source_record", "licence",
    "valid_from", "valid_to", "ambiguous", "status", "evidence_url", "added",
]

VIRUS_COLUMNS = [
    "axp_id", "role", "virus_family", "virus", "ncbi_taxon", "strain", "replication",
    "modifications", "transgenes", "route", "carrier", "evidence_url",
]
APPROVAL_COLUMNS = [
    "axp_id", "agency", "region", "date", "status", "brand", "indication", "evidence_url",
]

PROGRAM_STATUSES = {"active", "merged", "obsolete"}
VIRUS_ROLES = {"oncolytic", "in_vivo_gene_transfer", "ex_vivo_gene_transfer", "vaccine_vector", "phage", "other"}
REPLICATION = {"replicating", "conditionally_replicating", "non_replicating"}
ROUTES = {"intratumoral", "intravenous", "intra_arterial", "intravesical", "intraperitoneal", "intrapleural",
          "intracerebral", "intrathecal", "subretinal", "intravitreal", "intramuscular", "subcutaneous",
          "intradermal", "intranasal", "inhaled", "oral", "topical", "ex_vivo"}
AGENCIES = {"FDA", "EMA", "PMDA", "NMPA", "MFDS", "MHRA", "Health Canada", "TGA", "other"}
APPROVAL_STATUSES = {"approved", "conditional", "withdrawn"}
FAMILY_RE = re.compile(r"^[A-Z][a-z]+(viridae|viricetes)$")
ALIAS_TYPES = {"code", "inn", "usan", "brand", "former_code", "former_name", "synonym"}
ALIAS_SOURCES = {"curator", "ncit", "wikidata", "ctgov", "fda", "paper", "press"}
ALIAS_STATUSES = {"accepted", "proposed", "rejected"}
LICENCES = {"CC0-1.0", "public-domain", "CC-BY-4.0"}

ID_RE = re.compile(r"^AXP[0-9]{6}$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
PARTIAL_DATE_RE = re.compile(r"^[0-9]{4}(-[0-9]{2}(-[0-9]{2})?)?$")
NCIT_RE = re.compile(r"^C[0-9]+$")
QID_RE = re.compile(r"^Q[0-9]+$")

# Dropped marks, and a look-alike folded to the letter it stands for: the
# increment sign (U+2206) is often typed for a Greek capital delta, as in
# G47∆, and NFKC does not fold it.
_MARKS = {"®": "", "™": "", "©": "", "\u2206": "\u0394"}


def alias_key(name):
    """The identity key of a name (SPEC section 5).

    NFKC, uppercase, drop (R)/TM/(C), then keep letters and digits only:
    "MRTX-1133", "mrtx 1133" and "MRTX1133" all give "MRTX1133".
    Returns "" for a name with no letters or digits.
    """
    if name is None:
        return ""
    s = str(name)
    # Before NFKC, which would turn the trademark sign into the letters "TM".
    for mark, repl in _MARKS.items():
        s = s.replace(mark, repl)
    s = unicodedata.normalize("NFKC", s).upper()
    return "".join(ch for ch in s if ch.isalnum())


def modality_names(aliases_r=None):
    """Category names of modality_alias_list in aliases.R (the app's therapy axis)."""
    path = aliases_r or os.path.join(REPO, "aliases.R")
    names = []
    inside = False
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("modality_alias_list <- list("):
                inside = True
                continue
            if inside and line.startswith(")"):
                break
            if inside:
                m = re.match(r'^\s{2}"([^"]+)"\s*=\s*c\(', line)
                if m:
                    names.append(m.group(1))
    return names


def read_tsv(path, columns):
    """Rows of a registry TSV as dicts, plus a list of structural errors."""
    errors = []
    rows = []
    name = os.path.basename(path)
    if not os.path.exists(path):
        return rows, ["%s: missing" % name]
    with open(path, encoding="utf-8", newline="") as fh:
        text = fh.read()
    if "\r" in text:
        errors.append("%s: Windows line endings (CR); save with LF only" % name)
        text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    if not lines:
        return rows, ["%s: empty (needs the header row)" % name]
    header = lines[0].split("\t")
    if header != columns:
        errors.append("%s: header should be:\n  %s\nbut is:\n  %s"
                      % (name, "\t".join(columns), "\t".join(header)))
        return rows, errors
    for n, line in enumerate(lines[1:], start=2):
        if not line.strip():
            errors.append("%s line %d: blank line" % (name, n))
            continue
        cells = line.split("\t")
        if len(cells) != len(columns):
            errors.append("%s line %d: %d cells, expected %d (a stray or missing tab?)"
                          % (name, n, len(cells), len(columns)))
            continue
        row = dict(zip(columns, cells))
        row["_line"] = n
        rows.append(row)
    return rows, errors


def read_optional(registry_dir):
    """virus.tsv and approvals.tsv as (rows, errors) each; a missing file is empty."""
    out = []
    for name, cols in (("virus.tsv", VIRUS_COLUMNS), ("approvals.tsv", APPROVAL_COLUMNS)):
        path = os.path.join(registry_dir, name)
        out.append(read_tsv(path, cols) if os.path.exists(path) else ([], []))
    return out


def validate(registry_dir=DEFAULT_DIR, modalities=None):
    """All problems found in the registry, as human-readable strings."""
    if modalities is None:
        modalities = set(modality_names())
    programs, errors = read_tsv(os.path.join(registry_dir, "programs.tsv"), PROGRAM_COLUMNS)
    aliases, alias_errors = read_tsv(os.path.join(registry_dir, "aliases.tsv"), ALIAS_COLUMNS)
    errors += alias_errors

    def err(file, row, msg):
        errors.append("%s line %d (%s): %s" % (file, row["_line"], row.get("axp_id", "?"), msg))

    for rows, file in ((programs, "programs.tsv"), (aliases, "aliases.tsv")):
        for row in rows:
            for col, val in row.items():
                if col == "_line":
                    continue
                if val != val.strip():
                    err(file, row, "%s has leading or trailing spaces" % col)

    # --- programs ---
    by_id = {}
    for row in programs:
        pid = row["axp_id"]
        if not ID_RE.match(pid):
            err("programs.tsv", row, "ID must be AXP followed by 6 digits")
        if pid in by_id:
            err("programs.tsv", row, "duplicate ID (first on line %d)" % by_id[pid]["_line"])
            continue
        by_id[pid] = row
        status = row["status"]
        if status not in PROGRAM_STATUSES:
            err("programs.tsv", row, "status must be one of %s" % sorted(PROGRAM_STATUSES))
        if status == "merged":
            if not row["replaced_by"]:
                err("programs.tsv", row, "merged entries need replaced_by")
        elif row["replaced_by"]:
            err("programs.tsv", row, "replaced_by is only for merged entries")
        if status == "active":
            if not row["preferred_name"]:
                err("programs.tsv", row, "active entries need a preferred_name")
            if row["modality"] not in modalities:
                err("programs.tsv", row, "modality %r is not a category in aliases.R" % row["modality"])
        if not re.match(r"^[1-9][0-9]*$", row["entry_version"]):
            err("programs.tsv", row, "entry_version must be a positive integer")
        for col in ("created", "updated"):
            if not DATE_RE.match(row[col]):
                err("programs.tsv", row, "%s must be YYYY-MM-DD" % col)
        if row["created"] and row["updated"] and row["updated"] < row["created"]:
            err("programs.tsv", row, "updated is before created")
        if row["ncit"] and not NCIT_RE.match(row["ncit"]):
            err("programs.tsv", row, "ncit should look like C123456")
        if row["wikidata"] and not QID_RE.match(row["wikidata"]):
            err("programs.tsv", row, "wikidata should look like Q12345")

    for row in programs:
        if row["status"] == "merged" and row["replaced_by"]:
            target = by_id.get(row["replaced_by"])
            if target is None:
                err("programs.tsv", row, "replaced_by %s does not exist" % row["replaced_by"])
            elif target["status"] != "active":
                err("programs.tsv", row, "replaced_by %s is not active (point at the final survivor)"
                    % row["replaced_by"])

    # IDs are assigned in order with no gaps, so a typo'd ID stands out.
    ids = sorted(int(p[3:]) for p in by_id if ID_RE.match(p))
    if ids and ids != list(range(1, len(ids) + 1)):
        missing = sorted(set(range(1, ids[-1] + 1)) - set(ids))[:5]
        errors.append("programs.tsv: IDs should run AXP000001 upward with no gaps; missing %s"
                      % ", ".join("AXP%06d" % i for i in missing))

    # --- aliases ---
    for row in aliases:
        pid = row["axp_id"]
        prog = by_id.get(pid)
        if prog is None:
            err("aliases.tsv", row, "no such program")
        elif prog["status"] != "active":
            err("aliases.tsv", row, "program is %s; move its aliases to the active entry" % prog["status"])
        if not row["alias"]:
            err("aliases.tsv", row, "alias is empty")
        elif not alias_key(row["alias"]):
            err("aliases.tsv", row, "alias %r has no letters or digits" % row["alias"])
        for col, allowed in (("alias_type", ALIAS_TYPES), ("source", ALIAS_SOURCES),
                             ("status", ALIAS_STATUSES), ("licence", LICENCES)):
            if row[col] not in allowed:
                err("aliases.tsv", row, "%s %r must be one of %s" % (col, row[col], sorted(allowed)))
        if row["ambiguous"] not in ("0", "1"):
            err("aliases.tsv", row, "ambiguous must be 0 or 1")
        for col in ("valid_from", "valid_to"):
            if row[col] and not PARTIAL_DATE_RE.match(row[col]):
                err("aliases.tsv", row, "%s must be YYYY, YYYY-MM or YYYY-MM-DD" % col)
        if not DATE_RE.match(row["added"]):
            err("aliases.tsv", row, "added must be YYYY-MM-DD")
        if row["status"] == "accepted" and not (row["evidence_url"] or row["source_record"]):
            err("aliases.tsv", row, "accepted aliases need an evidence_url or source_record")

    # --- virus.tsv and approvals.tsv ---
    viruses, approvals = read_optional(registry_dir)
    errors += viruses[1] + approvals[1]
    viruses, approvals = viruses[0], approvals[0]
    for file, rows in (("virus.tsv", viruses), ("approvals.tsv", approvals)):
        for row in rows:
            for col, val in row.items():
                if col != "_line" and val != val.strip():
                    err(file, row, "%s has leading or trailing spaces" % col)
            prog = by_id.get(row["axp_id"])
            if prog is None:
                err(file, row, "no such program")
            elif prog["status"] != "active":
                err(file, row, "program is %s; use the active entry" % prog["status"])
            if not row["evidence_url"].startswith(("http://", "https://")):
                err(file, row, "evidence_url must be a link")
    seen_virus = {}
    for row in viruses:
        if row["axp_id"] in seen_virus:
            err("virus.tsv", row, "second row for this program (first on line %d)" % seen_virus[row["axp_id"]])
        seen_virus.setdefault(row["axp_id"], row["_line"])
        if row["role"] not in VIRUS_ROLES:
            err("virus.tsv", row, "role %r must be one of %s" % (row["role"], sorted(VIRUS_ROLES)))
        if not FAMILY_RE.match(row["virus_family"]):
            err("virus.tsv", row, "virus_family %r should be an ICTV family (...viridae) or class (...viricetes)"
                % row["virus_family"])
        if not row["virus"]:
            err("virus.tsv", row, "virus is empty")
        if row["ncbi_taxon"] and not row["ncbi_taxon"].isdigit():
            err("virus.tsv", row, "ncbi_taxon must be digits")
        if row["replication"] and row["replication"] not in REPLICATION:
            err("virus.tsv", row, "replication must be one of %s" % sorted(REPLICATION))
        routes = [r.strip() for r in row["route"].split(";") if r.strip()] if row["route"] else []
        bad = [r for r in routes if r not in ROUTES]
        if bad:
            err("virus.tsv", row, "unknown route %s (allowed: %s)" % (", ".join(bad), ", ".join(sorted(ROUTES))))
    for row in approvals:
        if row["agency"] not in AGENCIES:
            err("approvals.tsv", row, "agency %r must be one of %s" % (row["agency"], sorted(AGENCIES)))
        if not re.match(r"^[A-Z]{2}$", row["region"]):
            err("approvals.tsv", row, "region must be a two-letter code, e.g. US, EU, JP, CN")
        if not PARTIAL_DATE_RE.match(row["date"]):
            err("approvals.tsv", row, "date must be YYYY, YYYY-MM or YYYY-MM-DD")
        if row["status"] not in APPROVAL_STATUSES:
            err("approvals.tsv", row, "status must be one of %s" % sorted(APPROVAL_STATUSES))
        if not row["indication"]:
            err("approvals.tsv", row, "indication is empty")

    # --- name collisions (SPEC section 5) ---
    # Every active program's preferred name counts as an accepted, unambiguous alias.
    names = []  # (key, axp_id, ambiguous, where)
    for row in programs:
        if row["status"] == "active" and row["preferred_name"]:
            names.append((alias_key(row["preferred_name"]), row["axp_id"], False,
                          "programs.tsv line %d" % row["_line"], True))
    for row in aliases:
        if row["status"] == "accepted" and alias_key(row["alias"]):
            names.append((alias_key(row["alias"]), row["axp_id"], row["ambiguous"] == "1",
                          "aliases.tsv line %d" % row["_line"], False))
    seen = defaultdict(list)
    for key, pid, amb, where, is_pref in names:
        seen[key].append((pid, amb, where, is_pref))
    for key, hits in sorted(seen.items()):
        listed = [h for h in hits if not h[3]]
        same = defaultdict(list)
        for h in listed:
            same[h[0]].append(h[2])
        for pid, wheres in same.items():
            if len(wheres) > 1:
                errors.append("%s: name key %s listed more than once for %s (%s)"
                              % ("aliases.tsv", key, pid, ", ".join(wheres)))
        # At most one program may hold a key unambiguously.
        clear_progs = {h[0] for h in hits if not h[1]}
        if len(clear_progs) > 1:
            errors.append("name key %s belongs to %s; if it really names more than one product, "
                          "mark the alias rows ambiguous=1 (%s)"
                          % (key, ", ".join(sorted(clear_progs)), ", ".join(h[2] for h in hits)))
    return errors


def next_id(registry_dir=DEFAULT_DIR):
    programs, _ = read_tsv(os.path.join(registry_dir, "programs.tsv"), PROGRAM_COLUMNS)
    nums = [int(r["axp_id"][3:]) for r in programs if ID_RE.match(r["axp_id"])]
    return "AXP%06d" % (max(nums) + 1 if nums else 1)


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if len(argv) >= 2 else 2
    cmd = argv[1]
    if cmd == "key":
        for name in argv[2:]:
            print("%s\t%s" % (name, alias_key(name)))
        return 0
    registry_dir = argv[2] if len(argv) > 2 else DEFAULT_DIR
    if cmd == "validate":
        problems = validate(registry_dir)
        programs, _ = read_tsv(os.path.join(registry_dir, "programs.tsv"), PROGRAM_COLUMNS)
        aliases, _ = read_tsv(os.path.join(registry_dir, "aliases.tsv"), ALIAS_COLUMNS)
        if problems:
            for p in problems:
                print("ERROR " + p)
            print("%d problem(s)" % len(problems))
            return 1
        print("registry OK: %d programs, %d aliases" % (len(programs), len(aliases)))
        return 0
    if cmd == "next-id":
        print(next_id(registry_dir))
        return 0
    print("unknown command %r" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
