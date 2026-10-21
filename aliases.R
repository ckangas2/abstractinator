# aliases.R

# --- Define Immune Cell Aliases for Extraction ---
immune_cell_alias_list <- list(
  "T cell" = c("T cell", "T cells", "T-cell", "T-cells", "T lymphocyte", "T lymphocytes"),
  "CD4+ T cell" = c("CD4+ T cell", "CD4+ T cells", "CD4+ T-cell", "CD4+ T-cells", "helper T cell", "helper T cells", "Th cell", "Th cells"),
  "CD8+ T cell" = c("CD8+ T cell", "CD8+ T cells", "CD8+ T-cell", "CD8+ T-cells", "cytotoxic T cell", "cytotoxic T cells", "CTL", "CTLs"),
  "Regulatory T cell" = c("regulatory T cell", "regulatory T cells", "Treg", "Tregs"),
  "B cell" = c("B cell", "B cells", "B-cell", "B-cells", "B lymphocyte", "B lymphocytes"),
  "Natural killer cell" = c("natural killer cell", "natural killer cells", "NK cell", "NK cells"),
  "Monocyte" = c("monocyte", "monocytes"),
  "Macrophage" = c("macrophage", "macrophages"),
  "Dendritic cell" = c("dendritic cell", "dendritic cells", "DC", "DCs"),
  "Neutrophil" = c("neutrophil", "neutrophils"),
  "Eosinophil" = c("eosinophil", "eosinophils"),
  "Basophil" = c("basophil", "basophils"),
  "Mast cell" = c("mast cell", "mast cells"),
  "Innate lymphoid cell" = c("innate lymphoid cell", "innate lymphoid cells", "ILC", "ILCs"),
  "ILC1" = c("ILC1"),
  "ILC2" = c("ILC2"),
  "ILC3" = c("ILC3"),
  "Plasma cell" = c("plasma cell", "plasma cells"),
  "Memory T cell" = c("memory T cell", "memory T cells"),
  "Effector T cell" = c("effector T cell", "effector T cells"),
  "Naive T cell" = c("naive T cell", "naive T cells"),
  "Exhausted T cell" = c("exhausted T cell", "exhausted T cells"),
  "Memory B cell" = c("memory B cell", "memory B cells"),
  "Hematopoietic stem cell" = c("hematopoietic stem cell", "hematopoietic stem cells")
)

# --- Define Virus Aliases for Extraction ---
virus_alias_expanded <- list(
  "Adeno-Associated Virus" = c("adeno-associated virus", "AAV", "AAVs", "rAAV", "scAAV", "adeno-associated dependoparvovirus a", "adeno-associated dependoparvovirus b"),
  "Vesicular Stomatitis Virus" = c("vesicular stomatitis virus", "VSV"),
  "Newcastle Disease Virus" = c("newcastle disease virus", "NDV"),
  "Seneca Valley Virus" = c("seneca valley virus", "SVV"),
  "Myxoma Virus" = c("myxoma virus", "MYXV"),
  "ECHO-7 virus" = c("ECHO-7 virus", "Rigvir", "Riga virus"),
  "Maraba Virus" = c("maraba virus"),
  "Semliki Forest virus" = c("Semliki Forest virus", "SFV"),
  "Sindbis virus" = c("Sindbis virus", "SINV"),
  "Venezuelan equine encephalitis virus" = c("Venezuelan equine encephalitis virus", "VEEV"),
  "West Nile Virus" = c("West Nile Virus", "WNV"),
  "Simian virus 40" = c("Simian virus 40", "SV40"),
  "Rabies Virus" = c("Rabies Virus"),
  "Human Immunodeficiency Virus" = c("human immunodeficiency virus", "HIV", "HIV-1"),
  "Herpes Simplex Virus" = c("talimogene laherparepvec", "TVEC", "T-VEC", "herpes simplex virus type 1", "HSV-1", "HSV1", "oHSV", "herpes simplex virus", "HSVs", "HSV", "herpes"),
  "Herpes Simplex Virus 2" = c("HSV-2", "HSV2"),
  "Vaccinia Virus" = c("vaccinia virus", "VV", "VACV"),
  "Measles Virus" = c("measles virus", "MV", "rubeola"),
  "Lentivirus" = c("lentivirus", "LVs", "LV", "LVV", "lentiviral vectors"),
  "Retrovirus" = c("retrovirus", "RVs", "RV", "retroviral vectors", "gamma-retroviruses"),
  "Adenovirus" = c("adenovirus", "Ads", "Ad", "AV", "adenoviruses", "hAdV", "HAdV-5"),
  "Reovirus" = c("reovirus"),
  "Poliovirus" = c("poliovirus"),
  "Coxsackievirus" = c("coxsackievirus", "CV"),
  "Parvovirus" = c("parvovirus", "rat parvovirus H-1PV"),
  "Baculovirus" = c("baculovirus"),
  "Foamy Virus" = c("foamy virus", "FVV", "spumavirus"),
  "Alphavirus" = c("alphavirus"),
  "Flavivirus" = c("flavivirus"),
  "Polyomavirus" = c("polyomavirus"),
  "Rhabdovirus" = c("rhabdovirus")
)

# --- Define Bacteria Aliases for Extraction ---
# Genera and species used in bacterial cancer therapy, plus common pathogens
# that appear in immunology and virology literature. Same format as the lists
# above: "Display name" = c(alias, alias, ...). Aliases are matched as whole
# words, case-insensitively, so short ones (e.g. "BCG") are safe but should be
# distinctive. Contributions welcome: add a genus or species and open a PR.
bacteria_alias_expanded <- list(
  # --- Bacterial cancer therapy ---
  "Salmonella" = c("salmonella", "salmonella typhimurium", "s. typhimurium", "VNP20009", "Salmonella enterica"),
  "Clostridium" = c("clostridium", "clostridium novyi", "c. novyi", "clostridium butyricum", "clostridia"),
  "Listeria" = c("listeria", "listeria monocytogenes", "l. monocytogenes", "ADXS11-001", "Lm-LLO"),
  "Bifidobacterium" = c("bifidobacterium", "bifidobacterium longum", "b. longum", "bifidobacteria"),
  "Mycobacterium bovis BCG" = c("BCG", "bacillus calmette-guerin", "bacille calmette-guerin", "mycobacterium bovis"),
  "Escherichia coli" = c("escherichia coli", "e. coli", "E. coli Nissle", "EcN"),
  "Lactobacillus" = c("lactobacillus", "lactobacilli", "lactobacillus rhamnosus", "lacticaseibacillus"),
  "Lactococcus" = c("lactococcus", "lactococcus lactis", "l. lactis"),

  # --- Mycobacteria ---
  "Mycobacterium tuberculosis" = c("mycobacterium tuberculosis", "m. tuberculosis", "Mtb", "tubercle bacillus"),
  "Mycobacterium leprae" = c("mycobacterium leprae", "m. leprae"),

  # --- Common human pathogens ---
  "Staphylococcus aureus" = c("staphylococcus aureus", "s. aureus", "MRSA", "methicillin-resistant staphylococcus aureus"),
  "Streptococcus pneumoniae" = c("streptococcus pneumoniae", "s. pneumoniae", "pneumococcus", "pneumococcal"),
  "Streptococcus pyogenes" = c("streptococcus pyogenes", "s. pyogenes", "group A streptococcus"),
  "Pseudomonas aeruginosa" = c("pseudomonas aeruginosa", "p. aeruginosa"),
  "Klebsiella pneumoniae" = c("klebsiella pneumoniae", "k. pneumoniae", "klebsiella"),
  "Acinetobacter baumannii" = c("acinetobacter baumannii", "a. baumannii", "acinetobacter"),
  "Helicobacter pylori" = c("helicobacter pylori", "h. pylori"),
  "Neisseria meningitidis" = c("neisseria meningitidis", "n. meningitidis", "meningococcus", "meningococcal"),
  "Neisseria gonorrhoeae" = c("neisseria gonorrhoeae", "n. gonorrhoeae", "gonococcus"),
  "Chlamydia trachomatis" = c("chlamydia trachomatis", "c. trachomatis", "chlamydia"),
  "Borrelia burgdorferi" = c("borrelia burgdorferi", "b. burgdorferi", "borrelia", "Lyme disease spirochete"),
  "Clostridioides difficile" = c("clostridioides difficile", "clostridium difficile", "c. difficile", "C. diff"),
  "Enterococcus" = c("enterococcus", "enterococcus faecalis", "enterococcus faecium", "VRE", "vancomycin-resistant enterococcus"),
  "Haemophilus influenzae" = c("haemophilus influenzae", "h. influenzae"),
  "Bacteroides" = c("bacteroides", "bacteroides fragilis", "b. fragilis"),
  "Fusobacterium" = c("fusobacterium", "fusobacterium nucleatum", "f. nucleatum"),
  "Akkermansia" = c("akkermansia", "akkermansia muciniphila", "a. muciniphila"),
  "Vibrio cholerae" = c("vibrio cholerae", "v. cholerae"),
  "Shigella" = c("shigella", "shigella flexneri", "shigella dysenteriae"),
  "Yersinia" = c("yersinia", "yersinia pestis", "y. pestis", "yersinia enterocolitica"),
  "Francisella tularensis" = c("francisella tularensis", "f. tularensis", "francisella"),
  "Bacillus anthracis" = c("bacillus anthracis", "b. anthracis", "anthrax bacillus"),
  "Legionella pneumophila" = c("legionella pneumophila", "l. pneumophila", "legionella"),
  "Campylobacter jejuni" = c("campylobacter jejuni", "c. jejuni", "campylobacter"),
  "Treponema pallidum" = c("treponema pallidum", "t. pallidum")
)

# ---- Additions derived from MeSH, reviewed 2026-10-21 --------------------
# Generated by deploy/propose_aliases.R, which lists descriptors MeSH files
# under an organism tree that no existing category covers, ranked by how often
# they occur. Curated before adding:
#   - MeSH entry terms are plural only ("bacteriophages", "phages"), and the
#     \b anchors mean a plural alias never matches the singular. Both forms
#     are listed here.
#   - The influenza subtypes MeSH proposes separately (A, B, H1N1, H3N2) are
#     folded into one category: four dropdown rows holding 3-5 records each
#     tell the Plotinator nothing, and the subtype is in the title anyway.
#   - Skipped: "Oncolytic Viruses" (67 occurrences, but a function rather than
#     a taxon -- better as a flag like is_bioinformatics), "Viruses" and
#     "Bacteria" (top-level; bare-word aliases that would match most of the
#     corpus), "Jurkat Cells" (a cell line), "Betacoronavirus" (genus-level
#     and overlaps SARS-CoV-2).
#   - "TIL"/"TILs" deliberately omitted as aliases: too short to anchor safely.
# Appended with c() rather than edited into the literals above, so the
# original lists stay intact and these are easy to find and revert.

virus_alias_expanded <- c(virus_alias_expanded, list(
  "SARS-CoV-2" = c("sars-cov-2", "sars cov 2", "sars-cov2", "2019-ncov",
                   "covid-19 virus", "severe acute respiratory syndrome coronavirus 2",
                   "wuhan coronavirus"),
  "Norovirus"  = c("norovirus", "noroviruses", "norwalk virus", "norwalk viruses",
                   "norwalk-like virus", "norwalk-like viruses"),
  "Rotavirus"  = c("rotavirus", "rotaviruses"),
  "Bacteriophage" = c("bacteriophage", "bacteriophages", "phage", "phages",
                      "phix174", "phi x 174"),
  "Sapovirus"  = c("sapovirus", "sapoviruses", "sapporo virus"),
  "Influenza"  = c("influenza virus", "influenza viruses", "influenza a virus",
                   "influenza b virus", "influenza a", "influenza b",
                   "h1n1", "h3n2", "h5n1", "h7n9", "fluav", "flubv",
                   "orthomyxovirus", "orthomyxoviruses")
))

immune_cell_alias_list <- c(immune_cell_alias_list, list(
  "Tumor-infiltrating lymphocyte" = c("tumor-infiltrating lymphocyte",
                                      "tumor-infiltrating lymphocytes",
                                      "tumor infiltrating lymphocyte",
                                      "tumor infiltrating lymphocytes",
                                      "tumour-infiltrating lymphocyte",
                                      "tumour-infiltrating lymphocytes"),
  "PBMC" = c("pbmc", "pbmcs", "peripheral blood mononuclear cell",
             "peripheral blood mononuclear cells",
             "mononuclear leukocyte", "mononuclear leukocytes")
))
