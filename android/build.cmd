@echo off
chcp 65001 >nul
rem Сборка APK. Результат копируется в ..\PhonePrint.apk — оттуда его раздаёт PhonePrint (http://<ПК>:8080/app)
rem Папку с инструментами можно задать переменной TOOLS (по умолчанию D:\android-tools):
rem   set TOOLS=C:\android-tools ^& build.cmd
rem Если JAVA_HOME / ANDROID_HOME уже заданы в системе — они используются как есть.
setlocal
if not defined TOOLS set TOOLS=D:\android-tools
if not defined JAVA_HOME set JAVA_HOME=%TOOLS%\jdk
if not defined ANDROID_HOME set ANDROID_HOME=%TOOLS%\sdk
if not defined GRADLE_USER_HOME set GRADLE_USER_HOME=%TOOLS%\gradle-home
cd /d "%~dp0"
if exist "%TOOLS%\gradle-8.11.1\bin\gradle.bat" (
    call "%TOOLS%\gradle-8.11.1\bin\gradle.bat" assembleRelease --console=plain
) else (
    call gradlew.bat assembleRelease --console=plain
)
if errorlevel 1 exit /b 1
copy /y "app\build\outputs\apk\release\app-release.apk" "..\PhonePrint.apk" >nul
if errorlevel 1 exit /b 1
echo.
echo Готово: %~dp0..\PhonePrint.apk
