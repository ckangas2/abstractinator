@echo off
:: Explicitly define environment variables required by R/Arrow
set AWS_ACCESS_KEY_ID=your_key
set AWS_SECRET_ACCESS_KEY=your_secret
set AWS_DEFAULT_REGION=us-east-1
set DATA_WEBHOOK_URL=your_discord_webhook_url
set BIORXIV_BUCKET_NAME=biorxiv-2025-data

:: Execute Rscript
"C:\Program Files\R\R-4.x.x\bin\Rscript.exe" "C:\path\to\update_chips.R" >> "C:\path\to\logs\chips_updater.log" 2>&1