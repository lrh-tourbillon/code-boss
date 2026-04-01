@echo off
cd /d E:\cowork\codeboss
echo === Initializing git repo ===
git init
echo === Setting branch to main ===
git branch -M main
echo === Adding remote ===
git remote add origin https://github.com/lrh-tourbillon/code-boss.git
echo === Staging all files ===
git add -A
echo === Committing ===
git commit -m "Initial commit: CodeBoss plugin with Windows scripts and macOS placeholder"
echo === Force pushing (replacing GitHub's initial commit) ===
git push -u origin main --force
echo.
echo === DONE ===
del "%~f0"
pause
