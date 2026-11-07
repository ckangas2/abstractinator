# Tool reference

Read this when you need an exact parameter. The workflow and judgement are in
SKILL.md.

## search_literature

    search_literature(query, max_results=25, abstract_chars=1500, deep=false,
                      offset=0, sources="")

| parameter | meaning |
|---|---|
| `query` | Concept terms. Not boolean syntax. |
| `max_results` | 1-100. Split evenly across the sources that have hits. |
| `abstract_chars` | Truncate abstracts; `0` omits them. |
| `deep` | Fetch up to 250 records per database instead of 50. 20-60s. |
| `offset` | Skip this many records, to page. Ordering is deterministic. |
| `sources` | Comma-separated: `papers` (Europe PMC + OpenAlex), `grants` (NIH + NSF), `preprints`, `trials`, or exact source names. |

Response fields: `total_found` (whole deduplicated pool), `available` (what is
pageable after a `sources` filter), `returned`, `offset`, `has_more`,
`source_counts`, `results`.

Page against `available` or `has_more`. `total_found` does not shrink under a
`sources` filter, so paging against it overruns.

Each record: `title`, `abstract`, `authors`, `publication_date`, `doi`, `url`,
`source`, `primary_cell`, `primary_virus`, `primary_bacteria`,
`is_bioinformatics`, and for open-access Europe PMC articles, `pmcid` and
`is_open_access`. Records without an abstract are kept and listed last.

## get_fulltext

    get_fulltext(pmcid, doi, max_chars=20000)

Open-access articles from Europe PMC only. Prefer `pmcid` from a search
result; `doi` costs one extra lookup.

- `max_chars`: minimum 500, maximum 100000. A truncated response ends with a
  `[truncated]` marker, so `chars` can exceed `max_chars` by 13.
- The whole article is cached server-side, so reading more later costs
  nothing. Start small.
- `status: "not_open_access"` means follow the DOI by hand.

## Limits

Shared across every user of the service: about 20 searches per minute, and a
separate bucket for full text. A 429 means wait about a minute -- retrying in
a loop only takes capacity from everyone else. A fresh search takes 5-10
seconds; a repeat within 7 days is instant.

## Coverage

Europe PMC (including PubMed), OpenAlex, ClinicalTrials.gov, bioRxiv and
medRxiv (about 590,000 preprints, refreshed daily), NIH RePORTER, NSF Awards.
Free, no account, MIT licensed: https://github.com/ckangas2/abstractinator
