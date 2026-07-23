@echo off
cd /d "C:\Users\Chase Kangas\Documents\Everything_R\working_Abstractinator_v5"
"C:\Program Files\R\R-4.5.1\bin\Rscript.exe" "weekly_updater.R" >> "weekly_cron.log" 2>&1