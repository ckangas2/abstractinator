# benchmark/

How well the organism tags agree with an independent annotator.

`pubtator.md` compares our `primary_virus` and `primary_bacteria` with the
species that [PubTator3](https://www.ncbi.nlm.nih.gov/research/pubtator3/)
(NCBI) annotates in the same PubMed titles and abstracts, in three sets of
searches reported separately:

- **Held-out** (the headline): immune-process topics that name no organism,
  frozen on 2026-11-07 and never used to tune the alias lists. The report
  gives their figures but no example records.
- **Tuning**: topics that name an organism. Their disagreements are listed and
  have been used to fix the alias lists, so these figures are optimistic.
- **Negative controls**: searches where an organism tag would usually be
  wrong (acronym collisions such as "AD", "RV", "ad libitum").

The main figure is **tag support** (how often a tag we assign is backed by a
PubTator3 annotation of the same organism), with 95% confidence intervals.
`pubtator_disagreements.csv` lists every tuning-set disagreement and every
tagged negative control.

Regenerate on the server, from the repo root (about 25 minutes, stdlib only),
then commit both files:

```bash
python3 deploy/benchmark_pubtator.py
git add benchmark/pubtator.md benchmark/pubtator_disagreements.csv
```

PubTator3 is a model too, so the figures measure agreement, not accuracy.
Only PubMed records are compared; grants, trials and preprints (text matching
only, no MeSH) are not covered, and neither are cell types (PubTator3 has
none).
