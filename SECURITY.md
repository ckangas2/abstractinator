# Security Policy

The Abstractinator is a free, open-source research tool maintained by one
person. It is deployed at <https://abstractinator.me> behind a Cloudflare
tunnel, with no inbound ports open on the origin.

## What the service stores

- **Search terms**, logged anonymously, with a channel label (`website` or
  `agent`) and a timestamp. No IP address, no account, no session identity.
- **A result cache**, keyed by search term, retained 7 days.
- Nothing else.

## API keys

Two optional sources (CORE, USPTO PatentsView) require an API key. The
deployment is strictly bring-your-own-key:

- A visitor's key is held in that visitor's Shiny session only.
- It is never written to disk, never logged, and never visible in the UI
  (the input is a password field).
- The server's own environment is deliberately *not* consulted for these
  keys, so no visitor can ever spend the maintainer's credits.

## Reporting a vulnerability

Open an issue: <https://github.com/ckangas2/abstractinator/issues>

For something you would rather not disclose publicly, open an issue saying
only that you have a security report and asking for a contact method.

Please include the URL or endpoint, what you did, and what you observed.
Good-faith reports are welcome and will not be met with legal threats.

**Please do not run automated scanners at volume against the live site.** It
runs on a single machine, and that traffic is indistinguishable from an
attack. If you want to test, clone the repo and run it locally — the README
documents the full deployment.

## Scope

In scope: the Shiny app, the REST API, the MCP server, and the deployment
configuration in this repository.

Out of scope: the upstream databases the tool queries (Europe PMC, OpenAlex,
ClinicalTrials.gov, bioRxiv/medRxiv, NIH RePORTER, NSF), Cloudflare itself,
and findings that amount to "a scanner reported a missing header" without a
demonstrated impact.

## Response

Best effort, by one person, around a day job. Expect days, not hours.
