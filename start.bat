@echo off
REM Starts prompts.chat locally on Windows.
REM Needs Node.js 24 and Docker Desktop. Postgres runs in a Docker container,
REM the app runs in Next.js dev mode at http://localhost:3000.
setlocal EnableExtensions
cd /d "%~dp0"

set "DB_CONTAINER=prompts-chat-db"
set "DB_VOLUME=prompts_chat_pgdata"
set "APP_URL=http://localhost:3000"
set "FIRST_RUN="
if "%~1"==":open_browser" goto :open_browser

where node >nul 2>&1 || (echo Node.js not found. Install Node.js 24 from https://nodejs.org & goto :fail)
where docker >nul 2>&1 || (echo Docker not found. Install Docker Desktop from https://www.docker.com & goto :fail)

REM 1. Make sure the Docker engine is up
docker info >nul 2>&1
if errorlevel 1 (
  echo Starting Docker Desktop...
  if exist "%ProgramFiles%\Docker\Docker\Docker Desktop.exe" start "" "%ProgramFiles%\Docker\Docker\Docker Desktop.exe"
  for /l %%i in (1,1,60) do (
    docker info >nul 2>&1 && goto :docker_ready
    timeout /t 3 /nobreak >nul
  )
  echo Docker did not start within 3 minutes.
  goto :fail
)
:docker_ready

REM 2. Create .env on first run
if exist ".env" goto :env_ready
echo Creating .env...
node -e "const c=require('crypto'),q=String.fromCharCode(34),s=c.randomBytes(32).toString('base64'),db='postgresql://prompts:prompts@localhost:5432/prompts?schema=public',v={DATABASE_URL:db,DIRECT_URL:db,NEXTAUTH_URL:'%APP_URL%',NEXTAUTH_SECRET:s,AUTH_SECRET:s,CRON_SECRET:c.randomBytes(16).toString('hex')};require('fs').writeFileSync('.env',Object.entries(v).map(([k,x])=>k+'='+q+x+q).join(String.fromCharCode(10))+String.fromCharCode(10))" || goto :fail
:env_ready
REM Local login: email/password instead of GitHub/Google/Apple, open registration
findstr /b "PCHAT_AUTH_PROVIDERS=" .env >nul || echo PCHAT_AUTH_PROVIDERS="credentials">>.env
findstr /b "PCHAT_ALLOW_REGISTRATION=" .env >nul || echo PCHAT_ALLOW_REGISTRATION="true">>.env
REM Prefill the login form with the seeded admin (dev mode only)
findstr /b "PCHAT_DEV_LOGIN_EMAIL=" .env >nul || echo PCHAT_DEV_LOGIN_EMAIL="admin@prompts.chat">>.env
findstr /b "PCHAT_DEV_LOGIN_PASSWORD=" .env >nul || echo PCHAT_DEV_LOGIN_PASSWORD="password123">>.env

REM 3. Start (or create) the Postgres container
docker inspect %DB_CONTAINER% >nul 2>&1
if errorlevel 1 (
  echo Creating database container...
  docker run -d --name %DB_CONTAINER% --restart unless-stopped ^
    -e POSTGRES_USER=prompts -e POSTGRES_PASSWORD=prompts -e POSTGRES_DB=prompts ^
    -p 5432:5432 -v %DB_VOLUME%:/var/lib/postgresql/data postgres:17-bookworm >nul || goto :fail
  set "FIRST_RUN=1"
) else (
  docker start %DB_CONTAINER% >nul || goto :fail
)

echo Waiting for the database...
for /l %%i in (1,1,30) do (
  docker exec %DB_CONTAINER% pg_isready -U prompts -d prompts >nul 2>&1 && goto :db_ready
  timeout /t 2 /nobreak >nul
)
echo Database did not become ready.
goto :fail
:db_ready

REM 4. Install dependencies on first run
if not exist "node_modules" (
  echo Installing dependencies...
  call npm install || goto :fail
)

REM 5. Apply migrations, seed a fresh database
call npx prisma migrate deploy || goto :fail
if defined FIRST_RUN (
  echo Seeding database...
  call npm run db:seed || goto :fail
)

REM 6. Run the app and open the browser once it responds
start "" /b cmd /c ""%~f0" :open_browser"
echo.
echo prompts.chat is starting at %APP_URL%  (Ctrl+C to stop)
if defined FIRST_RUN echo Seeded admin login: admin@prompts.chat / password123
call npm run dev
goto :eof

:open_browser
REM Runs in the background: waits up to 3 minutes for the app, then opens it
for /l %%i in (1,1,60) do (
  curl -s -o nul "%APP_URL%" && (start "" "%APP_URL%" & exit /b 0)
  timeout /t 3 /nobreak >nul
)
exit /b 0

:fail
echo.
echo Startup failed. See the messages above.
pause
exit /b 1
