# Program registry: specification

Version 0.1 (2026-11-11). The registry gives each investigational therapy a
stable, citable ID and lists every name it has gone by, so that grants,
preprints, papers and trials that use different names can be linked to the
same thing. The tracker's tools (`tracker/`) validate it and build on it.

## 1. What a program is

A **program** is one investigational product: one molecule or one construct,
followed through every sponsor, licence deal and rename it has.

- One program per product, not per indication: pembrolizumab in melanoma and
  in lung cancer is one program.
- Combination regimens are not programs. A trial of MRTX1133 with
  cetuximab links to two programs.
- A changed construct is a new program: an oncolytic adenovirus with a new
  transgene, a CAR with a different binder, costimulatory domain or cell
  source (autologous vs allogeneic). So is the same construct made by a
  different manufacturing process when the product has its own INN
  (brexucabtagene autoleucel vs axicabtagene ciloleucel). A new formulation
  or route of the same molecule is not.
- A platform (a virus backbone, a CAR scaffold) is recorded in `platform`,
  not as a program of its own.
- An approved product keeps its program: approval is a stage, not a new entity.
- Generic research tools, drug classes ("KRAS inhibitors") and targets are
  not programs.

When in doubt, prefer one program and record the doubt in `notes`; a later
split is cheap (section 3).

## 2. IDs

- Format `AXP` + 6 digits, e.g. `AXP000042`. Assigned in order, never reused,
  and carry no meaning: the number says nothing about modality or date.
- A version suffix pins an entry as it stood at a release: `AXP000042.3` is
  version 3. `entry_version` increases by one whenever a curated field of
  the program or one of its aliases changes.
- Cite as the release (its DOI, once releases are deposited) plus the
  versioned ID.

## 3. Merges, splits and retirement

- **Merge** (two IDs turn out to be one product): the lower ID survives. The
  other gets `status = merged` and `replaced_by = <survivor>`, and its aliases
  move to the survivor. Merged IDs keep resolving, so old citations still
  work.
- **Split** (one ID was two products): the original ID stays on the product
  that keeps the most-used name; the other product gets a new ID. The split
  is recorded in both entries' `notes`.
- **Retire** (entered in error, not a program): `status = obsolete`, with the
  reason in `notes`. The row stays; the ID is never reused.

Rows are never deleted from `programs.tsv`.

## 4. Files

All files are UTF-8, tab-separated, one header row, no quoting. Empty means
unknown. Multiple values in one cell are separated by `; `.

### programs.tsv

| column | meaning |
|---|---|
| `axp_id` | the ID |
| `status` | `active`, `merged` or `obsolete` |
| `replaced_by` | the surviving ID, for merged entries only |
| `preferred_name` | INN if there is one, else the most-used code or name |
| `modality` | one category from the Abstractinator's therapy list (`modality_alias_list` in `aliases.R`) |
| `platform` | e.g. `adenovirus (Ad5/3)`, `HSV-1`, `autologous CAR-T`, `small molecule` |
| `targets` | gene symbols (HGNC), e.g. `KRAS`, `CD19` |
| `originator` | the organisation that first developed it |
| `sponsor` | the current lead developer |
| `ncit` | NCI Thesaurus code, e.g. `C123456` |
| `wikidata` | Wikidata QID, e.g. `Q12345` |
| `unii` | FDA UNII |
| `entry_version` | integer, starts at 1 |
| `created` | date the ID was assigned (YYYY-MM-DD) |
| `updated` | date of the last change |
| `notes` | free text: doubts, splits, merges, retirement reasons |

### aliases.tsv

Every name a program has gone by. The preferred name counts as an alias
whether or not it is listed.

| column | meaning |
|---|---|
| `axp_id` | the program (must be active) |
| `alias` | the name as written in its source |
| `alias_type` | `code` (development code), `inn`, `usan`, `brand`, `former_code`, `former_name`, `synonym` |
| `source` | `curator`, `ncit`, `wikidata`, `ctgov`, `fda`, `paper`, `press` |
| `source_record` | where exactly: an NCT number, a PMID, an NCIt code, a URL |
| `licence` | licence of the row, see section 6 |
| `valid_from`, `valid_to` | for codes that changed hands or were renamed (YYYY, YYYY-MM or YYYY-MM-DD) |
| `ambiguous` | `1` if the name also means something else (another program, a gene, a common word); an ambiguous alias never links a document on its own |
| `status` | `accepted`, `proposed` (awaiting review) or `rejected` (kept so it isn't proposed again) |
| `evidence_url` | link showing the name refers to this program |
| `added` | date added |

## 5. Matching names

Names are compared by a **key**: ®, ™ and © removed, the increment sign ∆
read as the Greek letter Δ, then Unicode NFKC, uppercased, then every
character that is not a letter or digit removed.
`MRTX-1133`, `MRTX 1133` and `mrtx1133` share the key `MRTX1133`;
`Pexa-Vec` and `PexaVec` share `PEXAVEC`.

- At most one program may hold a key without `ambiguous = 1` (preferred
  names count as unambiguous). If a name genuinely refers to two products,
  the alias rows are marked `ambiguous = 1`.
- A program must not list the same key twice.
- The test cases in `tracker/tests/alias_keys.tsv` define the key; every
  implementation (the Python tools now, the R app later) must pass them.

Linking text to programs (which alias appears where, with what confidence) is
defined separately with the linking methods; the key is only for identity.

## 6. Licences

The registry is dedicated to the public domain under CC0 1.0 (see `LICENSE`)
except for rows whose `licence` says otherwise.

Allowed `licence` values:
- `CC0-1.0`: our own curation, Wikidata, OpenAlex.
- `public-domain`: US government works (ClinicalTrials.gov registrations,
  NIH RePORTER, NSF, FDA).
- `CC-BY-4.0`: NCI Thesaurus. Credited in `README.md`.

Not allowed in this directory: share-alike licences (ChEMBL, Guide to
Pharmacology, DrugCentral) and non-commercial ones (DrugBank beyond its CC0
subset, WHO ICTRP). Those may be used to check our work, never copied here.
Abstracts are never copied into the registry.

## 7. Changes and review

Corrections arrive as GitHub issues or pull requests. Every change passes the
validator (`python3 tracker/registry.py validate`) in CI. A curator reviews
each proposed alias against its evidence before setting it to `accepted`;
automated tools only ever add `proposed` rows.
