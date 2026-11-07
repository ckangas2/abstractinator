# benchmark/

How well the organism tags agree with an independent annotator.

`pubtator.md` compares our `primary_virus` and `primary_bacteria` with the
species that [PubTator3](https://www.ncbi.nlm.nih.gov/research/pubtator3/)
(NCBI) annotates in the same PubMed titles and abstracts.
`pubtator_disagreements.csv` lists every record where the two differ.

Regenerate on the server, from the repo root (about 15 minutes, stdlib only):

```bash
python3 deploy/benchmark_pubtator.py
```

PubTator3 is a model too, so the figures measure agreement, not accuracy. It
has no cell types, so `primary_cell` is not covered.
