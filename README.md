# 🧬 The Abstractinator

**The Abstractinator** is a high-performance, automated boolean search and aggregation pipeline designed for the rapid acquisition, classification, and triage of immunology and virology literature. It transforms the traditionally manual process of literature review into a deterministic engineering pipeline.

---

## 🚀 1. Executive Overview

The tool aggregates metadata and abstracts from a wide array of open-access and authenticated databases, deduplicates them using distinct record identification, and applies a weighted scoring matrix to categorize papers by specific immune cell types and viruses.

### The "Nator" Ecosystem:
*   **Searchinator**: Orchestrates simultaneous queries across multiple global repositories.
*   **Deduplicatinator**: Eliminates redundancy between sources via unique record ID mapping.
*   **Plotinator**: An interactive analytics suite visualizing the intersection of virology and immunology trends.
*   **Readinator**: A curation tool for building targeted reading lists for export to Zotero/EndNote.

---

## 🛠️ 2. Technical Architecture

### Data Sources & Retrieval
The pipeline utilizes a hybrid retrieval strategy, combining open-access APIs with authenticated deep-searches:

| Source | Access Level | Focus |
| :--- | :--- | :--- |
| **Europe PMC** | Open | Primary Biomedical Literature |
| **OpenAlex** | Open | Global Scholarly Graph |
| **bioRxiv / medRxiv** | Open | Pre-prints (cutting edge) |
| **ClinicalTrials.gov** | Open | Human Clinical Study Protocols |
| **CORE** | API Key | Full-text Open Access Aggregation |
| **USPTO (PatentsView)** | API Key | Patent landscape & Intellectual Property |
| **NIH Reporter** | Open | US Federal Grant Funding/Projects |
| **NSF Awards** | Open | Fundamental Research Grants |
| **Scopus / Embase** | API Key | Gold-standard indexed literature |

### Dual-Write Storage Strategy
To serve both human researchers and autonomous agents, the system implements a dual-tier storage architecture in SQLite:

1.  **Human Tier (UI Snapshots)**: Search results are serialized into binary blobs for near-instant loading within the Shiny interface, bypassing expensive re-processing.
2.  **Agent Tier (Relational Knowledge Base)**: Every article is indexed as a unique row in a relational table (`articles`) with optimized indexes on titles and abstracts. This enables high-precision SQL querying for RAG (Retrieval-Augmented Generation) pipelines.

---

## 🤖 3. Agent Interface Specification

The Abstractinator is designed to be used as a "Source of Truth" for AI agents. Agents should interact via the `agent_api.R` wrapper rather than calling orchestration scripts directly.

### Available API Functions:
*   **`agent_search(term, keys)`**: Triggers a search (or hits cache) and returns a deduplicated data frame.
*   **`agent_query_kb(sql_query)`**: Executes raw SQL against the `articles` table for high-precision filtering.
*   **`agent_find_top_abstracts(keyword, n=5)`**: Retrieves only the most relevant abstracts to optimize LLM context windows.
*   **`agent_analyze_gap(topic)`**: Performs a knowledge audit to determine if current local data is sufficient or if a new search is required.
*   **`agent_format_as_md(df)`**: Converts R data frames into LLM-optimized Markdown tables.

### Database Schema for Agents:
| Column | Type | Description |
| :--- | :--- | :--- |
| `article_id` | TEXT (PK) | Unique identifier (DOI or URL) |
| `title` | TEXT | Title of the paper |
| `abstract` | TEXT | Full abstract text |
| `authors` | TEXT | Semicolon separated author list |
| `publication_date` | TEXT | ISO Date string |
| `url` | TEXT | Direct link to article |
| `doi` | TEXT | Digital Object Identifier |
| `source` | TEXT | Origin (e.g., 'NIH', 'PubMed', 'CORE') |
| `is_bioinformatics` | INTEGER | 1 = Bioinformatics focused, 0 = otherwise |
| `primary_cell` | TEXT | The dominant immune cell identified |
| `primary_virus` | TEXT | The dominant virus identified |

---

## ⚙️ 4. Installation & Setup

### Prerequisites
*   **R** (version 4.1+)
*   **Shiny** (for the web interface)

### Setup Steps
1. **Clone the Repository**:
   ```bash
   git clone https://github.com/your-username/abstractinator.git
   cd abstractinator
   ```

2. **Configure Environment Variables**:
   Create a `.Renviron` file in the project root and add your API keys:
   ```text
   ELSEVIER_API_KEY=***
   CORE_API_KEY=***
   USPTO_API_KEY=***
   INTEGRATE_NIH_NSF=1
   ```

3. **Initialize BioRxiv Database**:
   The pipeline requires a local copy of the bioRxiv database for high-performance preprint searching. You must run the harvest script to download and build this local Parquet store before launching the application:
   ```bash
   Rscript write_parquet_bioRxiV.R
   ```

4. **Launch the Application**:
   Open `app.R` in RStudio or run:
   ```R
   shiny::runApp('app.R')
   ```

---

## 📜 Citation

If you use The Abstractinator in your research, please cite it as follows:

> Kangas, C. (2025). The Abstractinator: Automated Boolean Search Tool for Rapid Acquisition, Classification, and Triage of Immuno-Networks And Therapeutic Oncolytic Research [Computer software].

**BibTeX:**
```bibtex
@software{TheAbstractinator2025,
  author = {Kangas, Chase},
  title = {The Abstractinator: Automated Boolean Search Tool for Rapid Acquisition, Classification, and Triage of Immuno-Networks And Therapeutic Oncolytic Research},
  year = {2025},
  url = {https://theabstractinator.shinyapps.io/Abstractinator/},
  version = {1.4.0}
}
```
