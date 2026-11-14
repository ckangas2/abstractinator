# fill_host_taxon.py

Fills the `host_taxon` column of `registry/virus.tsv` from NCBI Taxonomy, one
id per name in `host`, in the same order. Run it after adding a phage row.

    python3 tracker/fill_host_taxon.py --repo .

Every id is checked twice before it is used: an `esearch` for
`<name>[Scientific Name]` must return exactly one id, and the `esummary` for
that id must come back with the same scientific name at genus or species rank.

A name NCBI has reclassified -- *Mycobacterium abscessus* is now
*Mycobacteroides abscessus* -- is searched again under `[All Names]`, and the
id is used only if the taxonomy record itself lists the name the registry
holds. Those matches are printed under "names NCBI has reclassified". The
registry keeps the name the trials and papers use; the id carries the taxonomy.

The script never overwrites an existing `host_taxon`, backs `virus.tsv` up to
`~/abstractinator-backups/` before writing, and changes no other column.
`--map FILE` reads `name<TAB>taxid` lines instead of asking NCBI, which is how
`tests/test_host_taxon_resolve.py` and offline dry runs work.

Used on 2026-11-14 to fill all 33 phage rows (commit 2c47a2c).
