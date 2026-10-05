---
title: 'The Abstractinator: parallel, deduplicated literature retrieval for immunology and virology, for researchers and AI agents'
tags:
  - R
  - Shiny
  - immunology
  - virology
  - literature search
  - bibliometrics
  - Model Context Protocol
authors:
  - name: Chase Kangas
    orcid: 0000-0003-1668-6468
    affiliation: 1
affiliations:
  # JOSS accepts "Independent Researcher, Country" when there is no institution.
  - name: Independent Researcher, United States   # TODO: replace if affiliated
    index: 1
date: 4 October 2026   # TODO: update at submission
bibliography: paper.bib
---

# Summary

Keeping up with research means searching many separate databases: journal articles, preprints, clinical trials and grant awards all live in different places, each with its own search syntax. The same paper often appears in several of them, so a thorough search produces long, repetitive lists that must be merged by hand. The Abstractinator is open-source software that turns this into a single search. It queries six biomedical sources at once (Europe PMC, OpenAlex, ClinicalTrials.gov, bioRxiv/medRxiv, NIH RePORTER and NSF Awards), merges duplicate records, and labels each result with the immune cell type, virus and bacterium it is most strongly about. Because those labels come from editable vocabularies rather than a fixed schema, the same results can be viewed through different lenses: a plot of immune cells against viruses can be switched to immune cells against bacteria without re-running the search. Results can be browsed and filtered in a web application, charted over time, and exported to reference managers. The same search engine is also available to AI assistants through the Model Context Protocol (MCP), so a language model can retrieve and cite real literature instead of answering from memory. A public instance runs at [abstractinator.me](https://abstractinator.me).

# Statement of need

The volume of biomedical literature grows every year [@bornmann2015], and in fast-moving fields such as oncolytic virotherapy and viral immunology the relevant evidence is spread across peer-reviewed articles, preprints [@sever2019], trial registrations [@zarin2011] and funding records. Each source answers a different question: what has been published, what is emerging, what is being tested in patients, and what is being funded. A researcher who wants all four views must run and reconcile four or more searches.

The Abstractinator is built for researchers in immunology and virology, including graduate students and early-career scientists, who need a fast, reproducible overview of a topic across these sources. It addresses three problems: (1) fragmentation, by querying all sources in one step; (2) redundancy, by deduplicating records across sources while keeping the best-curated version of each; and (3) triage, by tagging records with controlled vocabularies so that a large result set can be narrowed to the biology of interest.

A second audience is emerging: AI assistants increasingly answer scientific questions, and retrieval-augmented generation [@lewis2020] depends on access to grounded, citable sources. Since such assistants often already have a general web search tool, it is worth stating what dedicated retrieval adds. First, *declarable coverage*: a web search returns what a commercial index surfaces, with no record of what was missed, whereas the Abstractinator queries a fixed set of sources and reports how many records each contributed, which is the minimum needed for a reproducible search. Second, *sources that general search indexes poorly*: grant abstracts and trial registrations are weakly represented in web results, yet they describe work that is funded or underway years before it is published. Third, *structure*: agents receive fielded, deduplicated records with identifiers, dates and category tags, which can be counted and grouped, rather than prose pages that must be read one at a time. Fourth, *provenance and sampling*: every record states its source and evidence type, so an agent can distinguish a recruiting trial from a preprint from a funded project, and reasons over a stated sample of the literature rather than over whichever pages a general index happened to surface. Deduplication matters particularly here, since an agent otherwise risks treating several copies of one study as independent corroboration. Exposing the search engine as an MCP tool [@mcp2024] makes these results available to agents directly.

# State of the field

General scholarly search services such as Semantic Scholar [@kinney2023] and OpenAlex [@priem2022] index much of the literature, but neither covers trial registrations or grant awards, and neither tags results with domain vocabularies for immunology and virology. Programmatic clients such as the `europepmc` [@europepmc_r] and `openalexR` [@aria2024] R packages provide access to a single source each, leaving merging and deduplication to the user. Evidence-synthesis tools such as `revtools` [@westgate2019], `litsearchr` [@grames2019] and ASReview [@vandeschoot2021] support screening and search-term development for systematic reviews, starting from records the user has already exported.

The Abstractinator builds on these resources rather than replacing them: it calls the same public APIs, and is complementary to screening tools, whose input it can supply through its CSV and RIS exports. Its contribution is the layer between them: cross-source retrieval spanning literature, preprints, trials and grants; deduplication across sources with different identifier conventions; swappable domain vocabularies; and delivery of the result to both a human-facing interface and AI agents from one code base. Contributing these features to any single-source client would not address the cross-source problem, which motivated a separate tool.

# Software design

The software is written in R. A single orchestration module serves two front ends: a Shiny [@shiny] web application and a REST API built with plumber, which in turn backs a small Python MCP server. Keeping one search engine behind every interface ensures that a person and an AI agent asking the same question receive identical results.

*Parallel, fault-tolerant retrieval.* Each source is queried as an independent background job using the `future` framework [@bengtsson2021]. Search time is therefore set by the slowest source rather than the sum of all sources. Every job runs inside a safety wrapper: if one source fails or times out, the search completes with the remaining sources, and the incomplete result is not cached, so the next search retries the failed source.

*Asynchronous multi-user operation.* In the web application, searches run as asynchronous tasks, so one user's search does not block the interface for others sharing the same server process.

*Local preprint index.* Querying the bioRxiv and medRxiv APIs on every search would be slow and would place repeated load on those services. Instead, the full preprint record is stored locally as yearly Apache Parquet files [@arrow], searched lazily with Arrow, and refreshed by a daily incremental update. The index currently holds approximately 598,000 preprints (2013 to 2026) and is searched in about one second.

*Deduplication.* Records are matched first by DOI (including links from preprints to their published versions) and then by normalized title, with a source-priority order that retains the best-curated metadata. NIH grants that appear once per fiscal year collapse to a single project record.

*Transparent, swappable tagging.* Labels are assigned by matching curated alias lists against titles and abstracts, weighting title matches above abstract matches, with aliases matched as whole words so that "salmonella" does not match "salmonellosis". A lexical approach was chosen over a learned classifier because it is fast, deterministic, and easy for users to audit and extend. Vocabularies are not hard-wired: immune cells, viruses and bacteria are three instances of one tagging function, and the plot's pathogen axis is chosen from a registry of vocabularies, so adding one (fungi, parasites, drug classes, or a laboratory's own terms) means adding an alias list and a single registry entry.

*Testing.* An offline test suite covers text sanitization, query parsing, cache keys, the per-source safety net and the tagging functions, and runs automatically on a clean machine for every change. A second, opt-in suite runs live searches against the real APIs for the cases that have historically broken retrieval: queries with no results in any source, queries matching a single source, punctuation-heavy and non-ASCII queries, and large result sets.

*Caching and privacy.* Results are cached for seven days, keyed by the search term, search depth and the set of sources used. Sources that require API keys (CORE and USPTO) follow a bring-your-own-key model: keys are held only in the user's session and are never logged or shared between users.

*Position between retrieval and curation.* The output is not a raw API dump, but neither is it a curated collection. Fixed editorial rules are applied to every search: an identity rule for deciding when two records are the same work, a source-precedence rule for which version to keep, domain vocabularies for classification, and balanced sampling across sources. Nothing yet judges whether an individual study is sound or how relevant it is to the question asked, which is the step that would make the output curated rather than classified. The planned additions along that axis are relevance ranking, full-text retrieval for open-access records, and an accumulated record store that would allow signals such as citation trajectory to inform ordering.

# Research impact statement

```{=html}
<!-- TODO: JOSS requires concrete, verifiable evidence here, not plans.
     Replace the TODO sentence below before submitting. Candidates to collect:
       - Search volume from the logs (website and MCP connector), e.g.
         "N searches from M sessions between DATE and DATE".
       - External users or groups who have adopted it (with permission).
       - Listings in MCP registries; documented use from AI assistants.
       - Publications, posters, theses or grant applications that used it.
       - A recall benchmark against a hand-curated reference set per topic. -->
```

The Abstractinator is publicly available at [abstractinator.me](https://abstractinator.me) and as an MCP connector at `https://mcp.abstractinator.me/mcp`. The deployed instance is open, requires no account, and spends no shared API credentials. Every search, from the web application or from an AI agent, is recorded without personal data, which provides the usage record for this section.

Measured performance on the deployed instance: a search across all six sources returns in roughly 5 to 10 seconds, the local preprint index is searched in about one second, and repeat searches within the caching window return immediately. TODO: add usage volume, adopting groups, registry listings, and any publications, theses or applications that used the tool.

# AI usage disclosure

<!-- TODO: review and edit so it accurately reflects your own process. -->

Generative AI tools (Anthropic's Claude) were used during development to assist with code refactoring (including parallel and asynchronous search, error handling, input sanitization and the MCP server), deployment configuration, test authoring, documentation, and drafting of this paper. All AI-assisted code was reviewed by the author and tested on the deployed system, including the edge-case searches described above. The author takes full responsibility for the software and this manuscript.

# Acknowledgements

TODO: acknowledge funding, mentors and contributors. Mascot icons are by Smashicons, imaginationlol and Magnific via Flaticon.

# References
